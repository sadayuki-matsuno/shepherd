import AppKit

extension AppDelegate {
    // Shut a session down, but only if its working tree is still clean. The displayed change count
    // can be up to 5s stale, so re-check git at click time. Which shutdown applies is decided by
    // closeMethod (see its comment for why each kind needs its own): a background agent is stopped
    // out of the daemon roster, and a bare interactive session is SIGTERMed.
    //
    // Only drop the status file once the session is PROVEN gone. `claude stop` exits 0 even when the
    // daemon never answered it, so taking its word clears the card while the process keeps running.
    // stopBackgroundWorker does the proving; when it fails we say so and leave the card up.
    func closeWorkspace(_ row: AgentRow) {
        let method = closeMethod(for: row)
        if method == .unavailable { return }
        guard !deletingSessions.contains(row.sessionId) else { return }   // already in flight
        // Mark the stop in flight: the card renders inert with a spinner until the outcome lands
        // (stopBackgroundWorker alone can sit on the daemon for seconds proving the kill).
        deletingSessions.insert(row.sessionId)
        rebuild(rows: lastRows)
        DispatchQueue.global(qos: .userInitiated).async {
            if !row.cwd.isEmpty,
               let st = runCommand([gitBin, "-C", row.cwd, "status", "--porcelain"]),
               !st.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async {   // became dirty — refresh, don't close
                    self.deletingSessions.remove(row.sessionId)
                    self.refresh()
                }
                return
            }
            var stopped = true
            switch method {
            case .stopBackgroundAgent(let id):
                stopped = stopBackgroundWorker(id)
            case .stopSession(let id, let pid):
                // `claude stop` doesn't know an interactive session ("No job matching …", exit 1) — SIGTERM
                // is what ends it. But a row we couldn't prove is a background agent (no `claude agents`
                // entry) may still be one, and those must die through the roster or the daemon respawns
                // them. The socket answers that in a millisecond, so ask instead of guessing.
                if daemonJobExists(id) {
                    stopped = stopBackgroundWorker(id)
                } else if let pid = pid, pidAlive(pid) {
                    kill(pid, SIGTERM)
                }
            case .unavailable:
                break
            }
            DispatchQueue.main.async {
                self.deletingSessions.remove(row.sessionId)
                if !stopped { self.flashHint(L("停止できませんでした — \(row.label)", "couldn't stop \(row.label)")) }
                self.refresh()
            }
        }
    }

    // Delete a finished background agent's record (`claude rm <id>`) — the only way off the agent-view
    // list once its process is gone. Destructive: rm removes the session's git worktree too (the
    // conversation transcript survives), so always confirm, on a sheet anchored to the HUD's own screen
    // (a free-floating modal lands on the menu-bar display — same reason closeIdleWorkspacesInColumn
    // uses a sheet).
    func removeAgentRecord(_ row: AgentRow) {
        guard let id = removableRecord(row), let claudeBin = claudeBin else { return }
        guard !deletingSessions.contains(row.sessionId) else { return }   // already in flight
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("この記録を削除しますか？", "Delete this session record?")
        alert.informativeText = L("claude rm \(id) を実行します。エージェント一覧から消え、worktree があれば一緒に削除されます（会話の記録は残ります）。",
                                  "Runs `claude rm \(id)`. It leaves the agent list and its worktree, if any, is deleted (the conversation transcript is kept).")
        alert.addButton(withTitle: L("削除", "Delete"))
        alert.addButton(withTitle: L("キャンセル", "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            // Mark the rm in flight: the card renders inert with a spinner until the outcome lands
            // (`claude rm` waits on daemon confirmation — the slow case this feedback exists for).
            self.deletingSessions.insert(row.sessionId)
            self.rebuild(rows: self.lastRows)
            DispatchQueue.global(qos: .userInitiated).async {
                // `claude rm` refuses whenever the cc-daemon isn't running ("couldn't confirm … was
                // stopped", exit 1 — measured 2026-07-09): it insists on the service confirming the
                // stop even for a long-dead record, and the daemon idle_exits the moment the last
                // worker ends, so this is the COMMON case, not the exception. The record itself is
                // just ~/.claude/jobs/<short>/ (state.json + timeline — verified as what `agents
                // --all` reads), so when rm fails, remove that directory ourselves. rm still runs
                // first for its extra cleanup (worktree removal) when a daemon is around.
                var ok = runCommand([claudeBin, "rm", id]) != nil
                if !ok {
                    let jobDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/jobs/\(id)")
                    ok = (try? FileManager.default.removeItem(atPath: jobDir)) != nil
                }
                DispatchQueue.main.async {
                    self.deletingSessions.remove(row.sessionId)
                    if ok { self.flashHint(L("記録 \(id) を削除しました", "removed record \(id)"), color: Cat.green) }
                    else { self.flashHint(L("削除に失敗しました — claude rm \(id)", "couldn't remove — claude rm \(id)")) }
                    self.refresh()
                }
            }
        }
    }

    // Close the clean, finished (idle OR done) sessions *within one column* — the repo group whose
    // header menu was used (v6 #2). done joined idle as a close target on 2026-07-08: both are the
    // same "finished/quiet" lane visually, and leaving done out made the action feel broken. As of
    // 2026-07-09 this also closes done/idle rows (bare-terminal / zellij / headless-daemon
    // sessions) by killing their pid — previously they had no close path and lingered as ghost cards.
    // dirty (uncommitted) and busy sessions are left alone (safe side); closeWorkspace re-verifies
    // cleanliness just before closing. De-dupes by workspace/session id (closableFinished). Confirms
    // with an alert when 2+ will close, then summarises via flashHint.
    func closeIdleWorkspacesInColumn(key: String) {
        let closableStates: Set<String> = ["idle"]
        let sections = groupByRepo(lastRows ?? [])
        guard let section = sections.first(where: { repoGroupKey($0) == key }) else {
            flashHint(L("この列に閉じられるワークスペースはありません", "no closable workspaces in this column"))
            return
        }
        let (closable, dirtySkipped) = closableFinished(section.rows)
        if closable.isEmpty {
            // Say what the column actually holds instead of a blanket "nothing" (2026-07-07: four
            // limit-hit sessions all read as error and the plain message looked like a false negative).
            var byStatus: [String: Int] = [:]
            var counted = Set<String>()
            for r in section.rows where closeMethod(for: r) != .unavailable && !closableStates.contains(r.status) {
                if counted.insert(r.sessionId).inserted { byStatus[r.status, default: 0] += 1 }
            }
            var parts: [String] = []
            for s in ["blocked", "error", "working"] {
                if let n = byStatus[s] { parts.append("\(style(for: s).word) \(n)") }
            }
            if dirtySkipped > 0 {
                parts.append(L("未コミットあり \(dirtySkipped)", "uncommitted \(dirtySkipped)"))
            }
            if parts.isEmpty {
                flashHint(L("この列に閉じられるセッションはありません", "no closable sessions in this column"))
            } else {
                flashHint(L("閉じられる完了・待機はありません — ", "no closable done/idle — ") + parts.joined(separator: " · "))
            }
            return
        }
        let doClose: () -> Void = { [weak self] in
            guard let self = self else { return }
            for r in closable { self.closeWorkspace(r) }
            let msg = dirtySkipped > 0
                ? L("この列の完了・待機 \(closable.count) 件を閉じました（未コミット \(dirtySkipped) 件はスキップ）",
                    "closed \(closable.count) done/idle in this column (skipped \(dirtySkipped) with uncommitted changes)")
                : L("この列の完了・待機 \(closable.count) 件を閉じました", "closed \(closable.count) done/idle in this column")
            self.flashHint(msg, color: Cat.green)
        }
        // Destructive: confirm when closing 2+ at once. Activate first — a nonactivating panel can't
        // front an alert otherwise (same reason the reply box calls activate). Present as a *sheet on
        // the HUD panel* rather than a free-floating runModal alert: the panel is a borderless
        // nonactivating window with no ordinary host, so a modal alert centers on the main (menu-bar)
        // display — landing on the wrong monitor when the HUD lives on another. A sheet is anchored to
        // its parent window, so it always appears on the HUD's own screen (v6fix #2). runModal +
        // repositioning is unreliable here because NSAlert re-centers its window when run.
        if closable.count >= 2 {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("この列の完了・待機ワークスペースを閉じますか？", "Close done/idle workspaces in this column?")
            alert.informativeText = dirtySkipped > 0
                ? L("clean な完了・待機 \(closable.count) 件を閉じます（未コミット \(dirtySkipped) 件は残します）。",
                    "Will close \(closable.count) clean done/idle workspaces (keeping \(dirtySkipped) with uncommitted changes).")
                : L("clean な完了・待機 \(closable.count) 件を閉じます。", "Will close \(closable.count) clean done/idle workspaces.")
            alert.addButton(withTitle: L("閉じる", "Close"))
            alert.addButton(withTitle: L("キャンセル", "Cancel"))
            alert.beginSheetModal(for: panel) { resp in
                if resp == .alertFirstButtonReturn { doClose() }
            }
        } else {
            doClose()
        }
    }

    // Deliver text (+ optional Enter) to a row's zellij session — single-pane via the focused-pane
    // fast path (works even detached), else targeted at the row's own pane id (multi-pane, needs an
    // attached client). Must run off the main thread. Returns false when the send was refused so
    // the caller can hint.
    @discardableResult
    func deliverText(_ text: String, to row: AgentRow, enter: Bool = true) -> Bool {
        if row.backend == .zellij, let zs = row.zellijSession {
            if row.zellijSendable, sendToZellij(zs, text: text, enter: enter) { return true }
            if let paneId = row.zellijPaneId { return sendToZellijPane(zs, paneId: paneId, text: text, enter: enter) }
            return false
        }
        return false
    }

    // The zellij "couldn't send" reason, for the hint line.
    func zellijBlockedHint() {
        flashHint(L("送信できません — 複数ペインの zellij は attach 中のみ送信可（カードをクリックして開いてから再試行）",
                    "couldn't send — a multi-pane zellij session needs an attached client (open it first, then retry)"))
    }

    // Send /remote-control to the session so it can be driven from claude.ai (phone). The row keeps
    // a small antenna mark afterwards as an "enabled" indicator.
    func remoteControlRow(_ row: AgentRow) {
        remoteEnabledSessions.insert(row.sessionId)
        rebuild(rows: lastRows)   // show the mark immediately
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.deliverText("/remote-control", to: row)
            if !ok {
                DispatchQueue.main.async {
                    self.remoteEnabledSessions.remove(row.sessionId)
                    self.zellijBlockedHint()
                    self.rebuild(rows: self.lastRows)
                }
            }
        }
    }

    func setHint(_ s: String?) {
        if let s = s {                       // an explicit hover overrides any active flash
            cancelHintFlash()
            hintLabel?.textColor = Cat.overlay
            hintLabel?.stringValue = s
        } else if !hintSticky {              // keep a flashed message until it times out
            hintLabel?.stringValue = ""
        }
    }

    private func cancelHintFlash() {
        hintFlashWork?.cancel(); hintFlashWork = nil; hintSticky = false
    }

    // Flash a message on the hint line in response to a click (e.g. a disabled-looking button
    // explaining why it did nothing). Stays put until the pointer hovers something else or it
    // times out — hover-exit alone won't clear it.
    func flashHint(_ s: String, color: NSColor = Cat.peach, seconds: TimeInterval = 4) {
        cancelHintFlash()
        hintSticky = true
        hintLabel?.textColor = color
        hintLabel?.stringValue = s
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.hintSticky = false; self.hintFlashWork = nil
            self.hintLabel?.textColor = Cat.overlay
            self.hintLabel?.stringValue = ""
        }
        hintFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - File drag & drop

    func setDragTarget(_ card: RowView) {
        lastDragAt = Date()
        if dragTarget !== card { dragTarget = card; updateDragVisuals() }
    }
    func dragExited(_ card: RowView) {
        lastDragAt = Date()
        if dragTarget === card { dragTarget = nil; updateDragVisuals() }
    }
    func updateDragVisuals() {
        let active = dragTarget != nil
        for c in stack.arrangedSubviews.compactMap({ $0 as? RowView }) {
            c.applyDragVisual(target: c === dragTarget, dimmed: active && c !== dragTarget)
        }
    }

    func handleDrop(_ urls: [URL], row: AgentRow, anchor: NSView) {
        dragTarget = nil
        updateDragVisuals()
        guard row.sendable else { return }
        showDropPopover(urls: urls, row: row, anchor: anchor)
    }

    // Confirm the files to attach (+ an optional message) before sending.
    func showDropPopover(urls: [URL], row: AgentRow, anchor: NSView) {
        dropPopover?.close()
        let width: CGFloat = 300
        let title = makeLabel(L("\(urls.count) 個のファイルを \(row.label) へ", "\(urls.count) file(s) → \(row.label)"), size: 12, weight: .semibold)
        let names = makeLabel(urls.map { $0.lastPathComponent }.joined(separator: ", "), size: 10.5, color: Cat.subtext)
        names.lineBreakMode = .byTruncatingMiddle
        let field = NSTextField()
        field.placeholderString = L("メッセージ（任意）", "message (optional)")
        field.translatesAutoresizingMaskIntoConstraints = false
        let cancel = ActionButton(title: L("キャンセル", "Cancel"), target: nil, action: nil)
        cancel.bezelStyle = .rounded; cancel.target = cancel; cancel.action = #selector(ActionButton.fire)
        cancel.onPress = { [weak self] in self?.dropPopover?.close() }
        let send = ActionButton(title: L("送信", "Send"), target: nil, action: nil)
        send.bezelStyle = .rounded; send.target = send; send.action = #selector(ActionButton.fire); send.keyEquivalent = "\r"
        send.onPress = { [weak self, weak field] in
            let msg = field?.stringValue ?? ""
            self?.dropPopover?.close()
            self?.sendFilesToRow(urls: urls, message: msg, row: row)
        }
        let buttons = NSStackView(views: [cancel, NSView(), send]); buttons.orientation = .horizontal; buttons.distribution = .fill
        let vstack = NSStackView(views: [title, names, field, buttons])
        vstack.orientation = .vertical; vstack.spacing = 8
        vstack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 130))
        container.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: container.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        let vc = NSViewController(); vc.view = container
        let pop = NSPopover(); pop.contentViewController = vc; pop.behavior = .applicationDefined; pop.delegate = self
        pop.contentSize = NSSize(width: width, height: 130)
        dropPopover = pop
        dropEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.dropPopover?.close(); return nil }
            return e
        }
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        container.window?.makeKey()
        container.window?.makeFirstResponder(field)
    }

    // Copy the files into our own scratch dir (so the agent can Read them even if the user deletes
    // the originals, and to sidestep ~/Downloads TCC), then send the paths + message to the row's
    // zellij session.
    func sendFilesToRow(urls: [URL], message: String, row: AgentRow) {
        guard !urls.isEmpty, row.sendable else { return }
        dropSentSession = row.sessionId
        rebuild(rows: lastRows)   // show "📎 送信済み" immediately
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = "/tmp/shepherd-drop"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var paths: [String] = []
            for u in urls {
                let dest = (dir as NSString).appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.removeItem(atPath: dest)
                if (try? FileManager.default.copyItem(at: u, to: URL(fileURLWithPath: dest))) != nil { paths.append(dest) }
            }
            guard !paths.isEmpty else { return }
            var text = paths.joined(separator: " ")
            if !message.isEmpty { text += " " + message }
            let ok = self.deliverText(text, to: row)
            DispatchQueue.main.async {
                if !ok { self.zellijBlockedHint() }
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if self.dropSentSession == row.sessionId {
                        self.dropSentSession = nil
                        self.rebuild(rows: self.lastRows)
                    }
                }
            }
        }
    }

    // MARK: - Capture sharing

    // Interactive region capture (⌘⇧⌘4-style). Hides the HUD so it's not in the shot,
    // saves under /tmp/shepherd-capture, and returns the path (nil if the user cancelled).
    func captureRegion(_ completion: @escaping (String?) -> Void) {
        let dir = "/tmp/shepherd-capture"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let path = (dir as NSString).appendingPathComponent("\(f.string(from: Date())).png")
        panel.orderOut(nil)   // keep the HUD out of the screenshot
        DispatchQueue.global(qos: .userInitiated).async {
            // Interactive capture: the user may take a while to drag the region — exempt from
            // the default 10s subprocess timeout.
            _ = runCommand(["/usr/sbin/screencapture", "-i", path], timeout: 600)
            let ok = FileManager.default.fileExists(atPath: path)
            DispatchQueue.main.async {
                self.panel.orderFrontRegardless()
                completion(ok ? path : nil)
            }
        }
    }

    // Row 📷: capture a region and send it straight to that agent's zellij session.
    func captureAndSendRow(_ row: AgentRow) {
        guard row.sendable else { return }
        captureRegion { [weak self] path in
            guard let self = self, let path = path else { return }
            self.sendFilesToRow(urls: [URL(fileURLWithPath: path)], message: "", row: row)
        }
    }

    // A tray button: SF Symbol + short label, tinted, with a self-drawn hover hint.
}

// Stop a cc-daemon background worker and confirm it is really gone. Returns false if it survived.
//
// The daemon's own control socket is the fast path (~1ms, no subprocess) but its `ok` only means
// "accepted": the worker leaves the roster a few hundred ms later. `claude stop` is the fallback,
// because the CLI carries a recovery the socket cannot — when the daemon is unreachable it hunts the
// process down and SIGTERMs it. Either way the verdict comes from asking the roster again, never from
// an exit code. See DaemonControl.swift.
private func stopBackgroundWorker(_ short: String) -> Bool {
    if daemonKill(short) {
        for _ in 0..<10 {
            if !daemonJobExists(short) { return true }
            usleep(200_000)
        }
    }
    guard let claudeBin = claudeBin else { return !daemonJobExists(short) }
    _ = runCommand([claudeBin, "stop", short])
    return !daemonJobExists(short)
}
