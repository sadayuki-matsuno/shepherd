import AppKit

// MARK: - UI building blocks

final class RowView: NSView {
    // The panel is movable by dragging its background (isMovableByWindowBackground). Without this,
    // a drag that starts on a card would ALSO move the whole HUD. Cards handle their own gestures
    // (click / ⌘-click / file drop), so they must not double as a window-move handle.
    override var mouseDownCanMoveWindow: Bool { false }
    var sessionId: String = ""
    var onClick: (() -> Void)?
    var onCmdClick: (() -> Void)?        // ⌘+click: blocked cards jump straight to the reply box (D2)
    var menuProvider: (() -> NSMenu?)?   // right-click: the context menu (D1/修正3)
    var onHoverChanged: ((Bool) -> Void)?  // card hover (drives the family-peek popover, C7)
    var interactionDisabled = false      // a stop/rm is in flight: swallow every click, badge and menu
    private var tracking: NSTrackingArea?
    var baseColor: NSColor = Cat.surface.withAlphaComponent(0.55)
    // A dashed border marking a subagent/teammate card (2026-07-11). A CALayer border can't be
    // dashed, so it's a CAShapeLayer whose rounded-rect path we resize here as the card lays out.
    var subagentDash: CAShapeLayer?

    override func layout() {
        super.layout()
        if let dash = subagentDash {
            dash.frame = bounds
            dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               cornerWidth: 8, cornerHeight: 8, transform: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if interactionDisabled { return }
        if event.modifierFlags.contains(.command), let cmd = onCmdClick { cmd(); return }
        onClick?()
    }

    // Use AppKit's native contextual-menu resolution rather than a rightMouseDown override. A plain
    // rightMouseDown never fires when the click lands on a child label: NSView's default pops the
    // label's own (nil) menu and does *not* bubble to the card — unlike left-click, which walks the
    // responder chain (which is why left-click jump worked but right-click didn't — 修正3). menu(for:)
    // is consulted by that same default path, and hitTest(_:) below routes right-clicks over passive
    // labels/stacks to the card, so the menu resolves anywhere on the card. Native menus track fine
    // on a nonactivating panel (same reason the v5 popUp menu did), so no NSApp.activate is needed.
    override func menu(for event: NSEvent) -> NSMenu? {
        if interactionDisabled { return nil }
        return menuProvider?() ?? super.menu(for: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Disabled (stop/rm in flight): the card takes every hit itself, so the buttons and badges
        // underneath — link badges, the family-strip toggle — never see the click.
        if interactionDisabled { return self }
        if hit === self { return self }
        // Keep genuinely interactive descendants clickable; route everything else (labels, stacks,
        // hover regions) to the card so it receives both left- and right-clicks. NOTE: this must be a
        // strict allow-list of *buttons/badges* — NOT `NSControl`, because NSTextField (every
        // makeLabel) subclasses NSControl, so `cur is NSControl` would wrongly hand the primary work
        // title (a label filling line1) back to itself and swallow the right-click (v5fix2 #1). Hover
        // tracking areas still fire independently of hitTest.
        var v: NSView? = hit
        while let cur = v, cur !== self {
            if cur is ClickableBadge || cur is NSButton { return hit }
            v = cur.superview
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    var tray: NSView?                   // action tray, revealed on hover

    // File drag & drop: the card is a drop target. Closures let AppDelegate coordinate the
    // "highlight this card / dim the others" visual across all cards during a drag.
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var dropLabelText = ""
    private var dropOverlay: NSView?

    // We only lighten the background on hover — the mouse cursor can't be changed to a
    // pointing hand here. macOS ignores NSCursor / cursorUpdate for a nonactivating panel
    // in an accessory (LSUIElement) app that never becomes active, and stealing focus to
    // work around it would defeat the whole point of a glanceable HUD.
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = baseColor.withAlphaComponent(min(baseColor.alphaComponent + 0.2, 1)).cgColor
        tray?.animator().alphaValue = 1
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseColor.cgColor
        tray?.animator().alphaValue = 0
        onHoverChanged?(false)
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        onDragEnter?()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        onDragEnter?()   // keeps this card the target and marks drag activity (pauses rebuild)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    // Highlight this card as the drop target (dashed-look overlay + label), or dim it when
    // another card is the target. Driven by AppDelegate so all cards update together.
    func applyDragVisual(target: Bool, dimmed: Bool) {
        alphaValue = dimmed ? 0.35 : 1
        if target {
            if dropOverlay == nil {
                let o = NSView()
                o.wantsLayer = true
                o.layer?.backgroundColor = Cat.base.withAlphaComponent(0.88).cgColor
                o.layer?.cornerRadius = 9
                o.layer?.borderWidth = 2
                o.layer?.borderColor = Cat.lavender.cgColor
                o.translatesAutoresizingMaskIntoConstraints = false
                let l = symbolLabel("paperclip", dropLabelText, size: 12, weight: .semibold, color: Cat.lavender)
                l.alignment = .center
                l.lineBreakMode = .byTruncatingTail
                l.translatesAutoresizingMaskIntoConstraints = false
                o.addSubview(l)
                addSubview(o)
                NSLayoutConstraint.activate([
                    o.leadingAnchor.constraint(equalTo: leadingAnchor),
                    o.trailingAnchor.constraint(equalTo: trailingAnchor),
                    o.topAnchor.constraint(equalTo: topAnchor),
                    o.bottomAnchor.constraint(equalTo: bottomAnchor),
                    l.centerXAnchor.constraint(equalTo: o.centerXAnchor),
                    l.centerYAnchor.constraint(equalTo: o.centerYAnchor),
                    l.leadingAnchor.constraint(greaterThanOrEqualTo: o.leadingAnchor, constant: 10),
                    l.trailingAnchor.constraint(lessThanOrEqualTo: o.trailingAnchor, constant: -10),
                ])
                dropOverlay = o
            }
            dropOverlay?.isHidden = false
        } else {
            dropOverlay?.isHidden = true
        }
    }
}

final class ActionButton: NSButton {
    var onPress: (() -> Void)?
    @objc func fire() { onPress?() }
}

// An NSMenuItem that runs a closure when picked — lets the right-click context menu (D1) be built
// inline without a fan of @objc selectors.
final class ClosureMenuItem: NSMenuItem {
    var onSelect: (() -> Void)?
    convenience init(_ title: String, enabled: Bool = true, _ onSelect: (() -> Void)? = nil) {
        self.init(title: title, action: onSelect == nil ? nil : #selector(fire), keyEquivalent: "")
        self.onSelect = onSelect
        self.isEnabled = enabled && onSelect != nil
        self.target = self
    }
    @objc func fire() { onSelect?() }
}

// A small clickable pill (for the unified PR / Artifact badges on the card).
final class ClickableBadge: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    // Badges keep their own left-click (open link / show list), but a right-click on one should
    // still surface the card's context menu — forward to the nearest ancestor that provides one. (修正3)
    override func menu(for event: NSEvent) -> NSMenu? {
        var v = superview
        while let cur = v { if let m = cur.menu(for: event) { return m }; v = cur.superview }
        return nil
    }
}

// Pasteboard type carrying a repo group's key while it's dragged between/within columns (v6 #2).
// Distinct from `.fileURL` so a repo-block drag never collides with the card's file-drop target.
let repoBlockPBType = NSPasteboard.PasteboardType("com.shepherd.repoblock")

// A column-header container that surfaces a right-click menu the same way a card does (v5fix4 #2):
// menu(for:) returns a provided menu, and hitTest routes clicks on passive labels (NSTextField is an
// NSControl) to the header so a right-click resolves anywhere on the header block. Buttons (the
// collapse caret) still receive their own clicks. Mirrors RowView.menu(for:)/hitTest.
//
// The header also doubles as the drag *handle* for moving its repo group to another column/position
// (v6 #2): a left-drag beyond a small threshold begins a dragging session carrying the repo key on
// `repoBlockPBType`. Dragging is limited to the header (not the cards) so it never fights the card's
// click / right-click / file-drop. Works on a nonactivating panel — a drag session needs no key
// window, only mouse tracking.
final class HeaderView: NSView, NSDraggingSource {
    // Grabbing the header starts a repo-block drag — it must NOT also move the whole HUD (the panel
    // is movable by background). This was the reported bug: header drag moved both block and window.
    override var mouseDownCanMoveWindow: Bool { false }
    var menuProvider: (() -> NSMenu?)?
    var repoKey: String = ""
    var onDragBegin: (() -> Void)?          // let the app pause its rebuild while a drag is live
    private var mouseDownPoint: NSPoint?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === self { return self }
        var v: NSView? = hit
        while let cur = v, cur !== self {
            if cur is ClickableBadge || cur is NSButton { return hit }
            v = cur.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard abs(p.x - start.x) > 4 || abs(p.y - start.y) > 4 else { return }   // small threshold: a click isn't a drag
        mouseDownPoint = nil
        guard !repoKey.isEmpty else { return }
        let item = NSPasteboardItem()
        item.setString(repoKey, forType: repoBlockPBType)
        let di = NSDraggingItem(pasteboardWriter: item)
        var contents: NSImage? = nil
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size); img.addRepresentation(rep); contents = img
        }
        di.setDraggingFrame(bounds, contents: contents)
        onDragBegin?()
        beginDraggingSession(with: [di], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

// Marker type for a repo-group panel, so a column can pick its section blocks out of its subviews
// (to compute where a dropped block lands) — v6 #2.
final class SectionPanelView: NSView {}

// One masonry column, and the drop target for repo-block drags (v6 #2). It hosts the column's
// vertical stack of SectionPanelViews and, on drop, reports (key, colIndex, index-among-manual) so
// the app can persist the new placement. During a drag it draws a lavender insertion line at the
// boundary under the cursor. Cards inside register only for `.fileURL`, so a repoBlock drag skips
// them and resolves here.
final class ColumnDropView: NSView {
    var colIndex = 0
    weak var stack: NSStackView?
    var onDropBlock: ((_ key: String, _ col: Int, _ dropIndex: Int) -> Void)?
    var onDragActivity: (() -> Void)?
    private var indicator: NSView?

    private func hasBlock(_ s: NSDraggingInfo) -> Bool {
        s.draggingPasteboard.availableType(from: [repoBlockPBType]) != nil
    }
    // Panels top→bottom (arrangedSubviews order), each with its frame in this view's coords.
    private func panels() -> [(view: SectionPanelView, frame: NSRect)] {
        guard let stack = stack else { return [] }
        return stack.arrangedSubviews.compactMap { sub in
            guard let panel = sub as? SectionPanelView else { return nil }
            return (panel, panel.convert(panel.bounds, to: self))
        }
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard hasBlock(s) else { return [] }
        onDragActivity?(); updateIndicator(at: convert(s.draggingLocation, from: nil)); return .move
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard hasBlock(s) else { return [] }
        onDragActivity?(); updateIndicator(at: convert(s.draggingLocation, from: nil)); return .move
    }
    override func draggingExited(_ s: NSDraggingInfo?) { hideIndicator() }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        defer { hideIndicator() }
        guard hasBlock(s), let key = s.draggingPasteboard.string(forType: repoBlockPBType), !key.isEmpty else { return false }
        let p = convert(s.draggingLocation, from: nil)
        // Visual insert position: how many blocks in this column sit above the drop point (non-flipped:
        // a higher midY = visually higher). The app freezes the whole board on drop, so counting all
        // blocks (not just manually-placed ones) is what maps onto the final order.
        let dropIndex = panels().filter { $0.frame.midY > p.y }.count
        onDropBlock?(key, colIndex, dropIndex)
        return true
    }
    private func updateIndicator(at p: NSPoint) {
        let ps = panels()
        let insAll = ps.filter { $0.frame.midY > p.y }.count   // panels above the cursor (all groups)
        let lineY: CGFloat
        if ps.isEmpty { lineY = bounds.maxY - 2 }
        else if insAll == 0 { lineY = ps[0].frame.maxY + 2 }                 // above the topmost
        else if insAll >= ps.count { lineY = ps[ps.count - 1].frame.minY - 2 } // below the last
        else { lineY = (ps[insAll - 1].frame.minY + ps[insAll].frame.maxY) / 2 } // gap midpoint
        let ind = indicator ?? {
            let v = NSView(); v.wantsLayer = true
            v.layer?.backgroundColor = Cat.lavender.cgColor
            v.layer?.cornerRadius = 1.5
            addSubview(v); indicator = v; return v
        }()
        ind.isHidden = false
        ind.frame = NSRect(x: 2, y: lineY - 1.5, width: max(0, bounds.width - 4), height: 3)
    }
    private func hideIndicator() { indicator?.isHidden = true }
}

// The HUD's pictographic glyphs are SF Symbols across the board (2026-07-11): the color emoji
// they replace (📎🤖📁📌🅿…) came from a different visual family — mixed weights, baked-in colors
// that fight the Cat palette, and blurry at chip sizes. These two helpers are the shared plumbing:
// a configured (and optionally pre-tinted) symbol image for places that can't tint a template
// image themselves (NSTextAttachment, NSMenuItem), and a label whose leading glyph is a symbol
// riding inline with the text as an attachment.
func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold,
                 color: NSColor? = nil) -> NSImage? {
    var config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    if let color = color { config = config.applying(.init(paletteColors: [color])) }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

func symbolLabel(_ symbol: String, _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                 color: NSColor, symbolColor: NSColor? = nil, mono: Bool = false) -> NSTextField {
    let label = makeLabel(text, size: size, weight: weight, color: color, mono: mono)
    guard let img = symbolImage(symbol, size: size * 0.92, weight: .semibold,
                                color: symbolColor ?? color) else { return label }
    let font = label.font ?? NSFont.systemFont(ofSize: size)
    let attachment = NSTextAttachment()
    attachment.image = img
    // Scale the glyph to the text's point size and drop it slightly below the baseline so it
    // reads centered against lowercase — the attachment's default baseline-sitting looks lifted.
    let h = size * 1.05
    let w = img.size.height > 0 ? img.size.width * h / img.size.height : h
    attachment.bounds = NSRect(x: 0, y: (font.capHeight - h) / 2, width: w, height: h)
    // Attributed text ignores the field's lineBreakMode, so carry truncation in the string itself
    // (tail, not makeLabel's middle: every current caller is a leading-icon chip/title).
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    let s = NSMutableAttributedString(attachment: attachment)
    s.append(NSAttributedString(string: " " + text,
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
    label.attributedStringValue = s
    label.lineBreakMode = .byTruncatingTail
    return label
}

// An optional leading SF Symbol lets a badge stand for its label with just an icon (e.g. the
// artifact badge is a doc glyph + number, so N of them fit where "Artifact ×N" wouldn't).
func badge(_ text: String, symbol: String? = nil, symbolSize: CGFloat = 10, fg: NSColor, bg: NSColor, tip: String? = nil, action: @escaping () -> Void) -> ClickableBadge {
    let v = ClickableBadge()
    v.onClick = action
    v.toolTip = tip
    v.wantsLayer = true
    v.layer?.backgroundColor = bg.cgColor
    v.layer?.cornerRadius = 6
    let content = NSStackView()
    content.orientation = .horizontal
    content.spacing = 3
    content.alignment = .centerY
    content.translatesAutoresizingMaskIntoConstraints = false
    content.setHuggingPriority(.required, for: .horizontal)
    if let symbol = symbol,
       let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .bold)) {
        let iv = NSImageView(image: img)
        iv.contentTintColor = fg
        // NSImageView hugs weakly by default and would stretch to fill the badge, leaving the
        // pill's width ambiguous — auto-layout then flip-flops it between "hug" and "fill the
        // row" on each rebuild (a visible flicker). Pin it to the glyph size so it never grows.
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.setContentHuggingPriority(.required, for: .vertical)
        iv.setContentCompressionResistancePriority(.required, for: .horizontal)
        content.addArrangedSubview(iv)
    }
    if !text.isEmpty {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = fg
        content.addArrangedSubview(l)
    }
    v.addSubview(content)
    let inset: CGFloat = symbol == nil ? 8 : 6
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: v.topAnchor, constant: 1),
        content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -1),
        content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: inset),
        content.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -inset),
    ])
    v.setContentCompressionResistancePriority(.required, for: .horizontal)
    v.setContentHuggingPriority(.required, for: .horizontal)
    return v
}

// A tray button (icon + short label) that reports hover, so a self-drawn hint can replace
// NSToolTip — which never fires here (a nonactivating accessory panel is never the active
// window, the same reason the pointer cursor / app-activation don't work).
final class HoverButton: NSButton {
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var hoverBg: NSColor = Cat.surface1.withAlphaComponent(0.6)
    private var tracking: NSTrackingArea?
    convenience init(title: String) { self.init(frame: .zero); self.title = title; self.bezelStyle = .regularSquare }
    @objc func fire() { onPress?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = hoverBg.cgColor; onHover?(true) }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = .clear; onHover?(false) }
}

// A plain view that reports hover (used for the gauge's hint region).
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// 固定サイズモードの縦スクロール土台（HUDサイズ 2026-07-08）。パネルは borderless で背景ドラッグ移動
// するので、スクロールビュー越しでも mouseDownCanMoveWindow を通す（カード側は従来どおり false で拒否）。
// documentView は flipped にして内容がクリップ領域より短いとき上詰めになるようにする。
final class DragScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
               color: NSColor = Cat.text, mono: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                  : NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

func pill(_ text: String, color: NSColor) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
    v.layer?.cornerRadius = 9
    let l = makeLabel(text, size: 11, weight: .semibold, color: color)
    l.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(l)
    NSLayoutConstraint.activate([
        l.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
        l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -2),
        l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
        l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
    ])
    return v
}

// (repoHeader removed — the single-column row mode that used it is gone (v5fix3 #3); column mode
// uses repoColumnHeader instead.)

// A tiny monospace badge — model tier (FABLE / OPUS / …) and permission mode (PLAN / ⏵⏵ …).
func modelChip(_ info: ModelInfo) -> NSView { tinyChip(info.name, color: info.color) }

func tinyChip(_ text: String, color: NSColor, symbol: String? = nil) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
    v.layer?.cornerRadius = 6
    let l: NSTextField
    if let symbol = symbol {
        l = symbolLabel(symbol, text, size: 9, weight: .bold, color: color, mono: true)
    } else {
        l = NSTextField(labelWithString: text)
        l.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        l.textColor = color
    }
    l.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(l)
    NSLayoutConstraint.activate([
        l.topAnchor.constraint(equalTo: v.topAnchor, constant: 1),
        l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -1),
        l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
        l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
    ])
    v.setContentCompressionResistancePriority(.required, for: .horizontal)
    v.setContentHuggingPriority(.required, for: .horizontal)
    return v
}
