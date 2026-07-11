import AppKit

extension AppDelegate {
    // v5 card. `width` is the card's own width (contentWidth in row mode, columnWidth in a column).
    // `isChild` styles a child-session card (rendered inside a thread container, so no extra indent
    // here). `familyChildren`/`familyCollapsed` drive the parent's bottom family strip (count +
    // working count + collapsed summary; click toggles the fold) and the working-child rail mirror
    // (C7). `subtitle` disambiguates same-labelled sibling cards (A4).
    func rowView(for row: AgentRow, width: CGFloat, isChild: Bool = false,
                 familyChildren: [AgentRow] = [], familyCollapsed: Bool = false,
                 subtitle: String? = nil) -> NSView {
        let innerW = width - 26   // content width inside the card's 12/12 insets (minus a little slack)
        // Mirror a working child onto an otherwise-quiet parent (C7): an idle/blocked parent reads
        // as "still busy" via a green rail. Working Agent-tool subagents are family children too
        // (their own nested cards since 2026-07-10), so familyChildren covers both kinds.
        // A fork is a divergent copy, not sub-work of the root — a working fork must NOT make the root
        // read as busy (green mirror) or bump its "稼働中" count. The fork shows its own state on its
        // own card, so nothing is lost.
        let familyWorking = familyChildren.filter { $0.status == "working" && !$0.isFork }.count
        let childWorking = familyWorking > 0
        let mirror = childWorking && (row.status == "idle" || row.status == "blocked")
        // "waiting" = we just sent a reply to this agent and it hasn't unblocked yet.
        let waiting = !row.sessionId.isEmpty && row.sessionId == replyWaitingSession
        let elapsed = Date().timeIntervalSince(row.statusSince)
        // A blocked agent left waiting > 5 min gets a stronger (darker) card.
        let neglected = row.status == "blocked" && !waiting && elapsed > 300

        let card = RowView()
        card.sessionId = row.sessionId
        // A stop/rm in flight (deletingSessions): the card goes inert — no click/menu/drop wiring,
        // every hit swallowed by the RowView flag — and gets a centered spinner + dimmed face below.
        let deleting = !row.sessionId.isEmpty && deletingSessions.contains(row.sessionId)
        if deleting {
            card.interactionDisabled = true
            card.toolTip = L("停止・削除を実行中…", "stopping / removing…")
        } else {
            wireCardActions(card, row: row)   // left-click jump / ⌘-click reply / right-click menu / D&D (D)
        }
        card.wantsLayer = true
        // Left rail = the single source of truth for state colour (v5fix3 #2 — the round dot on line1
        // is gone, so this bar alone carries state): red error / peach blocked / green working /
        // gray idle·unknown (the one "finished/quiet" lane). A working child mirrors green onto the
        // otherwise-quiet idle lane. blocked also gets a faint peach card fill.
        let railColor: NSColor = {
            switch row.status {
            case "error":                 return Cat.red
            case "blocked":               return Cat.peach
            case "working":               return Cat.green
            default:                      return mirror ? Cat.green : Cat.surface1
            }
        }()
        // Card fill by state (v7): error/blocked get a faint state-colour wash — the loud part of
        // their signal is the top banner, not the fill. Everything else keeps the neutral surface.
        card.baseColor = {
            switch row.status {
            case "error":   return Cat.red.withAlphaComponent(0.10)
            case "blocked": return Cat.peach.withAlphaComponent(0.10)
            default:        return Cat.surface.withAlphaComponent(0.5)
            }
        }()
        card.layer?.backgroundColor = card.baseColor.cgColor
        card.layer?.cornerRadius = row.isSubagent ? 8 : 10
        card.layer?.masksToBounds = true
        // A subagent/teammate card is a compact, dashed-outline chip rather than a full card: it's a
        // read-only window into work happening inside a parent, so it should read as "attached to"
        // the parent, not a session of its own (2026-07-11). The dash sits in the state colour, so
        // the colour still tells state; the border shape (not a solid rail) says "subagent".
        if row.isSubagent {
            let dash = CAShapeLayer()
            dash.strokeColor = railColor.withAlphaComponent(0.85).cgColor
            dash.fillColor = nil
            dash.lineWidth = 1
            dash.lineDashPattern = [4, 2]
            card.subagentDash = dash
            card.layer?.addSublayer(dash)
        }
        // The rail: a 3px colour bar down the left edge (full cards only — a subagent uses its dash).
        let rail = NSView()
        rail.wantsLayer = true
        rail.layer?.backgroundColor = railColor.cgColor
        rail.isHidden = row.isSubagent
        rail.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rail)

        // State-change colour transition in place (B4): if this session's rendered state changed
        // since last rebuild, fade the rail (and card fill) from neutral to the new colour.
        if let prev = renderedStatus[row.sessionId], prev != row.status {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = Cat.surface1.cgColor; a.duration = 0.4
            rail.layer?.add(a, forKey: "railfade")
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // working = alive (v7): a faint green tint over the card plus a breathing inset border.
        // This is the ONLY continuously animated state. A working child mirrored onto a quiet idle
        // parent breathes too (C7). Layers are recreated on every rebuild, so the animation is
        // simply re-attached each time.
        if !row.isSubagent, row.status == "working" || (mirror && row.status == "idle") {
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.backgroundColor = Cat.green.withAlphaComponent(0.07).cgColor
            tint.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(tint)
            NSLayoutConstraint.activate([
                tint.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                tint.topAnchor.constraint(equalTo: card.topAnchor),
                tint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ])
            card.layer?.borderWidth = 1.5
            if reduceMotion {
                card.layer?.borderColor = Cat.green.withAlphaComponent(0.5).cgColor
            } else {
                card.layer?.borderColor = Cat.green.withAlphaComponent(0.9).cgColor
                let blink = CABasicAnimation(keyPath: "borderColor")
                blink.fromValue = Cat.green.withAlphaComponent(0.9).cgColor
                blink.toValue = Cat.green.withAlphaComponent(0.22).cgColor
                blink.duration = 0.7
                blink.autoreverses = true
                blink.repeatCount = .infinity
                blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                card.layer?.add(blink, forKey: "workblink")
            }
        } else if row.status == "error" {
            card.layer?.borderWidth = 1.5
            card.layer?.borderColor = Cat.red.withAlphaComponent(0.55).cgColor
        }

        // done/idle recede (v7): finished work dims to 75%, read/idle sessions to 50%, so the lit
        // cards are the ones that still need a shepherd. Hover restores full brightness.
        let restingAlpha: CGFloat = {
            switch row.status {
            case "working", "blocked", "error": return 1.0
            default: return mirror ? 1.0 : 0.5   // idle / unknown
            }
        }()
        card.alphaValue = restingAlpha
        if restingAlpha < 1 {
            card.onHoverChanged = { [weak card] entered in
                card?.animator().alphaValue = entered ? 1 : restingAlpha
            }
        }

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 3
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        // Attention states carry a 19px status banner across the card's top (v7) — the content
        // stack starts below it. A parent with child sessions reserves a strip along the bottom
        // for the family fold control + collapsed summary (2026-07-08).
        let bannerH: CGFloat = (row.status == "error" || row.status == "blocked") ? 19 : 0
        let familyStripH: CGFloat = familyChildren.isEmpty ? 0 : 20
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rail.topAnchor.constraint(equalTo: card.topAnchor),
            rail.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 3),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: (row.isSubagent ? 5 : 8) + bannerH),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -((row.isSubagent ? 6 : 9) + familyStripH)),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: row.isSubagent ? 10 : 12),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: row.isSubagent ? -10 : -12),
            card.widthAnchor.constraint(equalToConstant: width),
        ])

        // Status banner (v7): a static strip that says WHY the card wants attention — error is a
        // solid red band, blocked a peach one carrying the waiting time (and "neglected" past 5 min).
        // No animation by design; the words are the signal.
        if bannerH > 0 {
            let isError = row.status == "error"
            let bannerView = NSView()
            bannerView.wantsLayer = true
            bannerView.layer?.backgroundColor =
                (isError ? Cat.red : Cat.peach.withAlphaComponent(0.9)).cgColor
            bannerView.translatesAutoresizingMaskIntoConstraints = false
            let bl: NSTextField
            if isError {
                bl = symbolLabel("exclamationmark.triangle.fill", "ERROR — " + L("対応が必要", "needs attention"),
                                 size: 9.5, weight: .bold, color: Cat.crust, mono: true)
            } else {
                bl = makeLabel("? " + L("応答待ち — ", "waiting — ") + formatDuration(elapsed)
                                   + (neglected ? L(" 放置中", " · neglected") : ""),
                               size: 9.5, weight: .bold, color: Cat.crust, mono: true)
            }
            bl.lineBreakMode = .byTruncatingTail
            bl.translatesAutoresizingMaskIntoConstraints = false
            bannerView.addSubview(bl)
            card.addSubview(bannerView)
            NSLayoutConstraint.activate([
                bannerView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                bannerView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                bannerView.topAnchor.constraint(equalTo: card.topAnchor),
                bannerView.heightAnchor.constraint(equalToConstant: bannerH),
                bl.centerYAnchor.constraint(equalTo: bannerView.centerYAnchor),
                bl.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 10),
                bl.trailingAnchor.constraint(lessThanOrEqualTo: bannerView.trailingAnchor, constant: -10),
            ])
        }

        // Uncommitted dog-ear (v7): an amber fold in the top-right corner whenever the worktree has
        // uncommitted changes. Presence only — the ±N count stays in the meta strip. (A radial
        // corner glow was tried 2026-07-08 and rejected as too faint — the crisp triangle stays.)
        if (row.changedFiles ?? 0) > 0 {
            let fold = NSView()
            fold.wantsLayer = true
            fold.translatesAutoresizingMaskIntoConstraints = false
            let tri = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 15))       // top-left of the 15×15 corner box (y-up)
            path.addLine(to: CGPoint(x: 15, y: 15))   // top-right
            path.addLine(to: CGPoint(x: 15, y: 0))    // bottom-right
            path.closeSubpath()
            tri.path = path
            tri.fillColor = Cat.amber.withAlphaComponent(0.9).cgColor
            fold.layer?.addSublayer(tri)
            card.addSubview(fold)
            NSLayoutConstraint.activate([
                fold.topAnchor.constraint(equalTo: card.topAnchor),
                fold.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                fold.widthAnchor.constraint(equalToConstant: 15),
                fold.heightAnchor.constraint(equalToConstant: 15),
            ])
        }

        // line 1 = the work title, promoted to the primary label (addendum): <activity> #issue
        // [spacer] [remote]. Primary text = activity (OSC title → last_prompt); only when that's
        // unavailable does it fall back to row.label (the session name). The state dot is gone
        // (v5fix3 #2) — the left rail carries state. The MODEL chip moved to its own chip row
        // below (with the permission-mode chip) so neither it nor the title gets truncated.
        let line1 = NSStackView()
        line1.orientation = .horizontal
        line1.spacing = 6
        line1.alignment = .top   // title may span 2 lines (v5fix2 #4); toggle/chip stay top-aligned
        var titleText = (row.activity.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }) ?? row.label
        if let issue = row.issueNo, !titleText.contains("#\(issue)") { titleText += "  #\(issue)" }
        // Leading icon: a subagent card is marked with sparkles (was the 🤖 label prefix); a title
        // that is a mid-call tool line keeps Transcript's "⚙ " data marker but renders it as a
        // gear symbol. Tool-call wins when both apply — the nesting already says "subagent".
        var titleSymbol: String? = row.isSubagent ? "sparkles" : nil
        if titleText.hasPrefix("⚙ ") { titleSymbol = "gearshape"; titleText = String(titleText.dropFirst(2)) }
        let titleSize: CGFloat = row.isSubagent ? 11 : 13.5
        let title = titleSymbol.map {
            symbolLabel($0, titleText, size: titleSize, weight: .semibold, color: Cat.text,
                        symbolColor: $0 == "sparkles" ? Cat.mauve : Cat.overlay)
        } ?? makeLabel(titleText, size: titleSize, weight: .semibold, color: Cat.text)
        // Wrap long work titles to at most 2 lines, then ellipsize (v5fix2 #4). preferredMaxLayoutWidth
        // reserves a sliver for the remote mark so a title that overflows wraps (rather than the
        // whole line1 stretching). The model chip no longer shares this line.
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.preferredMaxLayoutWidth = max(innerW - 24, 80)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        title.setContentHuggingPriority(.required, for: .vertical)
        line1.addArrangedSubview(title)
        if let sub = subtitle, !sub.isEmpty {
            let cap = makeLabel(sub, size: 10.5, color: Cat.overlay)
            cap.lineBreakMode = .byTruncatingTail
            cap.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            line1.addArrangedSubview(cap)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line1.addArrangedSubview(spacer)
        // (The old top-right "⌄N" fold toggle lived here — replaced by the bottom family strip,
        // which is far harder to miss. 2026-07-08.)
        // A VSCode-family session wears the code-brackets mark where the terminal rows wear none —
        // it's the one board glance that says "this card opens an editor window, not a terminal".
        if row.backend == .vscode {
            let mark = NSImageView()
            mark.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
            mark.contentTintColor = Cat.overlay
            mark.toolTip = editorDisplayName(row.editorBundleId)
            mark.setContentCompressionResistancePriority(.required, for: .horizontal)
            line1.addArrangedSubview(mark)
        }
        if remoteEnabledSessions.contains(row.sessionId) {
            let mark = NSImageView()
            mark.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
            mark.contentTintColor = Cat.overlay
            mark.setContentCompressionResistancePriority(.required, for: .horizontal)
            line1.addArrangedSubview(mark)
        }
        line1.widthAnchor.constraint(equalToConstant: innerW).isActive = true
        inner.addArrangedSubview(line1)

        // Chip row (2026-07-08): permission mode + model on their own line — sharing line 1 with
        // the title truncated both the chips and the title. Mode first (PLAN / ⏵⏵ EDITS / BYPASS…,
        // from the hook's permission_mode; "default" shows nothing), then the model tier, and last
        // BG for a cc-daemon background agent (2026-07-09) — the one chip that changes what "close"
        // does, so it's worth seeing at a glance.
        let modeChip = permissionModeChip(row.permissionMode)
        if modeChip != nil || row.model != nil || row.isBackground {
            let chips = NSStackView()
            chips.orientation = .horizontal
            chips.spacing = 6
            chips.alignment = .centerY
            if let pm = modeChip { chips.addArrangedSubview(tinyChip(pm.label, color: pm.color)) }
            if let m = row.model { chips.addArrangedSubview(modelChip(m)) }
            if row.isBackground { chips.addArrangedSubview(tinyChip("BG", color: Cat.mauve)) }
            // 🅿 a live worker parked idle — holding memory, likely forgotten (see parkedChip).
            if let parked = parkedChip(row) { chips.addArrangedSubview(tinyChip(parked.label, color: parked.color, symbol: "parkingsign")) }
            inner.addArrangedSubview(chips)
            chips.widthAnchor.constraint(lessThanOrEqualToConstant: innerW).isActive = true
        }

        // The work title now lives on line 1 (addendum), so the old "▸ headline" and the done "✓
        // result" utterance rows are gone — the card is title + meta + gauge. A blocked agent still
        // gets its pending question as a one-line "? …" preview (behind showBlockedQuestion), since
        // that's what tells you what it's asking. Reply (⌘-click / menu) is independent of this.
        // A background worker's `needs` leads: cc-daemon states the decision it wants ("confirm the
        // marking style … or provide direction") where lastMessage is only the tail of what it said.
        if showBlockedQuestion, row.status == "blocked",
           let lm = row.needs ?? row.lastMessage, !lm.isEmpty {
            let last = makeLabel("? " + lm, size: 11.5, weight: .semibold, color: Cat.peach)
            last.lineBreakMode = .byTruncatingTail
            last.maximumNumberOfLines = 1
            inner.addArrangedSubview(last)
            last.widthAnchor.constraint(lessThanOrEqualToConstant: innerW).isActive = true
        }

        // "reply sent, waiting" transient line (kept from v4) — only while we're awaiting an unblock.
        if waiting {
            let wline = NSStackView(); wline.orientation = .horizontal; wline.spacing = 6
            if !replyWaitingTimedOut {
                let spin = NSProgressIndicator()
                spin.style = .spinning; spin.controlSize = .small
                spin.setContentHuggingPriority(.required, for: .horizontal)
                spin.startAnimation(nil)
                wline.addArrangedSubview(spin)
            }
            wline.addArrangedSubview(makeLabel(
                replyWaitingTimedOut ? L("まだ応答待ち（再回答可）", "still waiting (resend ok)") : L("回答済み・反応待ち", "reply sent · waiting"),
                size: 11, color: replyWaitingTimedOut ? Cat.peach : Cat.subtext))
            inner.addArrangedSubview(wline)
        }

        // deliverables: favicon + title Artifact badges / PR badge (A1, C5).
        let deliverables = deliverableBadges(for: row)
        if !deliverables.isEmpty {
            let dline = NSStackView(views: deliverables)
            dline.orientation = .horizontal; dline.spacing = 6; dline.alignment = .leading
            inner.addArrangedSubview(dline)
        }

        // meta strip (C4): elapsed · ±changes · 🤖N · context mini-bar+% — icons, no state words.
        let meta = NSStackView()
        meta.orientation = .horizontal; meta.spacing = 10; meta.alignment = .centerY
        func metaLabel(_ s: String, color: NSColor = Cat.overlay) -> NSTextField {
            let l = makeLabel(s, size: 10.5, color: color); l.setContentCompressionResistancePriority(.required, for: .horizontal); return l
        }
        if !waiting { meta.addArrangedSubview(metaLabel(formatDuration(elapsed))) }
        if let c = row.changedFiles, c > 0 { meta.addArrangedSubview(metaLabel("±\(c)")) }
        func metaSymbolLabel(_ symbol: String, _ s: String, color: NSColor) -> NSTextField {
            let l = symbolLabel(symbol, s, size: 10.5, color: color)
            l.setContentCompressionResistancePriority(.required, for: .horizontal); return l
        }
        if row.sessionId == dropSentSession { meta.addArrangedSubview(metaSymbolLabel("paperclip", L("送信済み", "sent"), color: Cat.green)) }
        if row.stale { meta.addArrangedSubview(metaSymbolLabel("clock", "stale?", color: Cat.peach)) }
        // (The 🤖N working-subagent count chip is gone, 2026-07-10: a working subagent is its own
        // nested card now, so a number here would just repeat what the board already shows.)
        // Child mirror (C7): a quiet parent whose child is working reads as still busy.
        if mirror {
            meta.addArrangedSubview(metaSymbolLabel("sparkles", L("子作業中", "child working"), color: Cat.green))
        }
        // Context = a small pie + % pinned to the right end of the meta strip (v7 — the full-width
        // bottom gauge is gone). Grey below 60% so it melts into the card, yellow from 60%, red
        // from 85%. Hovering it shows the remaining-tokens hint on the shared hint line.
        if let pct = row.contextPct {
            let p = min(max(pct, 0), 1)
            let color: NSColor = p >= 0.85 ? Cat.red : p >= 0.60 ? Cat.yellow : Cat.overlay
            let pusher = NSView()   // flexible gap that shoves the pie to the right edge
            pusher.setContentHuggingPriority(.init(1), for: .horizontal)
            meta.addArrangedSubview(pusher)
            let pie = NSView()
            pie.wantsLayer = true
            pie.translatesAutoresizingMaskIntoConstraints = false
            let track = CAShapeLayer()
            track.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
            track.fillColor = Cat.overlay.withAlphaComponent(0.22).cgColor
            let wedge = CAShapeLayer()
            let wpath = CGMutablePath()
            let center = CGPoint(x: 5, y: 5)
            wpath.move(to: center)
            wpath.addArc(center: center, radius: 5, startAngle: .pi / 2,
                         endAngle: .pi / 2 - 2 * .pi * p, clockwise: true)   // 12 o'clock, clockwise
            wpath.closeSubpath()
            wedge.path = wpath
            wedge.fillColor = color.cgColor
            pie.layer?.addSublayer(track)
            pie.layer?.addSublayer(wedge)
            let pctLabel = metaLabel("\(Int(p * 100))%", color: color)
            // Remaining tokens against the model's real window (1M for fable/opus — 200k was
            // wrong for them and pinned the pie at 100%).
            let windowK = contextWindow(model: row.model?.raw) / 1000
            let remaining = Int(Double(windowK) * (1 - p))
            let ctxHint = L("コンテキスト \(Int(p * 100))%（窓 \(windowK)k）・ 残り \(remaining)k tokens",
                            "context \(Int(p * 100))% of \(windowK)k · \(remaining)k tokens left")
            let ctxBox = HoverView()
            ctxBox.onHover = { [weak self] entered in self?.setHint(entered ? ctxHint : nil) }
            ctxBox.translatesAutoresizingMaskIntoConstraints = false
            let ctxStack = NSStackView(views: [pie, pctLabel])
            ctxStack.orientation = .horizontal
            ctxStack.spacing = 4
            ctxStack.alignment = .centerY
            ctxStack.translatesAutoresizingMaskIntoConstraints = false
            ctxBox.addSubview(ctxStack)
            NSLayoutConstraint.activate([
                pie.widthAnchor.constraint(equalToConstant: 10),
                pie.heightAnchor.constraint(equalToConstant: 10),
                ctxStack.topAnchor.constraint(equalTo: ctxBox.topAnchor),
                ctxStack.bottomAnchor.constraint(equalTo: ctxBox.bottomAnchor),
                ctxStack.leadingAnchor.constraint(equalTo: ctxBox.leadingAnchor),
                ctxStack.trailingAnchor.constraint(equalTo: ctxBox.trailingAnchor),
            ])
            ctxBox.setContentHuggingPriority(.required, for: .horizontal)
            meta.addArrangedSubview(ctxBox)
        }
        if meta.arrangedSubviews.count > 0 {
            inner.addArrangedSubview(meta)
            // With a context pie the strip spans the full width (the pusher right-aligns the pie);
            // otherwise it just hugs its items as before.
            if row.contextPct != nil {
                meta.widthAnchor.constraint(equalToConstant: innerW).isActive = true
            } else {
                meta.widthAnchor.constraint(lessThanOrEqualToConstant: innerW).isActive = true
            }
        }

        // (The background card's hover attach/copy button was removed on 2026-07-10: clicking the
        // card face attaches — live worker and finished record alike — see wireCardActions.)

        // Family strip (2026-07-08): a parent with child sessions carries a full-width strip along
        // the card's bottom — fold caret + child/working counts, plus (when collapsed) the children's
        // status dots and the most-urgent child's one-liner, absorbing the old separate summary card.
        // The whole strip toggles the fold via a transparent full-size button overlay (the card's
        // hitTest only lets NSButton descendants keep their clicks); hovering it while collapsed
        // opens the family peek. Replaces the old top-right "⌄N" toggle.
        if !familyChildren.isEmpty {
            let sid = row.sessionId
            let strip = NSView()
            strip.wantsLayer = true
            strip.layer?.backgroundColor = Cat.surface1.withAlphaComponent(0.35).cgColor
            strip.translatesAutoresizingMaskIntoConstraints = false

            // Forks render first, so count them first: "⑂ fork N ・ 子 M 件 ・ 稼働中 K".
            let forkCount = familyChildren.filter { $0.isFork }.count
            let realChildren = familyChildren.count - forkCount
            var parts: [String] = []
            if forkCount > 0 { parts.append(L("fork \(forkCount)", forkCount == 1 ? "1 fork" : "\(forkCount) forks")) }
            if realChildren > 0 { parts.append(L("子 \(realChildren) 件", realChildren == 1 ? "1 child" : "\(realChildren) children")) }
            if familyWorking > 0 { parts.append(L("稼働中 \(familyWorking)", "\(familyWorking) working")) }
            let counts = symbolLabel(familyCollapsed ? "chevron.right" : "chevron.down",
                                     parts.joined(separator: L(" ・ ", " · ")), size: 10.5, weight: .bold,
                                     color: familyWorking > 0 ? Cat.green : Cat.subtext)
            counts.setContentCompressionResistancePriority(.required, for: .horizontal)
            let content = NSStackView(views: [counts])
            content.orientation = .horizontal
            content.spacing = 6
            content.alignment = .centerY
            if familyCollapsed {
                // Status dots + the most-urgent child's headline, straight from the old summary card.
                let dots = NSStackView()
                dots.orientation = .horizontal; dots.spacing = 3
                for c in familyChildren.prefix(10) {
                    // A fork shows the same branch symbol here as its expanded node marker, so the
                    // collapsed strip mirrors it rather than showing a fork as a round status dot.
                    let d: NSView
                    if c.isFork {
                        let iv = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "fork")?
                            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) ?? NSImage())
                        iv.contentTintColor = Cat.mauve
                        d = iv
                    } else {
                        d = makeLabel("●", size: 8, color: style(for: c.status).dot)
                    }
                    d.setContentCompressionResistancePriority(.required, for: .horizontal)
                    dots.addArrangedSubview(d)
                }
                content.addArrangedSubview(dots)
                let urgent = familyChildren.first { $0.status == "blocked" }
                    ?? familyChildren.first { $0.status == "working" }
                if let u = urgent {
                    let isQ = u.status == "blocked"
                    let hl = makeLabel((isQ ? "? " : "") + (u.needs ?? u.lastMessage ?? u.activity ?? u.label),
                                       size: 10.5, color: isQ ? Cat.peach : Cat.subtext)
                    hl.lineBreakMode = .byTruncatingTail
                    content.addArrangedSubview(hl)
                }
            }
            content.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(content)

            // Transparent click/hover surface on top — an NSButton so the card's hitTest lets it through.
            let overlay = HoverButton(title: "")
            overlay.isBordered = false
            overlay.target = overlay; overlay.action = #selector(HoverButton.fire)
            overlay.onPress = { [weak self] in self?.toggleFamily(sid) }
            let children = familyChildren
            overlay.onHover = { [weak self, weak strip] entered in
                guard let self = self else { return }
                self.setHint(entered
                    ? (familyCollapsed ? L("クリックで子カードを展開", "click to unfold the children")
                                       : L("クリックで子カードを折りたたむ", "click to fold the children"))
                    : nil)
                if familyCollapsed {
                    if entered, let s = strip { self.showFamilyPeek(children: children, from: s) }
                    else { self.scheduleFamilyPeekClose() }
                }
            }
            overlay.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(overlay)

            card.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                strip.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                strip.heightAnchor.constraint(equalToConstant: familyStripH),
                content.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(lessThanOrEqualTo: strip.trailingAnchor, constant: -8),
                content.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
                overlay.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: strip.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            ])
        }

        // Stop/rm in flight: a scrim dims the face (without dimming the spinner above it) and a
        // centered spinner says "in progress". Spinning is plain view animation, so it runs fine on
        // this never-active panel — unlike the NSToolTip/NSCursor class of traps.
        if deleting {
            let scrim = NSView(); scrim.wantsLayer = true
            scrim.layer?.backgroundColor = Cat.base.withAlphaComponent(0.55).cgColor
            scrim.layer?.cornerRadius = card.layer?.cornerRadius ?? 0
            scrim.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(scrim)
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.isIndeterminate = true
            spinner.controlSize = .regular
            spinner.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(spinner)
            NSLayoutConstraint.activate([
                scrim.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                scrim.topAnchor.constraint(equalTo: card.topAnchor),
                scrim.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            ])
            spinner.startAnimation(nil)
        }

        return card
    }

    // Deliverable badges for a card: the unified PR badge, then Artifact badges rendered as
    // "<favicon> <title> ↗" (A1/C5). 1–2 artifacts show directly; 3+ collapse to the latest plus a
    // "×N" chip opening the full list.
    func deliverableBadges(for row: AgentRow) -> [NSView] {
        var out: [NSView] = []
        if let pr = row.prNo {
            let ci = row.ciState
            // CI outcome leads the badge as a symbol (was a " ✓/✗/●" glyph glued into the text).
            let ciSymbol = ci.map { $0 == .pass ? "checkmark" : $0 == .fail ? "xmark" : "circle.dashed" }
            let fail = ci == .fail
            out.append(badge("PR #\(pr) ↗", symbol: ciSymbol, fg: fail ? Cat.red : Cat.teal,
                             bg: (fail ? Cat.red : Cat.teal).withAlphaComponent(0.15), tip: row.prUrl) {
                if let u = row.prUrl.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(u) }
            })
        }
        for link in row.links where link.label == "PR" && row.prNo == nil {
            out.append(badge("PR ↗", fg: Cat.teal, bg: Cat.teal.withAlphaComponent(0.14), tip: link.url) {
                if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }
            })
        }
        // "<favicon> <title-prefix> ↗" for one Artifact.
        func artifactBadge(_ link: AgentLink) -> NSView {
            // A session-chosen favicon emoji is that artifact's identity — keep it. Only the
            // fallback doc glyph joins the SF Symbol family.
            let title = link.title.map { String($0.prefix(18)) } ?? "Artifact"
            let text = link.favicon.map { "\($0) \(title) ↗" } ?? "\(title) ↗"
            return badge(text, symbol: link.favicon == nil ? "doc.text" : nil,
                         fg: Cat.blue, bg: Cat.blue.withAlphaComponent(0.2),
                         tip: (link.title ?? "Artifact") + "\n" + link.url) {
                if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }
            }
        }
        let artifacts = row.links.filter { $0.label == "Artifact" }
        if artifacts.count <= 2 {
            for link in artifacts { out.append(artifactBadge(link)) }
        } else if let latest = artifacts.last {
            out.append(artifactBadge(latest))
            let all = artifacts
            let chip = badge("×\(artifacts.count)", symbol: "doc.on.doc", symbolSize: 12,
                             fg: Cat.blue, bg: Cat.blue.withAlphaComponent(0.16),
                             tip: L("すべての Artifact を一覧", "list all \(artifacts.count) artifacts")) {}
            chip.onClick = { [weak self, weak chip] in if let c = chip { self?.showLinksMenu(all, from: c) } }
            out.append(chip)
        }
        return out
    }

    func toggleFamily(_ parentSessionId: String) {
        if collapsedFamilies.contains(parentSessionId) { collapsedFamilies.remove(parentSessionId) }
        else { collapsedFamilies.insert(parentSessionId) }
        defaults.set(Array(collapsedFamilies), forKey: "collapsedFamilies")
        rebuild(rows: lastRows)
    }

    // Wrap a child card in a thread container (C7, 案A): a 2px vertical connector + a node marker,
    // the card indented 20px. No box around the family. A normal child gets the round state-coloured
    // dot; a fork (isFork — same conversation as the root above it) gets a ⑂ branch glyph instead, so
    // "this is a fork" reads at a glance without leaning on the caption (2026-07-09).
    func threadChild(_ card: NSView, state: String, isFork: Bool = false, width: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView(); line.wantsLayer = true
        line.layer?.backgroundColor = Cat.surface1.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        // The node sits over the connector with an opaque base fill so the line doesn't cross it.
        let node = NSView(); node.wantsLayer = true
        node.layer?.backgroundColor = Cat.base.cgColor
        node.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        container.addSubview(card)
        container.addSubview(node)
        var nodeConstraints: [NSLayoutConstraint]
        if isFork {
            // A clean git-branch symbol on a base disc that masks the connector — the line-art branch
            // icon reads as "fork" far better (and looks far less like a loud blob) than the coloured
            // ⑂ badge it replaces (2026-07-09).
            node.layer?.backgroundColor = Cat.base.cgColor
            node.layer?.cornerRadius = 8
            let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "fork")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) ?? NSImage())
            icon.contentTintColor = Cat.mauve
            icon.translatesAutoresizingMaskIntoConstraints = false
            node.addSubview(icon)
            nodeConstraints = [
                node.widthAnchor.constraint(equalToConstant: 16),
                node.heightAnchor.constraint(equalToConstant: 16),
                node.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                icon.centerXAnchor.constraint(equalTo: node.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: node.centerYAnchor),
            ]
        } else {
            node.layer?.cornerRadius = 4.5
            node.layer?.borderWidth = 2
            node.layer?.borderColor = (state == "working" ? Cat.green : state == "blocked" ? Cat.peach : Cat.surface1).cgColor
            nodeConstraints = [
                node.widthAnchor.constraint(equalToConstant: 9),
                node.heightAnchor.constraint(equalToConstant: 9),
                node.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            ]
        }
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 2),
            node.centerXAnchor.constraint(equalTo: line.centerXAnchor),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: container.topAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: width),
        ] + nodeConstraints)
        return container
    }

    // (familySummaryView — the separate collapsed-family summary card — was absorbed into the
    // parent card's bottom family strip on 2026-07-08.)

    // Wire a card's mouse/drag actions (D). Left-click opens the session (openRow);
    // ⌘-click on a blocked, sendable card jumps straight to the reply box (D2); right-click opens
    // the context menu (D1); file drop sends to the session (D3, unchanged).
    func wireCardActions(_ card: RowView, row: AgentRow) {
        if row.backend == .zellij {
            card.onClick = { [weak self] in self?.openRow(row) }
            card.toolTip = L("クリック: zellij を開く / 右クリック: メニュー", "click: attach zellij / right-click: menu")
        } else if row.backend == .vscode {
            let editor = editorDisplayName(row.editorBundleId)
            card.onClick = { [weak self] in self?.openRow(row) }
            card.toolTip = L("クリック: \(editor) でフォルダを開く / 右クリック: メニュー",
                             "click: open the folder in \(editor) / right-click: menu")
        } else if row.isBackground {
            // A cc-daemon background session has no terminal of its own, but `claude attach <id>`
            // in a Ghostty window is one click away (2026-07-10) — the native teams route, same
            // command the agent view uses. A live worker's TUI opens in place (detaching keeps it
            // running); a finished record is resumed by the same command, so both click the same way.
            let id = shortSessionId(row.sessionId)
            card.onClick = { [weak self] in self?.openRow(row) }
            card.toolTip = removableRecord(row) == nil
                ? L("端末なしでバックグラウンド実行中のセッション（駐機中はメモリを保持し続けます）。クリック: attach で開く（claude attach \(id)）／右クリック→停止でメモリ解放",
                    "a background session running without a terminal (a parked worker keeps holding memory). click: open it (`claude attach \(id)`) / right-click → stop to free it")
                : L("終了済みのバックグラウンドセッションの記録。クリック: attach で開いて再開（claude attach \(id)）／右クリック: 記録を削除",
                    "a finished background session record. click: attach to resume it (`claude attach \(id)`) / right-click: delete the record")
        } else if row.isSubagent {
            // A teammate lives inside its parent's process: no terminal, no pid, no attach route
            // (verified 2026-07-10) — the card is a read-only window into its live transcript.
            card.toolTip = L("親セッション内で動く teammate（サブエージェント）。端末を持たないため開けません — 操作は親セッションから行ってください",
                             "a teammate running inside its parent session — no terminal to open; steer it from the parent")
        } else {
            // Started outside zellij and not a background worker: there's nowhere to jump, so the
            // click is a no-op and the explanation stays in the tooltip / hover hint.
            card.toolTip = L("zellij の外で起動されたセッションのため、Shepherd からは場所が分からず開けません（起動元のターミナルで操作してください）",
                             "started outside zellij, so Shepherd doesn't know where it lives — use its own terminal")
        }
        if row.status == "blocked", row.replyable {
            card.onCmdClick = { [weak self, weak card] in if let c = card { self?.showReply(for: row, from: c) } }
        }
        card.menuProvider = { [weak self, weak card] in
            guard let self = self, let card = card else { return nil }
            return self.buildCardMenu(for: row, anchor: card)
        }
        if row.sendable {
            card.registerForDraggedTypes([.fileURL])
            card.dropLabelText = L("ここにドロップして \(row.label) に送る", "drop to send to \(row.label)")
            card.onDragEnter = { [weak self, weak card] in if let c = card { self?.setDragTarget(c) } }
            card.onDragExit = { [weak self, weak card] in if let c = card { self?.dragExited(c) } }
            card.onDrop = { [weak self, weak card] urls in if let c = card { self?.handleDrop(urls, row: row, anchor: c) } }
        }
    }

    // Right-click context menu for a card (D1), returned to RowView.menu(for:) so AppKit shows it
    // natively at the cursor (修正3). Header = the directory + branch moved off the card face (C6).
    // blocked cards get "回答" first; then open/jump, remote-control, capture, pin, close.
    // `anchor` is the card the popovers (reply) attach to.
    func buildCardMenu(for row: AgentRow, anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // dir + branch header (disabled caption items)
        if !row.dirPath.isEmpty {
            let dir = ClosureMenuItem(row.dirPath, enabled: false, nil)
            dir.image = symbolImage(row.isWorktree ? "arrow.triangle.branch" : "folder", size: 11)
            menu.addItem(dir)
        }
        if let b = row.branch {
            let br = ClosureMenuItem(b + (row.changedFiles.map { " · ±\($0)" } ?? ""), enabled: false, nil)
            br.image = symbolImage("arrow.branch", size: 11)
            menu.addItem(br)
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }

        let sendable = row.sendable
        if row.status == "blocked", row.replyable {
            menu.addItem(ClosureMenuItem(L("回答する", "Reply")) { [weak self, weak anchor] in
                if let a = anchor { self?.showReply(for: row, from: a) }
            })
        }
        // open / jump
        if row.backend == .zellij {
            menu.addItem(ClosureMenuItem(L("zellij を開く ↗", "Attach zellij ↗")) { [weak self] in self?.openRow(row) })
        } else if row.backend == .vscode {
            let editor = editorDisplayName(row.editorBundleId)
            menu.addItem(ClosureMenuItem(L("\(editor) で開く ↗", "Open in \(editor) ↗")) { [weak self] in self?.openRow(row) })
        } else if row.isBackground {
            let id = shortSessionId(row.sessionId)
            menu.addItem(ClosureMenuItem(L("attach で開く ↗", "Attach ↗")) { [weak self] in self?.openRow(row) })
            menu.addItem(ClosureMenuItem(L("claude attach \(id) をコピー", "Copy `claude attach \(id)`")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("claude attach \(id)", forType: .string)
            })
        }
        if sendable {
            menu.addItem(ClosureMenuItem(L("遠隔操作（/remote-control）", "Remote-control")) { [weak self] in self?.remoteControlRow(row) })
            menu.addItem(ClosureMenuItem(L("範囲を撮影して送る", "Capture a region & send")) { [weak self] in self?.captureAndSendRow(row) })
        }
        // If this repo group is manually placed (dragged to a column), offer to release it back to
        // auto-fill. Manual *placement* is by dragging the header — there's no menu action for it.
        // Mirrors repoGroupKey (Models.swift): repo identity, header (= repoName), else the shared
        // "other" section — a row-derived key would never match the section's.
        let key = row.repoKey ?? row.repoName ?? otherSectionKey
        if manualLayout.contains(where: { $0.key == key }) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("自動配置に戻す", "Reset to auto layout")) { [weak self] in
                self?.clearManual(key)
            })
        }
        // close: sessions are only offered a stop once they're finished (idle) — stopping an actively-working
        // bare session would cut its turn. The wording names what actually happens, since a background
        // agent leaves the daemon roster while an interactive session is simply terminated. A daemon
        // spare gets nothing (closeMethod → .unavailable).
        let method = closeMethod(for: row)
        let finished = row.status == "idle"
        let closeTitle: String?
        switch method {
        case .stopBackgroundAgent where finished: closeTitle = L("バックグラウンドを停止（claude stop）", "Stop background agent")
        case .stopSession where finished: closeTitle = L("セッションを終了する", "End session")
        case .stopBackgroundAgent, .stopSession, .unavailable: closeTitle = nil
        }
        if let closeTitle = closeTitle {
            let clean = (row.changedFiles ?? 0) == 0
            menu.addItem(.separator())
            let close = ClosureMenuItem(closeTitle) { [weak self] in
                if clean { self?.closeWorkspace(row) }
                else { self?.flashHint(L("未コミットの変更があるため閉じられません。先にコミットまたは stash してください。",
                                         "Can't close: uncommitted changes — commit or stash first.")) }
            }
            menu.addItem(close)
        }
        // A background agent whose process is gone can't be stopped any further — `claude rm` is what
        // takes it off the agent-view list. It also deletes the session's worktree, so it's its own
        // item, with a confirmation (removeAgentRecord) rather than folded into close.
        if removableRecord(row) != nil {
            if closeTitle == nil { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(L("記録を削除（claude rm）…", "Delete record (claude rm)…")) { [weak self] in
                self?.removeAgentRecord(row)
            })
        }
        return menu
    }

}
