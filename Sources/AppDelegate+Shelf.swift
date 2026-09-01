import AppKit

// MARK: - Artifact shelf (2026-07-17)
//
// The board's ARTIFACTS section: every Artifact the index knows — API window + transcript
// history — as an inline searchable list. (The original popover variant behind a brand-bar
// button shipped first and was retired the same day once the inline section was approved.)

// One shelf row: click opens, right-click gets the context menu. Same menu(for:)/hitTest shape as
// RowView, minus everything a session card needs and an artifact row doesn't.
final class ShelfRowView: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var onHover: ((Bool) -> Void)?
    // Resting and hover fills. Overridden by a routine row waiting on approval, which wears the
    // blocked card's peach wash — hover-exit has to return to THAT, not to the default surface.
    var baseColor = Cat.surface.withAlphaComponent(0.4)
    var hoverColor = Cat.surface1.withAlphaComponent(0.5)
    private var tracking: NSTrackingArea?
    var baseAlpha: CGFloat = 1
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels must not swallow clicks — the row is the one interactive surface.
        super.hitTest(point) == nil ? nil : self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverColor.cgColor
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseColor.cgColor
        onHover?(false)
    }
}

extension AppDelegate {

    @objc func forceShelfRefresh() {
        maybeRefreshArtifacts(force: true)
        startArtifactScan()
    }

    // One artifact row: live-dot ・ favicon ・ title ・ [repo tag] ・ [pin] ・ updated stamp.
    // softDeleted dims.
    private func shelfRow(_ rec: ArtifactRecord, width: CGFloat) -> NSView {
        let row = ShelfRowView()
        row.wantsLayer = true
        row.layer?.backgroundColor = Cat.surface.withAlphaComponent(0.4).cgColor
        row.layer?.cornerRadius = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (rec.softDeleted ? Cat.overlay : Cat.green).cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        // Favicon emoji is the artifact's face; SF doc glyph when it never had one.
        let fav: NSView
        if let f = rec.favicon, !f.isEmpty {
            fav = makeLabel(f, size: 12)
        } else {
            let iv = NSImageView(image: symbolImage("doc.text", size: 11, color: Cat.overlay) ?? NSImage())
            iv.translatesAutoresizingMaskIntoConstraints = false
            fav = iv
        }
        let title = makeLabel(rec.title ?? String(rec.slug.prefix(8)), size: 12, weight: .medium, color: Cat.text)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(10), for: .horizontal)

        var trailing: [NSView] = [NSView()]
        if let repo = rec.repoName {
            let tag = makeLabel(repo, size: 9.5, color: Cat.overlay, mono: true)
            tag.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(11), for: .horizontal)
            tag.lineBreakMode = .byTruncatingTail
            trailing.append(tag)
        }
        let pinned = artifactPins.contains(rec.slug)
        if pinned {
            let pin = NSImageView(image: symbolImage("pin.fill", size: 9, color: Cat.amber) ?? NSImage())
            pin.translatesAutoresizingMaskIntoConstraints = false
            trailing.append(pin)
        }
        let date = makeLabel(rec.softDeleted ? L("削除済み", "deleted") : shelfDateText(rec.updatedAt),
                             size: 10, color: Cat.overlay, mono: true)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.append(date)

        let h = NSStackView(views: [dot, fav, title] + trailing)
        h.orientation = .horizontal
        h.spacing = 7
        h.alignment = .centerY
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            h.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            row.widthAnchor.constraint(equalToConstant: width),
        ])
        if rec.softDeleted { row.alphaValue = 0.45 }

        row.onClick = {
            if let u = URL(string: rec.url) { NSWorkspace.shared.open(u) }
        }
        row.menuProvider = { [weak self] in
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(L("ブラウザで開く", "Open in browser")) {
                if let u = URL(string: rec.url) { NSWorkspace.shared.open(u) }
            })
            menu.addItem(ClosureMenuItem(L("URL をコピー", "Copy URL")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rec.url, forType: .string)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(pinned ? L("固定を解除", "Unpin") : L("上位に固定", "Pin to top")) {
                self?.toggleArtifactPin(rec.slug)
            })
            return menu
        }
        return row
    }

    // Pin / unpin an artifact (bookmark-style: pinned rows sort to the top of the inline list).
    func toggleArtifactPin(_ slug: String) {
        if let i = artifactPins.firstIndex(of: slug) { artifactPins.remove(at: i) }
        else { artifactPins.append(slug) }
        defaults.set(artifactPins, forKey: "artifactPins")
        renderArtifactList()
    }

    // MARK: - Fetch orchestration

    // 源A fetch: only while the ARTIFACTS section is open (+15-min guard) or the ↻ forces it —
    // the endpoint is private and the section is an on-demand surface, so a folded bar costs
    // zero calls. Stale-while-error: a failure stamps artifactAPIError, the index stays.
    func maybeRefreshArtifacts(force: Bool) {
        // Fixture mode (demo board / self-checks) stays off the live API: real artifact titles
        // carry client project names, which must never reach a docs screenshot.
        guard ProcessInfo.processInfo.environment["SHEPHERD_PROJECTS_DIR"] == nil else { return }
        guard !artifactAPIFetching,
              force || Date().timeIntervalSince(artifactAPIFetchedAt) > 15 * 60 else { return }
        artifactAPIFetching = true
        DispatchQueue.global(qos: .utility).async {
            let (frames, error) = fetchArtifactFrames()
            if let frames = frames { ArtifactIndex.shared.mergeFrames(frames) }
            DispatchQueue.main.async {
                self.artifactAPIFetching = false
                self.artifactAPIFetchedAt = Date()
                self.artifactAPIError = error
                self.renderArtifactList()
            }
        }
    }

    // 源B scan: incremental after the first pass, so re-triggering is cheap (one stat per
    // unchanged transcript). Low priority — never on the refresh pipeline.
    func startArtifactScan() {
        guard !artifactScanRunning else { return }
        artifactScanRunning = true
        DispatchQueue.global(qos: .background).async {
            ArtifactIndex.shared.scanTranscripts(projectsDir: claudeProjectsDir)
            DispatchQueue.main.async {
                self.artifactScanRunning = false
                self.renderArtifactList()
            }
        }
    }

    // The inline bar's scan trigger rides refresh() (every 30s while the section is open), so it
    // gets its own guard: a stat over every transcript is cheap but not every-30s cheap.
    func startArtifactScanGuarded() {
        guard Date().timeIntervalSince(artifactScanAt) > 300 else { return }
        artifactScanAt = Date()
        startArtifactScan()
    }

    // MARK: - Inline board sections (experimental, 2026-07-17)
    //
    // The board splits into two collapsible sections: セッション (the columns, folding to a bar
    // that carries the status summary) and ARTIFACTS (an inline flat list with search and
    // bookmark-style pinning). The header's shelf-popover button stays — this layout is an
    // experiment and may be rejected.

    // A section's disclosure bar: the chevron+title badge is the click target; accessories
    // right-align. Spans the board like the header rows do. Shared with the ROUTINES section.
    func sectionRow(toggle: NSView, accessories: [NSView]) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let bar = NSStackView(views: [toggle, spacer] + accessories)
        bar.orientation = .horizontal
        bar.spacing = 6
        for v in bar.arrangedSubviews where v !== spacer {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(999), for: .horizontal)
        }
        bar.widthAnchor.constraint(equalToConstant: boardSpanWidth).isActive = true
        return bar
    }

    // A section's capped list: a vertical stack in a scroll view sized to show at most `visibleRows`
    // of them, so a long list scrolls instead of pushing the sections below it off the board. The
    // caller keeps the returned stack to fill (ARTIFACTS populates its rows later, on every
    // keystroke, without rebuilding this scroll). `rowStride` is one row plus the 4pt spacing —
    // ARTIFACTS knows its rows' height in advance, ROUTINES measures a built row instead of
    // guessing, which is what left dead space under the list before.
    func cappedListScroll(visibleRows: Int, rowStride: CGFloat) -> (scroll: NSScrollView, stack: NSStackView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: boardSpanWidth),
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(visibleRows) * rowStride),
        ])
        return (scroll, stack)
    }

    func sessionsSectionBar(rows: [AgentRow]?) -> NSView {
        let collapsed = sessionsSectionCollapsed
        let count = rows?.count ?? 0
        let toggle = badge(L("セッション — \(count)", "SESSIONS — \(count)"),
                           symbol: collapsed ? "chevron.right" : "chevron.down",
                           fg: Cat.subtext, bg: .clear,
                           tip: L("セッション一覧を開閉", "collapse / expand the sessions board")) { [weak self] in
            self?.toggleSessionsSection()
        }
        // Folded: the board's status summary moves onto the bar so nothing urgent goes dark —
        // including the A9 quota alert, which normally rides the (now hidden) status row.
        var accessories: [NSView] = []
        if collapsed, let w = quotaAlertWindow() {
            let sev = w.percent >= 95 || w.severity == "critical" || w.severity == "severe"
            let color = sev ? Cat.red : Cat.peach
            accessories.append(badge("\(w.label) \(Int(w.percent.rounded()))%", symbol: "exclamationmark.triangle.fill",
                                     symbolSize: 10, fg: color, bg: color.withAlphaComponent(0.16),
                                     tip: L("使用量パネルを表示", "show the usage panel")) { [weak self] in
                self?.revealUsagePanel()
            })
        }
        if collapsed, let rows = rows {
            let blocked = rows.filter { $0.status == "blocked" }.count
            let working = rows.filter { $0.status == "working" }.count
            if blocked > 0 { accessories.append(pill(L("応答待ち \(blocked)", "needs input \(blocked)"), color: Cat.peach)) }
            if working > 0 { accessories.append(pill(L("作業中 \(working)", "working \(working)"), color: Cat.green)) }
            if blocked == 0 && working == 0 {
                accessories.append(pill(rows.isEmpty ? L("agent なし", "no agents") : L("すべて待機", "all idle"),
                                        color: Cat.overlay))
            }
        }
        return sectionRow(toggle: toggle, accessories: accessories)
    }

    func toggleSessionsSection() {
        sessionsSectionCollapsed.toggle()
        defaults.set(sessionsSectionCollapsed, forKey: "sessionsCollapsed")
        rebuild(rows: lastRows)
    }

    func toggleArtifactsBar() {
        artifactsBarCollapsed.toggle()
        defaults.set(artifactsBarCollapsed, forKey: "artifactsBarCollapsed")
        if !artifactsBarCollapsed {
            maybeRefreshArtifacts(force: false)
            startArtifactScanGuarded()
        }
        rebuild(rows: lastRows)
    }

    // The ARTIFACTS section: disclosure bar (+ fetch stamp + ↻ when open), then a search field
    // and the flat pinned-first list in a capped-height scroll.
    func artifactsSectionViews() -> [NSView] {
        let collapsed = artifactsBarCollapsed
        // Folded shows only the count — skip the snapshot copy (this runs on every rebuild).
        let records = collapsed ? [] : ArtifactIndex.shared.snapshot()
        let count = collapsed ? ArtifactIndex.shared.count() : records.count
        let toggle = badge("ARTIFACTS — \(count)",
                           symbol: collapsed ? "chevron.right" : "chevron.down",
                           fg: Cat.subtext, bg: .clear,
                           tip: L("Artifact 一覧を開閉", "collapse / expand the artifact list")) { [weak self] in
            self?.toggleArtifactsBar()
        }
        var accessories: [NSView] = []
        if !collapsed {
            if artifactAPIError != nil {
                accessories.append(makeLabel(L("更新失敗", "fetch failed"), size: 10, color: Cat.peach, mono: true))
            } else if artifactAPIFetchedAt != .distantPast {
                accessories.append(makeLabel("↻ " + agoText(Date().timeIntervalSince(artifactAPIFetchedAt)),
                                             size: 10, color: Cat.overlay, mono: true))
            }
            accessories.append(badge("", symbol: "arrow.clockwise", fg: Cat.overlay, bg: .clear,
                                     tip: L("いますぐ再取得", "refresh now")) { [weak self] in
                self?.forceShelfRefresh()
            })
        }
        var out: [NSView] = [sectionRow(toggle: toggle, accessories: accessories)]
        guard !collapsed else { return out }

        let search = NSSearchField()
        search.placeholderString = L("Artifact を検索…", "search artifacts…")
        search.stringValue = artifactQuery
        search.delegate = self
        search.controlSize = .small
        search.font = NSFont.systemFont(ofSize: 11)
        search.translatesAutoresizingMaskIntoConstraints = false
        artifactSearchField = search

        // 簡易フィルター: repo で絞るポップアップ（すべて / 各repo / 帰属不明）。
        let repos = Set(records.compactMap { $0.repoName }).sorted()
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.font = NSFont.systemFont(ofSize: 10.5)
        let all = NSMenuItem(title: L("すべて", "all repos"), action: nil, keyEquivalent: "")
        popup.menu?.addItem(all)
        for repo in repos {
            let item = NSMenuItem(title: repo, action: nil, keyEquivalent: "")
            item.representedObject = repo
            popup.menu?.addItem(item)
        }
        if records.contains(where: { $0.repoName == nil }) {
            let item = NSMenuItem(title: L("帰属不明", "unattributed"), action: nil, keyEquivalent: "")
            item.representedObject = ""
            popup.menu?.addItem(item)
        }
        // Restore the active filter across rebuilds; a repo that vanished resets to "all".
        if let current = artifactRepoFilter,
           let i = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: i)
        } else {
            artifactRepoFilter = nil
            popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(artifactRepoFilterChanged(_:))
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)

        let filterRow = NSStackView(views: [search, popup])
        filterRow.orientation = .horizontal
        filterRow.spacing = 6
        search.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        filterRow.widthAnchor.constraint(equalToConstant: boardSpanWidth).isActive = true
        out.append(filterRow)

        // Cap the section at ~7 rows; more scrolls. The height is fixed at rebuild time — an
        // in-place search re-render doesn't resize the panel (auto mode can't grow without a
        // rebuild, and a rebuild would destroy the field being typed in).
        let visibleRows = min(max(shelfListOrder(records, pins: artifactPins, query: artifactQuery,
                                                 repoFilter: artifactRepoFilter).count, 1), 7)
        let (scroll, list) = cappedListScroll(visibleRows: visibleRows, rowStride: 31)
        artifactListStack = list
        renderArtifactList()
        out.append(scroll)
        return out
    }

    // Repopulate the inline list in place (search keystrokes, fetch/scan completions) — never a
    // full rebuild, which would recreate the search field and drop keyboard focus mid-word.
    func renderArtifactList() {
        guard let list = artifactListStack else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let records = shelfListOrder(ArtifactIndex.shared.snapshot(), pins: artifactPins,
                                     query: artifactQuery, repoFilter: artifactRepoFilter)
        if records.isEmpty {
            let msg = artifactScanRunning ? L("transcript を走査中…", "scanning transcripts…")
                : artifactQuery.isEmpty && artifactRepoFilter == nil
                    ? L("Artifact はまだありません", "no artifacts yet")
                    : L("該当なし", "no matches")
            list.addArrangedSubview(makeLabel(msg, size: 11, color: Cat.overlay))
            return
        }
        for rec in records {
            list.addArrangedSubview(shelfRow(rec, width: boardSpanWidth - 6))
        }
    }

    @objc func artifactRepoFilterChanged(_ sender: NSPopUpButton) {
        artifactRepoFilter = sender.selectedItem?.representedObject as? String
        lastArtifactTypeAt = Date()   // same brief rebuild hold as typing — the popup lives in the board
        renderArtifactList()
    }
}
