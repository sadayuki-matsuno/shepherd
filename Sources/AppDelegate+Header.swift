import AppKit

extension AppDelegate {
    // The header is TWO independent bars (2026-07-11), returned separately so rebuild can slot the
    // plan-usage dashboard between them: the BRAND BAR (logo · account … window controls) sits at
    // the very top, and the STATUS ROW (24h filter + summary pills) sits just above the board, under
    // the usage gauges — where the filter belongs. `status` is nil when minimized.
    func headerView(rows: [AgentRow]?) -> (brand: NSView, status: NSView?) {
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 6

        // Logo at the top-left (B6): the app mark (doubles as the settings-menu button) + a
        // "Shepherd" wordmark. The whole panel is drag-movable, so the brand also reads as the
        // window's grab handle. At minimized width we keep the mark and drop the wordmark.
        let markBtn = NSButton(title: "", target: self, action: #selector(showDeckMenu(_:)))
        markBtn.isBordered = false
        markBtn.imagePosition = .imageOnly
        if let icon = markIcon, let img = icon.copy() as? NSImage {
            img.size = NSSize(width: 20, height: 20); markBtn.image = img
        } else {
            markBtn.title = "❯"; markBtn.imagePosition = .noImage
            markBtn.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            markBtn.contentTintColor = Cat.blue
        }
        markBtn.toolTip = L("設定メニュー（ドラッグで移動）", "settings menu (drag to move)")
        markBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        topBar.addArrangedSubview(markBtn)
        if !minimized {
            let word = makeLabel("Shepherd", size: 12.5, weight: .heavy, color: Cat.subtext)
            word.setContentCompressionResistancePriority(.required, for: .horizontal)
            topBar.addArrangedSubview(word)
        }
        // The logged-in Claude account, so it's obvious whose usage/limits the sessions draw on.
        // Its local part reads at a glance; the plan and full address are in the tooltip. Clicking
        // it opens the usage panel (same as the quota chip). Skipped when minimized or logged out.
        if !minimized, let acct = claudeAccount() {
            let planTip = acct.plan.map { " · \($0.uppercased())" } ?? ""
            let chip = badge(acct.email, symbol: "person.crop.circle", fg: Cat.overlay,
                             bg: Cat.overlay.withAlphaComponent(0.14),
                             tip: acct.email + planTip) { [weak self] in self?.revealUsagePanel() }
            topBar.addArrangedSubview(chip)
        }

        // A newer GitHub release exists: a badge on the brand bar, so it survives minimizing.
        // Click opens the release page — updating stays a user action (brew upgrade); Shepherd
        // only points at it.
        if let up = availableUpdate {
            let chip = badge(L("更新 \(up.tag)", "update \(up.tag)"), symbol: "arrow.up.circle.fill",
                             fg: Cat.teal, bg: Cat.teal.withAlphaComponent(0.16),
                             tip: L("新しいバージョンがあります — クリックでリリースページを開く",
                                    "a newer release is available — click to open its release page")) {
                if let url = URL(string: up.url) { NSWorkspace.shared.open(url) }
            }
            topBar.addArrangedSubview(chip)
        }

        let brandSpacer = NSView()
        topBar.addArrangedSubview(brandSpacer)

        // Window controls live on the brand bar (2026-07-11): minimize / new session / help /
        // settings, right-aligned. Built below and appended after the spacer.
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        let header = statusRow   // the status pills below are added to this row

        // 24h filter toggle (B5). Click flips between 24h-recency and all.
        do {
            let on = timeFilter == .last24h
            let fchip = badge(on ? L("● 24時間以内 ▾", "● 24h ▾") : L("すべて表示 ▾", "all ▾"),
                              fg: on ? Cat.green : Cat.overlay,
                              bg: (on ? Cat.green : Cat.overlay).withAlphaComponent(0.14),
                              tip: L("表示範囲を切り替え（24時間以内 / すべて）", "toggle range (last 24h / all)")) { [weak self] in
                self?.toggleTimeFilter()
            }
            header.addArrangedSubview(fchip)
        }

        if worktreeCreating {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            header.addArrangedSubview(spinner)
            header.addArrangedSubview(makeLabel(L("worktree を作成中…", "creating worktree…"), size: 11, weight: .semibold, color: Cat.yellow))
        } else if let err = sessionError {
            header.addArrangedSubview(pill(err, color: Cat.red))
        } else if let rows = rows {
            let blocked = rows.filter { $0.status == "blocked" }.count
            let working = rows.filter { $0.status == "working" }.count
            if blocked > 0 { header.addArrangedSubview(pill(L("応答待ち \(blocked)", "needs input \(blocked)"), color: Cat.peach)) }
            if working > 0 { header.addArrangedSubview(pill(L("作業中 \(working)", "working \(working)"), color: Cat.green)) }
            if blocked == 0 && working == 0 {
                header.addArrangedSubview(pill(rows.isEmpty ? L("agent なし", "no agents") : L("すべて待機", "all idle"), color: Cat.overlay))
            }
        }

        // A9: when a weekly quota window is over threshold, mirror it into the header pill row so
        // it's impossible to miss even when engrossed in the board. Click reveals the usage panel.
        if let w = quotaAlertWindow() {
            let sev = w.percent >= 95 || w.severity == "critical" || w.severity == "severe"
            let color = sev ? Cat.red : Cat.peach
            let chip = badge("\(w.label) \(Int(w.percent.rounded()))%", symbol: "exclamationmark.triangle.fill",
                             symbolSize: 10, fg: color, bg: color.withAlphaComponent(0.16),
                             tip: L("使用量パネルを表示", "show the usage panel")) { [weak self] in self?.revealUsagePanel() }
            header.addArrangedSubview(chip)
        }

        // Deck condition shows in the header only briefly around a real connect/disconnect event
        // (A7). "Not connected" is the norm and stays out of the header — it's in the ⚙ menu.
        if let ds = deckStatus, let until = deckWarnUntil, Date() < until {
            header.addArrangedSubview(pill(ds, color: Cat.peach))
        }

        let spacer = NSView()
        header.addArrangedSubview(spacer)

        // Right-aligned window controls (v7): symbol-only buttons, uniform size. They live on the
        // BRAND BAR (topBar), pushed to the trailing edge by brandSpacer. Text glyphs render so small
        // they read as mystery dots — use SF Symbols at one size instead.
        func toolButton(_ symbol: String, action: Selector, tip: String, tint: NSColor = Cat.overlay) -> NSButton {
            let b = NSButton(title: "", target: self, action: action)
            b.isBordered = false
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) {
                b.image = img; b.imagePosition = .imageOnly
            }
            b.contentTintColor = tint
            b.toolTip = tip
            return b
        }
        let mini = toolButton(minimized ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                              action: #selector(toggleMinimized),
                              tip: minimized ? L("元に戻す", "expand")
                                             : L("最小化（ダッシュボードとサマリのみ）", "minimize (dashboard + summary only)"))
        topBar.addArrangedSubview(mini)
        // "+" makes a NEW session (a new card), so it lives on the status row at the top-right of the
        // board, next to the cards it creates — not up on the brand bar (2026-07-11). The status row
        // is hidden when minimized, which is fine: there's no board to add a card to then.
        if ghqBin != nil, !minimized {
            let plus = toolButton("plus", action: #selector(showNewSessionMenu(_:)),
                                  tip: L("新しいセッションを開始", "start a new session"))
            header.addArrangedSubview(plus)
        }
        let help = toolButton("questionmark.circle", action: #selector(showHelp(_:)),
                              tip: L("アイコン・表示の説明", "what the icons mean"))
        topBar.addArrangedSubview(help)
        // Always neutral — deck connection state lives in the ⚙ menu, not the button tint
        // (the teal tint read as "something's wrong with settings", 2026-07-08 feedback).
        let gear = toolButton("gearshape.fill", action: #selector(showDeckMenu(_:)),
                              tip: L("設定", "settings"))
        topBar.addArrangedSubview(gear)

        // Each row's spacer — and only its spacer — absorbs the leftover width. Without explicit
        // priorities the fixed-width constraint resolves ambiguously and a pill gets squeezed to "…".
        func packRow(_ row: NSStackView, spacer: NSView) {
            row.distribution = .fill
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            for v in row.arrangedSubviews where v !== spacer {
                v.setContentHuggingPriority(.required, for: .horizontal)
                v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(999), for: .horizontal)
            }
        }
        packRow(topBar, spacer: brandSpacer)
        packRow(header, spacer: spacer)

        // Both bars span the real board (boardWidth = N columns + gaps), not the legacy 320pt
        // contentWidth. The narrow width remains only for the minimized strip and the empty state.
        let wide = !minimized && !(rows?.isEmpty ?? true)
        let width = wide ? boardSpanWidth : contentWidth - 24
        topBar.widthAnchor.constraint(equalToConstant: width).isActive = true
        if minimized { return (topBar, nil) }
        header.widthAnchor.constraint(equalToConstant: width).isActive = true
        return (topBar, header)
    }

    @objc func setHudSizeMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = HUDSizeMode(rawValue: raw), mode != hudSizeMode else { return }
        hudSizeMode = mode
        defaults.set(mode.rawValue, forKey: "hudSizeMode")
        rebuild(rows: lastRows)
    }

    @objc func toggleUsageDashboard() {
        showUsageDashboard.toggle()
        defaults.set(showUsageDashboard, forKey: "showUsageDashboard")
        if showUsageDashboard { usageFetchedAt = .distantPast; maybeRefreshUsage() }
        rebuild(rows: lastRows)
    }

    @objc func showDeckMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let usageItem = NSMenuItem(title: L("プラン使用量を表示", "Show plan usage"), action: #selector(toggleUsageDashboard), keyEquivalent: "")
        usageItem.target = self
        usageItem.state = showUsageDashboard ? .on : .off
        menu.addItem(usageItem)

        // HUD サイズ (2026-07-08): 自動（従来の内容追従）/ 固定3種（縦スクロールのみ）/ フルディスプレイ。
        let sizeItem = NSMenuItem(title: L("HUD サイズ", "HUD size"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        let sizeChoices: [(HUDSizeMode, String)] = [
            (.auto, L("自動（内容に合わせる）", "Auto (fit content)")),
            (.small, L("小（1列）", "Small (1 column)")),
            (.medium, L("中（2列）", "Medium (2 columns)")),
            (.large, L("大（3列）", "Large (3 columns)")),
            (.fullDisplay, L("フルディスプレイ", "Full display")),
        ]
        for (mode, name) in sizeChoices {
            let choice = NSMenuItem(title: name, action: #selector(setHudSizeMode(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = mode.rawValue
            choice.state = hudSizeMode == mode ? .on : .off
            sizeMenu.addItem(choice)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        // Only offer the toggle when a deck is actually attached (or already in use).
        let present = deck != nil || StreamDeck.isPresent()
        let item = NSMenuItem(title: L("Stream Deck を使う", "Use Stream Deck"), action: #selector(toggleDeck), keyEquivalent: "")
        item.target = self
        item.state = deck != nil ? .on : .off
        item.isEnabled = present
        menu.addItem(item)
        if !present {
            let info = NSMenuItem(title: L("Stream Deck が接続されていません", "No Stream Deck connected"), action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        } else if let ds = deckStatus {
            menu.addItem(.separator())
            let info = NSMenuItem(title: ds, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        let repo = NSMenuItem(title: L("GitHub リポジトリを開く", "Open the GitHub repo"), action: #selector(openShepherdRepo), keyEquivalent: "")
        repo.target = self
        menu.addItem(repo)
        // The running version, so "which build am I on?" never needs a trip to the repo. When a
        // newer release exists the line becomes clickable and opens its release page (the same
        // place the header badge points).
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            if let up = availableUpdate {
                let item = NSMenuItem(title: L("Shepherd v\(version)（更新 \(up.tag) あり）", "Shepherd v\(version) (update \(up.tag) available)"),
                                      action: #selector(openReleasePage), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: "Shepherd v\(version)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Shepherd を終了", "Quit Shepherd"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func openReleasePage() {
        if let url = URL(string: availableUpdate?.url ?? shepherdReleasesURL) { NSWorkspace.shared.open(url) }
    }

    // ＋: a small search picker over base ghq repos (linked worktrees excluded); picking one
    // creates a fresh worktree (herd-issues convention) and launches claude in it.
    @objc func showNewSessionMenu(_ sender: NSButton) {
        // Toggle: a second click on ＋ while the picker is up closes it instead of stacking a second
        // popover on top of the first (2026-07-11 report).
        if repoPickerPopover != nil { closeRepoPicker(); return }
        guard let ghq = ghqBin, let out = runCommand([ghq, "list", "--full-path"]) else { return }
        var all: [(title: String, path: String)] = []
        for path in out.split(separator: "\n").map(String.init) {
            var isDir: ObjCBool = false
            let git = (path as NSString).appendingPathComponent(".git")
            // Linked worktrees have a .git *file*; base repos have a .git *directory*.
            guard FileManager.default.fileExists(atPath: git, isDirectory: &isDir), isDir.boolValue else { continue }
            all.append((path.split(separator: "/").suffix(2).joined(separator: "/"), path))
        }
        repoPickerAll = all
        repoPickerFiltered = all

        let width: CGFloat = 320
        let search = NSTextField()
        search.placeholderString = L("リポジトリを検索…", "search repositories…")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        repoPickerSearch = search

        let table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo"))
        col.width = width - 24
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(repoPickerConfirm)
        repoPickerTable = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let vstack = NSStackView(views: [search, scroll])
        vstack.orientation = .vertical
        vstack.spacing = 8
        vstack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 280))
        container.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: container.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let vc = NSViewController()
        vc.view = container
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .applicationDefined
        pop.delegate = self
        pop.contentSize = NSSize(width: width, height: 280)
        repoPickerPopover = pop

        repoPickerEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let table = self.repoPickerTable else { return event }
            switch event.keyCode {
            case 53: self.closeRepoPicker(); return nil                       // Esc
            case 36, 76: self.repoPickerConfirm(); return nil                 // Return / Enter
            case 125:                                                          // Down
                let n = self.repoPickerFiltered.count
                if n > 0 { let r = min(max(table.selectedRow, -1) + 1, n - 1); table.selectRowIndexes([r], byExtendingSelection: false); table.scrollRowToVisible(r) }
                return nil
            case 126:                                                          // Up
                if self.repoPickerFiltered.count > 0 { let r = max(table.selectedRow - 1, 0); table.selectRowIndexes([r], byExtendingSelection: false); table.scrollRowToVisible(r) }
                return nil
            default: return event
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        container.window?.makeKey()
        container.window?.makeFirstResponder(search)
        if !repoPickerFiltered.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }

        // Click-outside-to-close. The popover is .applicationDefined (it must survive focus changes
        // while you type in the search field), so it won't auto-dismiss — a local mouse monitor does
        // it: any click NOT inside the popover's own window closes the picker (2026-07-11 report).
        repoPickerClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.window !== self.repoPickerPopover?.contentViewController?.view.window {
                self.closeRepoPicker()
            }
            return event
        }
    }

    func closeRepoPicker() {
        if let m = repoPickerClickMonitor { NSEvent.removeMonitor(m); repoPickerClickMonitor = nil }
        repoPickerPopover?.close()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { repoPickerFiltered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: row < repoPickerFiltered.count ? repoPickerFiltered[row].title : "")
        cell.font = NSFont.systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingMiddle
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === repoPickerSearch else { return }
        let q = (repoPickerSearch?.stringValue ?? "").lowercased()
        repoPickerFiltered = q.isEmpty ? repoPickerAll : repoPickerAll.filter { $0.title.lowercased().contains(q) }
        repoPickerTable?.reloadData()
        if !repoPickerFiltered.isEmpty { repoPickerTable?.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc func repoPickerConfirm() {
        guard let table = repoPickerTable, table.selectedRow >= 0, table.selectedRow < repoPickerFiltered.count else { return }
        let path = repoPickerFiltered[table.selectedRow].path
        closeRepoPicker()
        newSessionWorktree(repoPath: path)
    }

    // Detect a repo's default branch: origin/HEAD, else `remote show origin`, else current.
    func detectDefaultBranch(_ repoPath: String) -> String? {
        if let s = runCommand([gitBin, "-C", repoPath, "symbolic-ref", "refs/remotes/origin/HEAD", "--short"]) {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v.hasPrefix("origin/") ? String(v.dropFirst("origin/".count)) : v }
        }
        if let s = runCommand([gitBin, "-C", repoPath, "remote", "show", "origin"]),
           let line = s.split(separator: "\n").first(where: { $0.contains("HEAD branch:") }) {
            let v = line.replacingOccurrences(of: "HEAD branch:", with: "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty, v != "(unknown)" { return v }
        }
        if let s = runCommand([gitBin, "-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"]) {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }

    func newSessionWorktree(repoPath: String) {
        let repoName = (repoPath as NSString).lastPathComponent
        worktreeCreating = true
        sessionError = nil
        rebuild(rows: lastRows)
        DispatchQueue.global(qos: .userInitiated).async {
            func fail(_ msg: String) {
                DispatchQueue.main.async {
                    self.worktreeCreating = false
                    self.sessionError = msg
                    self.rebuild(rows: self.lastRows)
                }
            }
            var user = runCommand([gitBin, "-C", repoPath, "config", "user.name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if user.isEmpty { user = NSUserName() }
            var cleanUser = user.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if cleanUser.isEmpty { cleanUser = "user" }
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyyMMdd-HHmmss"
            let branch = "\(cleanUser)-\(fmt.string(from: Date()))"
            guard let base = self.detectDefaultBranch(repoPath) else {
                fail(L("既定ブランチを検出できません", "couldn't detect the default branch")); return
            }
            // Create the worktree with git itself (P4, 2026-07-10 — this used to be `herdr worktree
            // create` + `herdr pane run`). The base is the default branch: prefer the local ref, and
            // fall back to origin's when this checkout has no local copy of it.
            let path = "\(repoPath)/../\(repoName)-\(base)-\(branch)"
            let localBase = runCommand([gitBin, "-C", repoPath, "rev-parse", "--verify", "--quiet", base]) != nil
            let startPoint = localBase ? base : "origin/\(base)"
            guard runCommand([gitBin, "-C", repoPath, "worktree", "add", path, "-b", branch, startPoint],
                             timeout: 120) != nil else {   // big repos take a while to check out
                fail(L("worktree の作成に失敗しました", "worktree creation failed")); return
            }
            guard let claude = claudeBin else {
                fail(L("claude CLI が見つかりません", "couldn't find the claude CLI")); return
            }
            DispatchQueue.main.async {
                self.worktreeCreating = false
                // The session opens in its own Ghostty window, started in the worktree. Its card
                // appears on the next refresh (the status hook writes the file as it boots).
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.mitchellh.ghostty")
                }
                self.jumpGhostty(command: "\(claude) --dangerously-skip-permissions",
                                 windowKey: "sessionWin." + path, cwd: path)
                self.refresh()
            }
        }
    }

}
