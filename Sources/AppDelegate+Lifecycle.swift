import AppKit
import CoreServices

extension AppDelegate {
    // Stable per-monitor id (survives reconnects/reboots, unlike NSScreenNumber).
    func screenUUID(_ screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    // The display the panel mostly sits on (placement save + fullDisplay sizing share this).
    func screenUnderPanel() -> NSScreen? {
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = s.frame.intersection(panel.frame); return r.width * r.height
        }
        guard let scr = NSScreen.screens.max(by: { overlap($0) < overlap($1) }),
              overlap(scr) > 0 else { return nil }
        return scr
    }

    // Remember which display and where, as an offset from that display's top-left.
    func savePlacement() {
        guard let scr = screenUnderPanel(), let uuid = screenUUID(scr) else { return }
        defaults.set(uuid, forKey: "hudDisplayUUID")
        defaults.set(Double(panel.frame.minX - scr.frame.minX), forKey: "hudRelLeft")
        defaults.set(Double(scr.frame.maxY - panel.frame.maxY), forKey: "hudRelTop")
    }

    func restorePlacement(size: NSSize) {
        if let uuid = defaults.string(forKey: "hudDisplayUUID"),
           defaults.object(forKey: "hudRelLeft") != nil,
           let scr = NSScreen.screens.first(where: { screenUUID($0) == uuid }) {
            let x = scr.frame.minX + CGFloat(defaults.double(forKey: "hudRelLeft"))
            let top = scr.frame.maxY - CGFloat(defaults.double(forKey: "hudRelTop"))
            panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)
            return
        }
        // First run, or that display is unplugged: top-right of the main screen.
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16))
        }
    }

    // Clear and release the deck when Shepherd quits, so it doesn't keep showing a
    // stale board. Runs synchronously during termination (menu → Quit).
    func applicationWillTerminate(_ notification: Notification) {
        blinkTimer?.invalidate()
        guard let d = deck else { return }
        deck = nil
        d.stopInput()
        deckQueue.sync { d.close() }   // reset (clears keys) + close, after any in-flight render
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless self-check: `SHEPHERD_DUMP=1 Shepherd` prints the merged rows
        // to stderr and exits — used for fixture-driven testing since the HUD can't be inspected
        // programmatically (nonactivating accessory panel). No GUI is built in this mode.
        if ProcessInfo.processInfo.environment["SHEPHERD_DUMP"] != nil { dumpAndExit() }
        // Headless frames-endpoint probe (P0): measures header requirements + response shape via
        // the app's own token path — the token never leaves the process (ArtifactIndex.swift).
        if ProcessInfo.processInfo.environment["SHEPHERD_ARTIFACT_PROBE"] != nil { artifactProbeAndExit() }

        let rect = NSRect(x: 0, y: 0, width: contentWidth, height: 100)
        panel = KeyablePanel(contentRect: rect,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)

        // Nearly opaque solid background (readability first) with a thin border.
        let container = NSView(frame: rect)
        container.wantsLayer = true
        container.layer?.backgroundColor = Cat.base.withAlphaComponent(0.97).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Cat.surface.cgColor
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The stack lives inside a vertical-only scroll view (HUDサイズ 2026-07-08). In auto mode the
        // panel is sized to fit the content so scrolling never engages; in the fixed / fullDisplay
        // modes the panel keeps its size and taller content scrolls. The document is pinned to the
        // clip view's width — horizontal scrolling is structurally impossible.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scrollView = DragScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay   // legacy scrollers would eat width off the fixed board
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = doc
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        // Fixed width in row mode; deactivated in column mode so the stack grows to fit columns.
        stackWidthConstraint = stack.widthAnchor.constraint(equalToConstant: contentWidth - 24)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            stackWidthConstraint,
        ])

        // Restore onto the same physical display we were on last time. AppKit's own
        // frame autosave gets confused by this multi-display setup, so we identify the
        // display by its stable UUID and remember the position relative to it.
        restorePlacement(size: rect.size)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak self] _ in self?.savePlacement()
        }

        rebuild(rows: nil)
        panel.orderFrontRegardless()

        if defaults.bool(forKey: "deckEnabled") { enableDeck() }

        // ~/.claude/sessions — the file each claude process writes about itself — is the state
        // source, and FSEvents on it pushes every busy/idle/waiting flip into a refresh, so nothing
        // polls. A 30s fallback timer covers what FSEvents misses (and the slower-moving git / PR
        // facts). Nothing to GC: the CLI removes a session's file when it exits, and readSessionsRegistry
        // skips any file whose pid is gone.
        try? FileManager.default.createDirectory(atPath: claudeSessionsDir, withIntermediateDirectories: true)
        startFileWatch()
        // PR facts revalidate in the background (stale-while-revalidate); when one actually
        // changed, repaint through the normal debounced path.
        onPRFactsChanged = { [weak self] in
            DispatchQueue.main.async { self?.scheduleDebouncedRefresh() }
        }
        // Same deal for the account chip (claudeAccount is stale-while-revalidate too).
        onAccountChanged = { [weak self] in
            DispatchQueue.main.async { self?.scheduleDebouncedRefresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()

    }

    // Fixture-driven self-check (see SHEPHERD_DUMP above).
    func dumpAndExit() -> Never {
        func w(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        let rows = fetchAgents()
        w("ROWS \(rows.count)")
        let now = Date()
        for r in rows.sorted(by: { style(for: $0.status).order < style(for: $1.status).order }) {
            let ctx = r.contextPct.map { String(format: "%.0f%%", $0 * 100) } ?? "-"
            let age = Int(now.timeIntervalSince(r.statusSince))
            w("[\(r.backend)] \(r.status)\(r.stale ? " STALE" : "") | \(r.label) | sess=\(r.sessionId.prefix(8)) zellij=\(r.zellijSession ?? "-")\(r.zellijPaneId.map { ":p\($0)" } ?? "")\(r.zellijSendable ? "(sendable)" : "") branch=\(r.branch ?? "-") ±\(r.changedFiles.map(String.init) ?? "-") ctx=\(ctx) age=\(age)s links=\(r.links.count) agents=\(r.subagents.count) parent=\(r.parentSessionId.map { String($0.prefix(8)) } ?? "-")")
            if let act = r.activity { w("    prompt=\(act.prefix(80))") }
            for l in r.links { w("    link \(l.label): \(l.favicon ?? "") \(l.title.map { String($0.prefix(40)) } ?? "-") | \(l.url)") }
            if let lm = r.lastMessage { w("    last=\(lm.prefix(70))") }
            for a in r.subagents { w("    subagent \(a.type) [\(a.working ? "working" : "idle")]\(a.name.map { " \($0)" } ?? "")") }
        }
        // Artifact shelf index — transcript source only, scanned synchronously, so a fixture run
        // is deterministic (the API source needs a token and live network; fixture mode redirects
        // the index file to scratch — see ArtifactIndex.indexPath).
        ArtifactIndex.shared.scanTranscripts(projectsDir: claudeProjectsDir)
        let artifacts = ArtifactIndex.shared.snapshot()
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        w("ARTIFACTS \(artifacts.count)")
        for a in artifacts {
            w("  \(a.softDeleted ? "×" : "·") \(a.favicon ?? "-") \(a.title ?? String(a.slug.prefix(8))) | repo=\(a.repoName ?? "-") slug=\(a.slug.prefix(8)) api=\(a.lastSeenInAPI != nil)")
        }
        // Tree view: repo grouping + child-session nesting exactly as the HUD lays it out.
        w("TREE")
        for section in groupByRepo(rows) {
            if let h = section.header { w("# \(h)") }
            // Same split the board draws: the tree, then the archive lane of finished records.
            let (live, records) = partitionRecords(section.rows)
            for (row, depth) in treeOrder(live) {
                let indent = String(repeating: "  ", count: depth)
                let mark = depth > 0 ? "↳ " : ""
                w("\(indent)\(mark)[\(row.backend)] \(row.status) \(row.label) sess=\(row.sessionId.prefix(8)) links=\(row.links.count) 🤖\(row.subagents.count)")
            }
            if !records.isEmpty {
                w("  ▸ 終了済み記録 \(records.count)")
                for row in records { w("    · \(row.status) \(row.label) sess=\(row.sessionId.prefix(8))") }
            }
        }
        exit(0)
    }

    // MARK: - FSEvents (status dir + transcripts)

    // Watch ~/.claude/sessions (each claude process's own status file). We deliberately do NOT watch
    // ~/.claude/projects: transcripts append on every token so it would fire many times a
    // second, and the transcript-derived facts (context %, model) are already 20s-cached — so
    // reacting faster is pointless while the per-refresh git/herdr work is not. The hook writes
    // a status file on every meaningful event, so those writes double as the activity signal and
    // keep context reasonably fresh; the 30s fallback timer covers the rest.
    func startFileWatch() {
        let paths = [claudeSessionsDir] as CFArray
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { app.scheduleDebouncedRefresh() }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, fsQueue)
        FSEventStreamStart(stream)
        fsStream = stream
    }

    // 0.2s debounce, main-thread. Coalesces bursts and drops FSEvents' own thread before refresh.
    // (0.1s FSEvents latency + 0.2s debounce ≈ 0.3s floor from hook write to fetch start; the old
    // 0.3+0.5 put a 0.8s floor on every state change.)
    func scheduleDebouncedRefresh() {
        fsDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        fsDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // (The 5s herdr-signature poll that used to live here was retired in P2, 2026-07-10: the
    // sessions-registry files are on the FSEvents stream, so hook-less status flips push their
    // own refresh.)

    func refresh() {
        // Queue, don't drop: an FSEvents refresh arriving mid-refresh used to be discarded, so a
        // state change landing during a slow fetch stayed invisible until the 30s fallback timer.
        if isRefreshing { refreshPending = true; return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let rows = fetchAgents()
            // Timing evidence for the /tmp/shepherd-deck.log capture (stderr is unbuffered;
            // stdout would sit in stdio's file buffer).
            let line = String(format: "refresh %.2fs rows=%d\n", Date().timeIntervalSince(t0), rows.count)
            FileHandle.standardError.write(line.data(using: .utf8)!)
            DispatchQueue.main.async {
                self.lastRows = rows
                self.updateReplyWaiting(rows: rows)
                // Pause the row rebuild while a popover is open or a file drag is in progress
                // — recreating the rows would destroy the anchor / drop-target views.
                // The artifact-search hold is TIME-based (2s past the last keystroke), not
                // currentEditor(): a field that keeps the field editor while the user works
                // elsewhere would suppress rebuilds — and every board update — indefinitely.
                if self.replyPopover == nil && self.repoPickerPopover == nil && self.dropPopover == nil
                    && self.helpPopover == nil
                    && Date().timeIntervalSince(self.lastArtifactTypeAt) > 2.0
                    && Date().timeIntervalSince(self.lastDragAt) > 1.0 {
                    self.rebuild(rows: rows)
                }
                if self.deck != nil { self.renderDeck() }
                self.isRefreshing = false
                if self.refreshPending { self.refreshPending = false; self.refresh() }
            }
        }
        maybeRefreshUsage()
        maybeCheckForUpdate()
        // The inline ARTIFACTS section keeps itself fresh while open (15-min API guard, 5-min
        // scan guard — both no-ops most refreshes; nothing runs synchronously here).
        if !artifactsBarCollapsed && !minimized {
            maybeRefreshArtifacts(force: false)
            startArtifactScanGuarded()
        }
    }

    // Compare the bundle version against the latest GitHub release at most once a day, on its own
    // background hop. Additive: any failure just means no badge until the next attempt.
    func maybeCheckForUpdate() {
        guard !updateChecking, Date().timeIntervalSince(updateCheckedAt) > 24 * 3600,
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }
        updateChecking = true
        DispatchQueue.global(qos: .utility).async {
            let latest = fetchLatestRelease()
            DispatchQueue.main.async {
                self.updateChecking = false
                self.updateCheckedAt = Date()
                let update = latest.flatMap { isUpdateAvailable(latest: $0.tag, current: current) ? $0 : nil }
                let changed = update?.tag != self.availableUpdate?.tag
                self.availableUpdate = update
                if changed, self.replyPopover == nil, self.repoPickerPopover == nil,
                   self.dropPopover == nil, self.helpPopover == nil,
                   Date().timeIntervalSince(self.lastArtifactTypeAt) > 2.0,
                   Date().timeIntervalSince(self.lastDragAt) > 1.0 {
                    self.rebuild(rows: self.lastRows)
                }
            }
        }
    }

    // Fetch plan-usage at most once a minute, on its own background hop so a slow HTTP call never
    // blocks the 5s agent poll. Repaints when the snapshot changes. Stale-while-error: a failed
    // fetch must never replace good gauges (a sleep-wake network blip used to blank the whole
    // dashboard for a minute) — keep the old snapshot and stamp usageError instead.
    // Runs even with the dashboard hidden: the header's credit-burn and quota-alert chips render
    // from this data regardless of the toggle, and a hidden dashboard used to freeze them at
    // whatever state the last visible fetch saw (review finding, 2026-07-17).
    func maybeRefreshUsage() {
        guard !usageFetching,
              Date().timeIntervalSince(usageFetchedAt) > 60 else { return }
        usageFetching = true
        DispatchQueue.global(qos: .utility).async {
            let snap = fetchClaudeUsage()
            DispatchQueue.main.async {
                self.usageFetching = false
                self.usageFetchedAt = Date()
                if let snap = snap {
                    if snap.error == nil {
                        // Credit-burn state: compare this snapshot's spend.used against the last
                        // one's (kept across failed fetches — an error snapshot must not reset the
                        // baseline). The fake seam wins so captures don't flicker off on a fetch.
                        if ProcessInfo.processInfo.environment["SHEPHERD_FAKE_CREDIT_BURN"] == nil {
                            let anyWorking = (self.lastRows ?? []).contains { $0.status == "working" }
                            self.creditBurn = creditBurnActive(prevUsedMinor: self.creditPrevUsedMinor,
                                                               credit: snap.credit, windows: snap.windows,
                                                               anyWorking: anyWorking)
                        }
                        if let used = snap.credit?.usedMinor { self.creditPrevUsedMinor = used }
                        self.lastUsage = snap
                        self.usageError = nil
                    } else {
                        self.usageError = snap.error
                        // Nothing to keep? Show the error snapshot itself (message body).
                        if self.lastUsage == nil { self.lastUsage = snap }
                    }
                } else {
                    self.usageError = L("トークンが読めない", "no oauth token")
                }
                if self.replyPopover == nil && self.repoPickerPopover == nil && self.dropPopover == nil
                    && self.helpPopover == nil
                    && Date().timeIntervalSince(self.lastArtifactTypeAt) > 2.0 {
                    self.rebuild(rows: self.lastRows)
                }
            }
        }
    }

    // The dashboard's ↻: refresh EVERYTHING the header shows, bypassing every cache guard —
    // usage/credit (60s), plan tier (24h), account chip. Then one board refresh so card facts
    // follow. Safe to spam: usageFetching still dedupes concurrent fetches.
    func forceDashboardRefresh() {
        usageFetchedAt = .distantPast
        factsLock.lock(); planTierCache = nil; accountCache = nil; factsLock.unlock()
        maybeRefreshUsage()
        refresh()
    }

    // Percent at/above which a weekly quota window is mirrored into the header (A9). Default 90;
    // override: `defaults write … quotaAlertPercent 80`.
    var quotaAlertPercent: Double {
        defaults.object(forKey: "quotaAlertPercent") == nil ? 90 : defaults.double(forKey: "quotaAlertPercent")
    }

    // The weekly-quota window (all-models or a model-scoped week) most in need of attention — over
    // the alert threshold or flagged critical by the API. nil when everything's comfortably below.
    func quotaAlertWindow() -> UsageWindow? {
        guard let usage = lastUsage, usage.error == nil else { return nil }
        let threshold = quotaAlertPercent
        return usage.windows
            .filter { $0.key != "session" && ($0.percent >= threshold || $0.severity == "critical" || $0.severity == "severe") }
            .max(by: { $0.percent < $1.percent })
    }

    // Bring the usage dashboard into view (turn it on / un-minimize) so the A9 alert chip can jump
    // straight to it, and force an immediate refresh of the numbers.
    func revealUsagePanel() {
        if !showUsageDashboard { showUsageDashboard = true; defaults.set(true, forKey: "showUsageDashboard") }
        if minimized { minimized = false; defaults.set(false, forKey: "minimized") }
        usageFetchedAt = .distantPast
        rebuild(rows: lastRows)
        maybeRefreshUsage()
    }

}
