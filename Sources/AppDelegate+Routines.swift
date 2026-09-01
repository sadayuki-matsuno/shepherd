import AppKit

// MARK: - ROUTINES section (2026-09-01)
//
// The board's third collapsible section, under ARTIFACTS: claude.ai routines — cron-scheduled
// agents running in Anthropic's cloud. They leave no trace on this machine (no pid, no
// transcript, no daemon job), so unlike every other card here these rows are pure API state and
// the section carries its own fetch stamp / ↻ / failure text.
//
// A routine whose run is stopped at a permission prompt (worker_status "requires_action") gets
// the blocked card's peach treatment — same fact as a blocked session (an agent stopped, waiting
// on a human), so it reads the same way across the board, and the count survives on the bar while
// the section is folded.

extension AppDelegate {

    func toggleRoutinesBar() {
        routinesBarCollapsed.toggle()
        defaults.set(routinesBarCollapsed, forKey: "routinesBarCollapsed")
        if !routinesBarCollapsed { maybeRefreshRoutines(force: false) }
        rebuild(rows: lastRows)
    }

    // What the board should show: the fetched list, or invented rows when a staged capture asks
    // for them (fixture mode never fetches, so the seam has to supply the data outright).
    var displayedRoutines: [Routine] {
        guard routineFixtureMode else { return routines }
        return ProcessInfo.processInfo.environment["SHEPHERD_FAKE_ROUTINE_ACTION"] != nil
            ? fakeActionRoutines() : []
    }

    // Routines stopped at a permission prompt — the section's reason to exist.
    var routinesNeedingAction: [Routine] { displayedRoutines.filter { $0.liveState == "requires_action" } }

    // Bring the routine list into view — the minimized strip's approval chip jumps here, the way
    // the quota chip jumps to the usage panel.
    func revealRoutines() {
        if minimized { minimized = false; defaults.set(false, forKey: "minimized") }
        if routinesBarCollapsed {
            routinesBarCollapsed = false
            defaults.set(false, forKey: "routinesBarCollapsed")
        }
        rebuild(rows: lastRows)
        maybeRefreshRoutines(force: true)
    }

    // Fetch on refresh()'s coat-tails, 120s guard, whether the section is open or not: the folded
    // bar still carries the count and the approval chip, and freezing those behind a fold is the
    // failure the usage fetch had to be rescued from (2026-07-17). Off-main; stale-while-error.
    func maybeRefreshRoutines(force: Bool) {
        // Fixture mode (demo board / SHEPHERD_DUMP self-checks) stays off the live API — a staged
        // capture must never show the real account's routines.
        guard !routineFixtureMode else { return }
        guard !routinesFetching, force || Date().timeIntervalSince(routinesFetchedAt) > 120 else { return }
        routinesFetching = true
        let previous = routines
        DispatchQueue.global(qos: .utility).async {
            let (fetched, error) = fetchRoutines(previous: previous)
            DispatchQueue.main.async {
                self.routinesFetching = false
                self.routinesFetchedAt = Date()
                self.routinesError = error
                if var list = fetched {
                    // Capture seam, same spirit as SHEPHERD_FAKE_CREDIT_BURN: pin the first
                    // routine to "waiting for approval" so that state can be screenshotted
                    // without waiting for a real permission prompt to appear. (On a staged board
                    // the seam works through displayedRoutines instead — there is no fetch there.)
                    if ProcessInfo.processInfo.environment["SHEPHERD_FAKE_ROUTINE_ACTION"] != nil,
                       !list.isEmpty {
                        list[0].liveState = "requires_action"
                        list[0].liveSessionId = list[0].lastRun?.sessionId
                    }
                    self.routines = list   // a failed fetch keeps the previous list
                }
                // The same rebuild hold every async repaint takes: rebuilding mid-keystroke would
                // recreate the ARTIFACTS search field and drop its focus.
                if self.replyPopover == nil && self.repoPickerPopover == nil && self.dropPopover == nil
                    && self.helpPopover == nil
                    && Date().timeIntervalSince(self.lastArtifactTypeAt) > 2.0
                    && Date().timeIntervalSince(self.lastDragAt) > 1.0 {
                    self.rebuild(rows: self.lastRows)
                }
            }
        }
    }

    // Disclosure bar (count, plus the fetch stamp and ↻ when open, or the approval chip when
    // folded), then one row per routine.
    func routinesSectionViews() -> [NSView] {
        let list = displayedRoutines
        // An unstaged fixture board never fetches, so the section could only render an empty "no
        // routines" line — and dev/demo-board.sh's captures are what docs/assets ships. Leave it
        // out entirely there.
        if routineFixtureMode && list.isEmpty { return [] }
        let collapsed = routinesBarCollapsed
        let toggle = badge("ROUTINES — \(list.count)",
                           symbol: collapsed ? "chevron.right" : "chevron.down",
                           fg: Cat.subtext, bg: .clear,
                           tip: L("routine 一覧を開閉", "collapse / expand the routine list")) { [weak self] in
            self?.toggleRoutinesBar()
        }
        var accessories: [NSView] = []
        let needing = routinesNeedingAction
        if collapsed && !needing.isEmpty {
            accessories.append(badge(L("承認待ち \(needing.count)", "needs approval \(needing.count)"),
                                     symbol: "questionmark.circle.fill",
                                     fg: Cat.peach, bg: Cat.peach.withAlphaComponent(0.16),
                                     tip: L("routine 一覧を開く", "open the routine list")) { [weak self] in
                self?.toggleRoutinesBar()
            })
        }
        if !collapsed {
            if routinesError != nil {
                accessories.append(makeLabel(L("更新失敗", "fetch failed"), size: 10, color: Cat.peach, mono: true))
            } else if routinesFetchedAt != .distantPast {
                accessories.append(makeLabel("↻ " + agoText(Date().timeIntervalSince(routinesFetchedAt)),
                                             size: 10, color: Cat.overlay, mono: true))
            }
            accessories.append(badge("", symbol: "arrow.clockwise", fg: Cat.overlay, bg: .clear,
                                     tip: L("いますぐ再取得", "refresh now")) { [weak self] in
                self?.maybeRefreshRoutines(force: true)
            })
        }
        var out: [NSView] = [sectionRow(toggle: toggle, accessories: accessories)]
        guard !collapsed else { return out }

        if list.isEmpty {
            let msg = routinesFetching ? L("取得中…", "fetching…")
                : routinesError != nil ? L("取得できません", "unavailable")
                : L("routine はありません", "no routines")
            let label = makeLabel(msg, size: 11, color: Cat.overlay)
            label.widthAnchor.constraint(equalToConstant: boardSpanWidth).isActive = true
            out.append(label)
            return out
        }
        // Rows live in a capped scroll like the artifact list: a long routine list must not be
        // able to push the sections below it off the board.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Carried-over live state is dimmed the way stale gauges are — it is what we last knew,
        // not what is true now.
        let stale = routinesError != nil
        for r in routineListOrder(list) {
            stack.addArrangedSubview(routineRow(r, width: boardSpanWidth - 6, stale: stale))
        }
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
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(list.count, 7)) * 36),
        ])
        out.append(scroll)
        return out
    }

    // One routine: state glyph ・ name ・ [? 承認待ち] ・ next-run stamp ・ last-run mark.
    // Disabled routines dim like an idle card and drop the schedule text — a greyed row still
    // promising a next run reads as a bug.
    private func routineRow(_ r: Routine, width: CGFloat, stale: Bool) -> NSView {
        let needsAction = r.liveState == "requires_action"
        let row = ShelfRowView()
        row.wantsLayer = true
        row.baseColor = needsAction ? Cat.peach.withAlphaComponent(0.12) : Cat.surface.withAlphaComponent(0.4)
        row.hoverColor = needsAction ? Cat.peach.withAlphaComponent(0.22) : Cat.surface1.withAlphaComponent(0.5)
        row.layer?.backgroundColor = row.baseColor.cgColor
        row.layer?.cornerRadius = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let (symbol, tint) = needsAction ? ("questionmark.circle.fill", Cat.peach)
            : r.liveState == "running" ? ("arrow.triangle.2.circlepath", Cat.green)
            : !r.enabled ? ("pause.circle", Cat.overlay)
            : ("clock", Cat.subtext)
        let glyph = NSImageView(image: symbolImage(symbol, size: 11, color: tint) ?? NSImage())
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let name = makeLabel(r.name, size: 12, weight: .medium, color: Cat.text)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(10), for: .horizontal)

        var trailing: [NSView] = [NSView()]
        if needsAction { trailing.append(pill(L("? 承認待ち", "? needs approval"), color: Cat.peach)) }
        let schedule = r.enabled ? routineNextRunText(r.nextRunAt).map { L("次回 \($0)", "next \($0)") }
                                 : L("無効", "disabled")
        if let schedule = schedule {
            let stamp = makeLabel(schedule, size: 10, color: Cat.overlay, mono: true)
            stamp.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.append(stamp)
        }
        if let kind = routineRunKind(r.lastRun?.status) {
            let (mark, markTint) = kind == "succeeded" ? ("checkmark.circle", Cat.green)
                : kind == "failed" ? ("xmark.circle", Cat.red)
                : kind == "cancelled" ? ("minus.circle", Cat.overlay)
                : ("hourglass", Cat.subtext)
            let iv = NSImageView(image: symbolImage(mark, size: 10, color: markTint) ?? NSImage())
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.setContentHuggingPriority(.required, for: .horizontal)
            trailing.append(iv)
        }

        let h = NSStackView(views: [glyph, name] + trailing)
        h.orientation = .horizontal
        h.spacing = 7
        h.alignment = .centerY
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            row.widthAnchor.constraint(equalToConstant: width),
        ])
        row.alphaValue = (r.enabled ? 1 : 0.5) * (stale ? 0.6 : 1)

        // The run a click opens: the one asking for approval when there is one, else the last run.
        // Both come from data the trigger record already carried, so the row stays clickable even
        // when the sessions pass failed.
        let runURL = routineSessionURL(r.liveSessionId ?? r.lastRun?.sessionId)
        let pageURL = "https://claude.ai/code/routines/\(r.id)"
        row.onClick = {
            if let u = URL(string: runURL ?? pageURL) { NSWorkspace.shared.open(u) }
        }
        // Schedule details hang off an anchored popover, never the bottom hint line — at 10.5pt in
        // the board's bottom-left corner the hint is out of view of the row being touched.
        row.onHover = { [weak self, weak row] entered in
            guard let self = self, let row = row else { return }
            guard entered else { self.hideHoverTip(from: row); return }
            let box = NSStackView(views: [
                makeLabel(r.name, size: 11.5, weight: .semibold, color: Cat.text),
                makeLabel(r.cronExpression.map { L("cron  \($0)", "cron  \($0)") }
                            ?? L("一度だけ実行", "runs once"), size: 10.5, color: Cat.subtext, mono: true),
                makeLabel(routineNextRunText(r.nextRunAt).map { L("次回  \($0)", "next  \($0)") }
                            ?? L("次回の予定なし", "no next run"), size: 10.5, color: Cat.subtext, mono: true),
                makeLabel(routineNextRunText(r.lastFiredAt).map { L("前回  \($0)", "last  \($0)") }
                            ?? L("実行履歴なし", "never fired"), size: 10.5, color: Cat.subtext, mono: true),
            ])
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 4
            self.showHoverTip(box, from: row)
        }
        row.menuProvider = {
            let menu = NSMenu()
            menu.autoenablesItems = false
            if let runURL = runURL {
                menu.addItem(ClosureMenuItem(L("最新の実行を開く", "Open the latest run")) {
                    if let u = URL(string: runURL) { NSWorkspace.shared.open(u) }
                })
            }
            menu.addItem(ClosureMenuItem(L("routine ページを開く", "Open the routine page")) {
                if let u = URL(string: pageURL) { NSWorkspace.shared.open(u) }
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("URL をコピー", "Copy URL")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(runURL ?? pageURL, forType: .string)
            })
            return menu
        }
        return row
    }
}
