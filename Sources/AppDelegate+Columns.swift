import AppKit

extension AppDelegate {
    // Drop a repo group into a column at a visual position (v6 #2, v6fix2). To make a drag move *only*
    // the dragged group, we first freeze the current on-screen placement of every group into
    // `manualLayout` (so no auto-rebalancing reflows the others when this group leaves its column),
    // then move just the dragged key to (col, dropIndex). `dropIndex` counts *all* blocks in the
    // target column above the cursor. When the group is already in the target column, removing it
    // shifts the later slots down by one, so a downward move decrements the index. New (never-seen)
    // groups stay out of manualLayout and auto-fill the shortest column on the next rebuild.
    func applyManualDrop(key: String, toColumn col: Int, at dropIndex: Int) {
        let colCount = effectiveColumns
        let sections = groupByRepo(lastRows ?? [])
        var cols = layoutColumns(sections, colCount: colCount)   // freeze the current placement
        let target = max(0, min(col, colCount - 1))

        var oldIndexInTarget: Int? = nil
        for c in cols.indices {
            if let i = cols[c].firstIndex(of: key) {
                if c == target { oldIndexInTarget = i }
                cols[c].remove(at: i)
            }
        }
        var insert = dropIndex
        if let old = oldIndexInTarget, dropIndex > old { insert -= 1 }
        insert = max(0, min(insert, cols[target].count))
        cols[target].insert(key, at: insert)

        manualLayout = cols.enumerated().flatMap { col, keys in keys.map { (key: $0, col: col) } }
        saveManualLayout()
        rebuild(rows: lastRows)
    }

    // Release a repo group's manual placement so it returns to auto-fill (v6 #2). With the whole
    // board frozen after a drag, clearing one group drops just it to the shortest column's end; the
    // rest stay put.
    func clearManual(_ key: String) {
        guard manualLayout.contains(where: { $0.key == key }) else { return }
        manualLayout.removeAll { $0.key == key }
        saveManualLayout()
        rebuild(rows: lastRows)
    }

    // Release every manual placement so the board returns fully to auto-fill (v6fix2, optional escape
    // hatch — after a drag freezes the whole board, this restores the original height-balanced pack).
    func clearAllManual() {
        guard !manualLayout.isEmpty else { return }
        manualLayout = []
        saveManualLayout()
        rebuild(rows: lastRows)
    }

    // Family peek popover (C7): hovering a collapsed family's summary previews its children.
    func showFamilyPeek(children: [AgentRow], from anchor: NSView) {
        familyPeekCloseWork?.cancel()
        if familyPeekPopover != nil { return }
        let box = NSStackView(); box.orientation = .vertical; box.alignment = .leading; box.spacing = 5
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for c in children {
            let dotc = style(for: c.status).dot
            let d = makeLabel("●", size: 8, color: dotc)
            // The 🤖 label prefix is gone (SF Symbol化 2026-07-11) — mark a subagent child here
            // with the same sparkles its nested card uses.
            let name = c.isSubagent
                ? symbolLabel("sparkles", c.label, size: 11.5, weight: .semibold, color: Cat.text, symbolColor: Cat.mauve)
                : makeLabel(c.label, size: 11.5, weight: .semibold, color: Cat.text)
            name.lineBreakMode = .byTruncatingTail
            let head = NSStackView(views: [d, name]); head.orientation = .horizontal; head.spacing = 6
            box.addArrangedSubview(head)
            let sub = c.lastMessage ?? c.activity
            if let s = sub, !s.isEmpty {
                let l = makeLabel(String(s.prefix(60)), size: 10.5, color: Cat.subtext)
                l.lineBreakMode = .byTruncatingTail
                box.addArrangedSubview(l)
            }
        }
        box.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let vc = NSViewController(); vc.view = box
        let pop = NSPopover(); pop.contentViewController = vc; pop.behavior = .applicationDefined
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        familyPeekPopover = pop
    }
    func scheduleFamilyPeekClose() {
        familyPeekCloseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.familyPeekPopover?.close(); self?.familyPeekPopover = nil }
        familyPeekCloseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    // Popup listing every deliverable behind an aggregated chip (A2). Each item is "<favicon> <title>"
    // so you can pick by name, not by URL (v5fix3 #1); the URL rides along as the tooltip and the
    // opened target. favicon → doc.text symbol, title → URL's last path component → "Artifact" when absent.
    func showLinksMenu(_ links: [AgentLink], from view: NSView) {
        let menu = NSMenu()
        for link in links {
            var title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty { title = URL(string: link.url)?.lastPathComponent ?? "" }
            if title.isEmpty { title = link.label.isEmpty ? "Artifact" : link.label }
            let item = NSMenuItem(title: link.favicon.map { "\($0) \(title)" } ?? title,
                                  action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
            if link.favicon == nil { item.image = symbolImage("doc.text", size: 11) }
            item.target = self
            item.representedObject = link.url
            item.toolTip = link.url
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc func openLinkFromMenu(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    // A short caption to tell apart two cards that share a label (A4): the first line of what it's
    // doing, else a short session-id so they're never indistinguishable.
    func disambigSubtitle(_ row: AgentRow) -> String {
        if let a = row.activity?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            return String(a.prefix(28))
        }
        return "#" + row.sessionId.prefix(6)
    }

    // Emit a repo section's threaded tree into `into` at card width `width` (C7). A root card with
    // child sessions gets a ⌄N fold toggle; collapsed → a one-line child summary; expanded → each
    // child in a thread container (connector + node dot). New sessions fade in (B4).
    func emitTree(_ section: RepoSection, into target: NSStackView, width: CGFloat) {
        let ordered = treeOrder(section.rows)
        var labelCounts: [String: Int] = [:]
        for (r, _) in ordered { labelCounts[r.label, default: 0] += 1 }
        func sub(_ r: AgentRow) -> String? { (labelCounts[r.label] ?? 0) > 1 ? disambigSubtitle(r) : nil }
        func add(_ v: NSView, sessionId: String) {
            target.addArrangedSubview(v)
            if !knownSessions.isEmpty && !knownSessions.contains(sessionId) {   // genuinely new → slide/fade in
                v.alphaValue = 0
                DispatchQueue.main.async { v.animator().alphaValue = 1 }
            }
        }
        var i = 0
        while i < ordered.count {
            let root = ordered[i].row
            var kids: [AgentRow] = []
            var j = i + 1
            while j < ordered.count && ordered[j].depth > 0 { kids.append(ordered[j].row); j += 1 }
            let collapsed = collapsedFamilies.contains(root.sessionId)
            add(rowView(for: root, width: width, familyChildren: kids,
                        familyCollapsed: collapsed, subtitle: sub(root)),
                sessionId: root.sessionId)
            // Collapsed families show their summary inside the parent's bottom strip (2026-07-08 —
            // the separate one-line summary card is gone), so only the expanded state adds views.
            if !kids.isEmpty && !collapsed {
                for k in kids {
                    let cardW = width - 20
                    // A fork gets an explicit "fork" caption (its title equals the root's, being the
                    // same conversation) instead of the generic same-label disambiguator; the branch
                    // node marker beside it carries the icon.
                    let cap = k.isFork ? L("fork", "fork") : sub(k)
                    let child = rowView(for: k, width: cardW, isChild: true, subtitle: cap)
                    add(threadChild(child, state: k.status, isFork: k.isFork, width: width), sessionId: k.sessionId)
                }
            }
            i = j
        }
    }

    // Cycle the board time filter (B5): 24h ⇄ all.
    func toggleTimeFilter() {
        timeFilter = timeFilter == .last24h ? .all : .last24h
        defaults.set(timeFilter.rawValue, forKey: "timeFilter")
        rebuild(rows: lastRows)
    }

    @objc func toggleMinimized() {
        minimized.toggle()
        defaults.set(minimized, forKey: "minimized")
        rebuild(rows: lastRows)
    }

    func toggleRepoCollapse(_ key: String) {
        if collapsedRepos.contains(key) { collapsedRepos.remove(key) } else { collapsedRepos.insert(key) }
        defaults.set(Array(collapsedRepos), forKey: "collapsedRepos")
        rebuild(rows: lastRows)
    }

    // The placement key is the free `repoGroupKey` (Models.swift) — solo sections get per-session
    // keys there; a shared literal used to paint one section into every solo slot (2026-07-09).

    // The board's placement: for each column, the repo keys it holds, top-to-bottom. Manually-placed
    // groups (in `manualLayout`) sit in their assigned column first, in manualLayout order; the rest
    // auto-fill the shortest column (by group weight), in a stable name order. This is the single
    // source of truth shared by `columnsView` (rendering) and `applyManualDrop` (which freezes the
    // current placement so a drag moves *only* the dragged group — v6fix2).
    func layoutColumns(_ sections: [RepoSection], colCount: Int) -> [[String]] {
        func weight(_ s: RepoSection) -> CGFloat {
            let key = repoGroupKey(s)
            if collapsedRepos.contains(key) { return 1 }
            let (live, records) = partitionRecords(s.rows)
            var w = 1 + CGFloat(treeOrder(live).count)
            // The archive lane costs one slot folded, and its records on top of that when unfolded.
            if !records.isEmpty { w += expandedRecordLanes.contains(key) ? CGFloat(records.count) + 1 : 1 }
            return w
        }
        var byKey: [String: RepoSection] = [:]
        for s in sections { byKey[repoGroupKey(s)] = s }
        let manualSet = Set(manualLayout.map { $0.key })
        var cols = [[String]](repeating: [], count: colCount)
        var heights = [CGFloat](repeating: 0, count: colCount)
        for placement in manualLayout {
            guard let s = byKey[placement.key] else { continue }   // group no longer on the board
            let col = max(0, min(placement.col, colCount - 1))
            cols[col].append(placement.key)
            heights[col] += weight(s)
        }
        let autoSections = sections.filter { !manualSet.contains(repoGroupKey($0)) }
            .sorted { ($0.header ?? repoGroupKey($0)) < ($1.header ?? repoGroupKey($1)) }
        for s in autoSections {
            let col = heights.enumerated().min { $0.element < $1.element }!.offset
            cols[col].append(repoGroupKey(s))
            heights[col] += weight(s)
        }
        return cols
    }

    // Column mode (B3/v6 #2): repo groups packed into fixed-width columns. Placement comes from
    // `layoutColumns`; a group is drawn as "manual" (📌, and a "reset to auto" menu entry) when it's
    // pinned to a column in `manualLayout`. A state change never reflows the board — only membership
    // changes (new session, 24h drop-off, a drag) do.
    func columnsView(_ sections: [RepoSection]) -> NSView {
        let colCount = effectiveColumns
        var byKey: [String: RepoSection] = [:]
        for s in sections { byKey[repoGroupKey(s)] = s }
        let manualSet = Set(manualLayout.map { $0.key })

        let columns: [NSStackView] = (0..<colCount).map { _ in
            let s = NSStackView(); s.orientation = .vertical; s.alignment = .leading; s.spacing = 8
            s.translatesAutoresizingMaskIntoConstraints = false
            return s
        }
        let placement = layoutColumns(sections, colCount: colCount)
        for (col, keys) in placement.enumerated() {
            for key in keys {
                guard let s = byKey[key] else { continue }
                columns[col].addArrangedSubview(sectionColumnView(s, manual: manualSet.contains(key)))
            }
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        for (idx, c) in columns.enumerated() {
            // Top-pin each column in a fixed-width, flexible-height wrapper so the tallest column
            // doesn't stretch the others' cards, and a collapsed group never changes the slot width.
            // The wrapper is also the drop target for repo-block drags into this column (v6 #2).
            let wrap = ColumnDropView()
            wrap.colIndex = idx
            wrap.stack = c
            wrap.onDragActivity = { [weak self] in self?.lastDragAt = Date() }
            wrap.onDropBlock = { [weak self] key, col, index in self?.applyManualDrop(key: key, toColumn: col, at: index) }
            wrap.registerForDraggedTypes([repoBlockPBType])
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(c)
            NSLayoutConstraint.activate([
                c.topAnchor.constraint(equalTo: wrap.topAnchor),
                c.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                c.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                c.bottomAnchor.constraint(lessThanOrEqualTo: wrap.bottomAnchor),
                wrap.widthAnchor.constraint(equalToConstant: columnWidth),
            ])
            row.addArrangedSubview(wrap)
        }
        return row
    }

    // One repo group as a fixed-width column entry: an emphasized header (B7) over its threaded
    // cards, all wrapped in a tinted panel so the group's extent is unmistakable (修正2). Collapsing
    // hides the cards but keeps the column-width slot (B1).
    func sectionColumnView(_ section: RepoSection, manual: Bool) -> SectionPanelView {
        let key = repoGroupKey(section)
        let collapsed = collapsedRepos.contains(key)
        let inner = columnWidth - repoPanelPad * 2
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        col.addArrangedSubview(repoColumnHeader(section, key: key, collapsed: collapsed, manual: manual, width: inner))
        if !collapsed {
            // Finished background records are history, not sessions: they leave the tree and fold into
            // one archive lane under the live cards (2026-07-09). A repo of nothing but records is
            // just its header + the folded lane.
            let (live, records) = partitionRecords(section.rows)
            emitTree(RepoSection(header: section.header, rows: live), into: col, width: inner)
            if !records.isEmpty {
                let expanded = expandedRecordLanes.contains(key)
                col.addArrangedSubview(recordLaneView(key: key, records: records, expanded: expanded, width: inner))
                if expanded {
                    for record in records { col.addArrangedSubview(rowView(for: record, width: inner)) }
                }
            }
        }
        col.widthAnchor.constraint(equalToConstant: inner).isActive = true
        return repoGroupPanel(col, width: columnWidth)
    }

    // The archive lane: one dashed tray under a repo's live cards holding its finished background
    // records. Folded by default — "▸ 終了済み記録 N ・クリックで展開／attach で再開" plus the records'
    // status dots. The whole strip toggles the fold via a transparent full-size button overlay, the
    // same trick the family strip uses (RowView-style hitTest only lets NSButtons keep their clicks).
    func recordLaneView(key: String, records: [AgentRow], expanded: Bool, width: CGFloat) -> NSView {
        let laneHeight: CGFloat = 30
        let lane = NSView()
        lane.wantsLayer = true
        lane.layer?.backgroundColor = Cat.mantle.withAlphaComponent(0.85).cgColor
        lane.layer?.cornerRadius = 10
        lane.translatesAutoresizingMaskIntoConstraints = false
        let dash = CAShapeLayer()
        dash.path = CGPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: laneHeight - 1),
                           cornerWidth: 10, cornerHeight: 10, transform: nil)
        dash.fillColor = nil
        dash.strokeColor = Cat.surface1.cgColor
        dash.lineWidth = 1
        dash.lineDashPattern = [4, 3]
        lane.layer?.addSublayer(dash)

        let caret = makeLabel(expanded ? "▾" : "▸", size: 10, weight: .bold, color: Cat.overlay, mono: true)
        let title = makeLabel(L("終了済み記録", "finished records"), size: 11.5, color: Cat.subtext)
        let count = makeLabel("\(records.count)", size: 11.5, weight: .bold, color: Cat.mauve, mono: true)
        let hint = makeLabel(expanded ? L("・クリックで畳む", "· click to fold")
                                      : L("・クリックで展開／attach で再開", "· click to unfold / attach to resume"),
                             size: 10.5, color: Cat.overlay)
        hint.lineBreakMode = .byTruncatingTail
        for l in [caret, title, count] { l.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let content = NSStackView(views: [caret, title, count, hint])
        content.orientation = .horizontal
        content.spacing = 5
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        lane.addSubview(content)

        let dots = NSStackView()
        dots.orientation = .horizontal
        dots.spacing = 3
        dots.translatesAutoresizingMaskIntoConstraints = false
        for record in records.prefix(10) {
            let dot = makeLabel("●", size: 8, color: style(for: record.status).dot)
            dot.setContentCompressionResistancePriority(.required, for: .horizontal)
            dots.addArrangedSubview(dot)
        }
        lane.addSubview(dots)

        let overlay = HoverButton(title: "")
        overlay.isBordered = false
        overlay.target = overlay; overlay.action = #selector(HoverButton.fire)
        overlay.onPress = { [weak self] in self?.toggleRecordLane(key) }
        overlay.onHover = { [weak self] entered in
            self?.setHint(entered
                ? (expanded ? L("クリックで終了済み記録を畳む", "click to fold the finished records")
                            : L("終了済みの記録 \(records.count) 件 — クリックで展開（claude attach で再開できます）",
                                "\(records.count) finished records — click to unfold (resume with claude attach)"))
                : nil)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        lane.addSubview(overlay)

        NSLayoutConstraint.activate([
            lane.widthAnchor.constraint(equalToConstant: width),
            lane.heightAnchor.constraint(equalToConstant: laneHeight),
            content.leadingAnchor.constraint(equalTo: lane.leadingAnchor, constant: 13),
            content.centerYAnchor.constraint(equalTo: lane.centerYAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: dots.leadingAnchor, constant: -8),
            dots.trailingAnchor.constraint(equalTo: lane.trailingAnchor, constant: -13),
            dots.centerYAnchor.constraint(equalTo: lane.centerYAnchor),
            overlay.leadingAnchor.constraint(equalTo: lane.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: lane.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: lane.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: lane.bottomAnchor),
        ])
        return lane
    }

    func toggleRecordLane(_ key: String) {
        if expandedRecordLanes.contains(key) { expandedRecordLanes.remove(key) } else { expandedRecordLanes.insert(key) }
        defaults.set(Array(expandedRecordLanes), forKey: "expandedRecordLanes")
        rebuild(rows: lastRows)
    }

    // A repo group (header + its cards) wrapped in a subtly tinted, rounded panel so the boundary
    // between repos is unambiguous — especially in column mode where several short groups stack in
    // one column (修正2). The panel sits *below* the parent/child family layer: it uses the darker
    // `mantle` tint while cards keep their lighter `surface` tint, so cards still read as floating
    // above the group and the repo ▸ family hierarchy isn't flattened.
    func repoGroupPanel(_ content: NSView, width: CGFloat) -> SectionPanelView {
        let panel = SectionPanelView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Cat.mantle.withAlphaComponent(0.5).cgColor
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Cat.surface.withAlphaComponent(0.45).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: repoPanelPad),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -repoPanelPad),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: repoPanelPad),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -repoPanelPad),
            panel.widthAnchor.constraint(equalToConstant: width),
        ])
        return panel
    }

    // Column header (B7): a collapse caret + repo name (15/heavy) + count over a hairline underline.
    // Pin / reorder / idle-close actions now live in the header's right-click menu (v5fix4 #2) instead
    // of on-face buttons, so the header stays clean; the caret still toggles collapse on click.
    func repoColumnHeader(_ section: RepoSection, key: String, collapsed: Bool, manual: Bool, width: CGFloat) -> NSView {
        let urgent = section.rows.contains { $0.status == "blocked" }
        let container = HeaderView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.repoKey = key
        container.onDragBegin = { [weak self] in self?.lastDragAt = Date() }
        container.toolTip = L("ドラッグ: 列を移動 / 右クリック: 列の操作（idle一括クローズ）", "drag: move to a column / right-click: column actions (close idle)")
        container.menuProvider = { [weak self] in self?.buildColumnHeaderMenu(key: key, manual: manual) }

        let caret = HoverButton(title: "")
        caret.isBordered = false
        caret.image = symbolImage(collapsed ? "chevron.right" : "chevron.down", size: 11, weight: .bold)
        caret.imagePosition = .imageOnly
        caret.contentTintColor = Cat.overlay
        caret.target = caret; caret.action = #selector(HoverButton.fire)
        caret.onPress = { [weak self] in self?.toggleRepoCollapse(key) }
        caret.setContentCompressionResistancePriority(.required, for: .horizontal)

        let name = makeLabel(section.header ?? L("その他", "other"), size: 15, weight: .heavy,
                             color: urgent ? Cat.peach : Cat.text)
        name.lineBreakMode = .byTruncatingTail
        let count = makeLabel("\(section.rows.count)", size: 11.5, color: Cat.overlay)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A small pin marks a manually-placed group (dragged to this column), so the fixed vs.
        // auto-filled distinction stays legible; release it via the right-click / card menu.
        let pinMark: NSView? = manual ? NSImageView(image: symbolImage("pin.fill", size: 10, color: Cat.peach) ?? NSImage()) : nil
        pinMark?.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = NSStackView(views: [caret, name, count])
        bar.orientation = .horizontal; bar.spacing = 6; bar.alignment = .firstBaseline
        let spc = NSView(); spc.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spc)
        if let pinMark = pinMark { bar.addArrangedSubview(pinMark) }
        bar.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSView(); rule.wantsLayer = true
        rule.layer?.backgroundColor = (urgent ? Cat.peach : Cat.surface1).cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(bar)
        container.addSubview(rule)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rule.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            rule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        return container
    }

    // Right-click menu for a column header (v6 #2): release a manual placement back to auto (when
    // this group is manually placed — placement itself is by dragging the header), and close idle
    // workspaces *scoped to this column*. Same ClosureMenuItem approach as the card menu.
    func buildColumnHeaderMenu(key: String, manual: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if manual {
            menu.addItem(ClosureMenuItem(L("自動配置に戻す", "Reset to auto layout")) { [weak self] in self?.clearManual(key) })
        }
        // A drag freezes the whole board into manualLayout, so offer a way to release everything.
        if !manualLayout.isEmpty {
            menu.addItem(ClosureMenuItem(L("すべて自動配置に戻す", "Reset all to auto layout")) { [weak self] in self?.clearAllManual() })
        }
        if manual || !manualLayout.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(L("この列の完了・待機ワークスペースを閉じる", "Close done/idle workspaces in this column")) { [weak self] in
            self?.closeIdleWorkspacesInColumn(key: key)
        })
        return menu
    }

    // Shown when the server is up but no agents are running: the logo + a short "what this
    // does" blurb, so an empty board reads as intentional rather than broken. The logo doubles
    // as a button that opens the new-session picker (when ghq is available).
    func emptyStateView() -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .centerX
        box.spacing = 7
        box.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        if let icon = markIcon, let img = icon.copy() as? NSImage {
            img.size = NSSize(width: 46, height: 46)
            if ghqBin != nil {
                let logo = NSButton(image: img, target: self, action: #selector(showNewSessionMenu(_:)))
                logo.isBordered = false
                logo.imagePosition = .imageOnly
                logo.toolTip = L("クリックで新しいセッションを開始", "click to start a new session")
                box.addArrangedSubview(logo)
            } else {
                box.addArrangedSubview(NSImageView(image: img))
            }
        }
        box.addArrangedSubview(makeLabel("Shepherd", size: 15, weight: .bold, color: Cat.text))
        box.addArrangedSubview(makeLabel(L("Claude Code エージェントの見張り番", "a watchtower for your Claude Code agents"),
                                         size: 11.5, color: Cat.subtext))

        let features: [(String, String, NSColor)] = [
            ("bell.badge", L("応答待ちを見つけて知らせます", "surfaces agents that need your reply"), Cat.peach),
            ("arrow.uturn.right", L("行クリックでそのエージェントへジャンプ", "click a row to jump to that agent"), Cat.blue),
            ("plus.circle", L("右上の ＋ で新しいセッションを開始", "＋ (top-right) starts a new session"), Cat.green),
        ]
        for (sym, text, color) in features {
            let iv = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) ?? NSImage())
            iv.contentTintColor = color
            let feat = NSStackView(views: [iv, makeLabel(text, size: 11, color: Cat.subtext)])
            feat.orientation = .horizontal
            feat.spacing = 6
            box.addArrangedSubview(feat)
        }

        let docs = badge(L("ドキュメント ↗", "Documentation ↗"), symbol: "book",
                         fg: Cat.teal, bg: Cat.teal.withAlphaComponent(0.14), tip: shepherdDocsURL) {
            if let u = URL(string: shepherdDocsURL) { NSWorkspace.shared.open(u) }
        }
        let docsWrap = NSStackView(views: [docs])
        docsWrap.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 0, right: 0)
        box.addArrangedSubview(docsWrap)

        // Center in both axes for every HUD size mode (2026-07-11 report: pinned to the
        // single-column contentWidth, the box hugged the top-left of a fixed 2–3 column panel).
        // The wrapper spans the same width the header does (boardSpanWidth), and in the fixed /
        // fullDisplay modes it also claims the panel height left over below the header rows —
        // measured from the stack at this point in rebuild — so the content floats at the visual
        // center. In auto mode the panel hugs the content, so the wrapper just hugs the box.
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(box)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: boardSpanWidth),
            wrap.heightAnchor.constraint(greaterThanOrEqualTo: box.heightAnchor),
            box.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        if let panelH = fixedPanelSize()?.height {
            stack.layoutSubtreeIfNeeded()
            box.layoutSubtreeIfNeeded()
            // 64 ≈ the document's top/bottom insets (24) + the hint line + stack spacing below.
            let remaining = panelH - stack.fittingSize.height - 64
            if remaining > box.fittingSize.height {
                wrap.heightAnchor.constraint(equalToConstant: remaining).isActive = true
            }
        }
        return wrap
    }

    // One usage gauge row: label · track with a filled portion · percent + reset countdown.
    // Colored by the API's severity, falling back to the used-percent (green→peach→red).
    func usageGauge(_ w: UsageWindow) -> NSView {
        let color: NSColor = {
            switch w.severity {
            case "critical", "severe": return Cat.red
            case "warning": return Cat.peach
            default: return w.percent >= 85 ? Cat.red : w.percent >= 60 ? Cat.peach : Cat.green
            }
        }()
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY

        let name = makeLabel(w.label, size: 10.5, weight: .medium, color: Cat.subtext)
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = Cat.surface1.withAlphaComponent(0.5).cgColor
        track.layer?.cornerRadius = 4
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = color.cgColor
        fill.layer?.cornerRadius = 4
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        let frac = max(0, min(1, w.percent / 100))
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: frac),
        ])

        let pctText = "\(Int(w.percent.rounded()))%"
        let resetText = w.resetsAt.map { "  " + shortReset($0) } ?? ""
        let pct = makeLabel(pctText + resetText, size: 10.5, weight: .semibold, color: color)
        pct.setContentHuggingPriority(.required, for: .horizontal)
        pct.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addArrangedSubview(name)
        row.addArrangedSubview(track)
        row.addArrangedSubview(pct)
        return row
    }

    // "→2h" / "→3d" style countdown until the window resets.
    func shortReset(_ date: Date) -> String {
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return L("まもなく", "soon") }
        let h = Int(secs / 3600)
        if h < 1 { return "→\(max(1, Int(secs / 60)))m" }
        if h < 24 { return "→\(h)h" }
        return "→\(h / 24)d"
    }

    // Top dashboard: the plan-usage gauges (5h / weekly / per-model) shown above everything else.
    func usageDashboardView(width: CGFloat) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical; box.spacing = 5; box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 6, right: 2)

        let title = makeLabel(L("プラン使用量", "plan usage"), size: 10, weight: .bold, color: Cat.overlay)
        box.addArrangedSubview(title)

        if let usage = lastUsage, usage.error == nil, !usage.windows.isEmpty {
            // Order: session, weekly, then any model-scoped windows.
            let order: (UsageWindow) -> Int = { $0.key == "session" ? 0 : $0.key == "weekly" ? 1 : 2 }
            for w in usage.windows.sorted(by: { order($0) < order($1) }) {
                box.addArrangedSubview(usageGauge(w))
            }
        } else {
            let msg = lastUsage?.error ?? L("読み込み中…", "loading…")
            box.addArrangedSubview(makeLabel(msg, size: 10.5, color: Cat.overlay))
        }
        box.widthAnchor.constraint(equalToConstant: width - 20).isActive = true

        // Wrap in a faintly tinted card to set it apart from the agent rows.
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Cat.surface.withAlphaComponent(0.35).cgColor
        card.layer?.cornerRadius = 9
        box.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            box.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            box.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            box.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
        return card
    }

    // Board width in column mode = N fixed columns + gaps. Used to span the dashboard full width (B2).
    var boardWidth: CGFloat { CGFloat(effectiveColumns) * columnWidth + CGFloat(effectiveColumns - 1) * 12 }

    // Column count per size mode (HUDサイズ 2026-07-08): auto keeps the user-overridable
    // masonryColumns; the fixed presets ARE a column count; fullDisplay packs whatever fits the
    // screen width. Everything that lays out columns (columnsView / applyManualDrop / boardWidth)
    // goes through this so the board can never overflow a fixed panel sideways.
    var effectiveColumns: Int {
        if hudSizeMode == .auto { return masonryColumns }
        if let preset = hudPreset(hudSizeMode) { return preset.columns }
        let width = fixedPanelSize()?.width ?? contentWidth
        return hudFitColumns(panelWidth: width, columnWidth: columnWidth, gap: 12, sidePadding: 12)
    }

    // The panel's target size in the fixed modes; nil in auto (content-fit). Preset heights clamp
    // to the current display so "大" on a small sub-monitor never overhangs.
    func fixedPanelSize() -> NSSize? {
        switch hudSizeMode {
        case .auto:
            return nil
        case .fullDisplay:
            return (screenUnderPanel() ?? NSScreen.main)?.visibleFrame.size
        default:
            guard let preset = hudPreset(hudSizeMode) else { return nil }
            let width = hudPanelWidth(columns: preset.columns, columnWidth: columnWidth, gap: 12, sidePadding: 12)
            let maxHeight = (screenUnderPanel() ?? NSScreen.main)?.visibleFrame.height
            return NSSize(width: width, height: maxHeight.map { min(preset.height, $0) } ?? preset.height)
        }
    }

    // Width the header / dashboard / hint line span: the board itself in auto, the panel's inner
    // width in the fixed modes (fullDisplay is wider than its N columns, and the toolbar should
    // still reach the panel's right edge).
    var boardSpanWidth: CGFloat { fixedPanelSize().map { $0.width - 24 } ?? boardWidth }

    // Apply the active board filter (B5). Today: 24h recency by updated_at (rows with no timestamp
    // are kept — an unknown age shouldn't hide a live session).
    func applyFilter(_ rows: [AgentRow]) -> [AgentRow] {
        switch timeFilter {
        case .all: return rows
        case .last24h:
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            return rows.filter { ($0.updatedAt ?? Date()) >= cutoff }
        }
    }

    func rebuild(rows: [AgentRow]?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let filtered = rows.map(applyFilter)
        // Top-to-bottom: brand bar (logo + account + controls), then the plan-usage gauges, then the
        // status row (24h filter + summary pills) sitting right on top of the board (2026-07-11).
        let (brand, status) = headerView(rows: filtered)
        stack.addArrangedSubview(brand)
        if showUsageDashboard { stack.addArrangedSubview(usageDashboardView(width: boardSpanWidth)) }
        if let status = status { stack.addArrangedSubview(status) }

        // Minimized: dashboard + header summary only — skip the whole body and hint line.
        // This wins over the fixed size modes: a mostly-empty fixed panel with one strip is noise.
        if minimized {
            scrollView.verticalScrollElasticity = .none
            stackWidthConstraint.isActive = true
            stack.layoutSubtreeIfNeeded()
            let size = NSSize(width: contentWidth, height: stack.fittingSize.height + 24)
            let top = panel.frame.maxY, x = panel.frame.minX
            panel.setContentSize(size)
            panel.setFrameOrigin(NSPoint(x: x, y: top - panel.frame.height))
            return
        }

        if let rows = filtered, rows.isEmpty {
            stack.addArrangedSubview(emptyStateView())
        } else if let rows = filtered {
            // Always lay repos out as fixed-width masonry columns (v5fix3 #3 — the single-column row
            // mode is gone). Groups pack into the shortest column; pinned groups keep a stable slot.
            stack.addArrangedSubview(columnsView(groupByRepo(rows)))
        }
        // Remember which sessions we've shown (new ones fade in next time) and their rendered state
        // (a change animates the rail colour) — B4. Updated after the body is built.
        if let rows = filtered {
            knownSessions = Set(rows.map { $0.sessionId })
            renderedStatus = Dictionary(rows.map { ($0.sessionId, $0.status) }, uniquingKeysWith: { a, _ in a })
        }

        // Self-drawn hover hint line (NSToolTip doesn't fire on a nonactivating panel).
        do {
            let hint = makeLabel("", size: 10.5, color: Cat.overlay)
            hint.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(hint)
            // Match the header: span the board so longer hints (e.g. the close-idle breakdown)
            // aren't cut at the legacy 296pt.
            let hintWide = !(filtered?.isEmpty ?? true)
            hint.widthAnchor.constraint(equalToConstant: hintWide ? boardSpanWidth : contentWidth - 24).isActive = true
            hintLabel = hint
        }

        // The board grows to fit its columns; the fixed-width constraint now only pins the minimized
        // strip (handled above) — so it stays inactive here.
        stackWidthConstraint.isActive = false
        stack.layoutSubtreeIfNeeded()
        // Panel sizing per mode (HUDサイズ 2026-07-08): auto fits the content (scroll never engages);
        // the presets keep their fixed size with the top-left anchored; fullDisplay snaps to the
        // visible frame of whichever display the panel sits on — drag it to another monitor and the
        // next rebuild fills that one.
        scrollView.verticalScrollElasticity = hudSizeMode == .auto ? .none : .automatic
        if hudSizeMode == .fullDisplay, let scr = screenUnderPanel() ?? NSScreen.main {
            panel.setFrame(scr.visibleFrame, display: true)
            return
        }
        let fitting = NSSize(width: max(contentWidth, stack.fittingSize.width + 24),
                             height: stack.fittingSize.height + 24)
        let size = fixedPanelSize() ?? fitting
        let top = panel.frame.maxY
        let x = panel.frame.minX
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: x, y: top - panel.frame.height))
    }
}
