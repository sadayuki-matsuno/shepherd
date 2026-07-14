import AppKit

// ？ヘルプ: HUD 上の記号・色・操作の凡例ポップオーバー。stale? や 📎 のような
// 一見しただけでは意味の取れない表示の説明を1か所に集める（2026-07-08 要望）。
// 他のポップオーバーと同じ流儀: behavior = .applicationDefined、表示前に NSApp.activate、
// 表示中は rebuild をスキップ（AppDelegate+Lifecycle のガード）、Esc / ✕ / 再クリックで閉じる。
extension AppDelegate {

    @objc func showHelp(_ sender: NSButton) {
        if helpPopover != nil { closeHelp(); return }

        let width: CGFloat = 420
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 10, right: 12)
        body.translatesAutoresizingMaskIntoConstraints = false

        // 見出し行 + 凡例行のファクトリ。glyph 列は幅固定で説明を揃える。
        func section(_ title: String) {
            let l = makeLabel(title, size: 10.5, weight: .heavy, color: Cat.subtext)
            let wrap = NSStackView(views: [l])
            wrap.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 1, right: 0)
            body.addArrangedSubview(wrap)
        }
        func row(_ glyph: String, color: NSColor = Cat.text, _ desc: String, symbol: String? = nil,
                 symbols: [String] = []) {
            let h = NSStackView()
            h.orientation = .horizontal
            h.alignment = .top
            h.spacing = 8
            let g: NSView
            if !symbols.isEmpty {
                // Several sibling icons in one glyph cell (e.g. the header's control buttons).
                let icons = NSStackView()
                icons.orientation = .horizontal
                icons.spacing = 6
                for name in symbols {
                    if let img = symbolImage(name, size: 11, color: color) {
                        icons.addArrangedSubview(NSImageView(image: img))
                    }
                }
                g = icons
            } else if let name = symbol, !glyph.isEmpty {
                g = symbolLabel(name, glyph, size: 11, weight: .semibold, color: color, mono: true)
            } else if let name = symbol,
               let img = NSImage(systemSymbolName: name, accessibilityDescription: desc)?
                   .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) {
                let iv = NSImageView(image: img)
                iv.contentTintColor = color
                g = iv
            } else {
                let l = makeLabel(glyph, size: 11, weight: .semibold, color: color)
                l.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
                l.lineBreakMode = .byClipping
                g = l
            }
            g.translatesAutoresizingMaskIntoConstraints = false
            g.widthAnchor.constraint(equalToConstant: 108).isActive = true
            let d = makeLabel(desc, size: 11, color: Cat.text)
            d.maximumNumberOfLines = 0
            d.lineBreakMode = .byWordWrapping
            d.cell?.wraps = true
            d.preferredMaxLayoutWidth = width - 108 - 8 - 24
            h.addArrangedSubview(g)
            h.addArrangedSubview(d)
            body.addArrangedSubview(h)
        }

        section(L("ステータス（カード左端の色）", "STATUS (card edge color)"))
        row("● " + L("応答待ち", "needs input"), color: Cat.peach,
            L("質問・許可を待って停止中。右クリック→「回答する」でここから返信できる", "waiting on a question / permission. Right-click → Reply to answer from here"))
        row("● " + L("エラー", "error"), color: Cat.red,
            L("異常終了など、対応が必要", "something failed — needs attention"))
        row("● " + L("作業中", "working"), color: Cat.green,
            L("Claude が作業している", "Claude is actively working"))
        row("● " + L("待機", "idle"), color: Cat.overlay,
            L("何もしていない", "nothing running"))

        section(L("カードの記号", "CARD SYMBOLS"))
        row("#123", color: Cat.subtext, L("対応中の GitHub issue 番号", "the GitHub issue being worked on"))
        row("", color: Cat.overlay,
            L("遠隔操作（/remote-control）が有効", "remote-control is enabled for this pane"),
            symbol: "antenna.radiowaves.left.and.right")
        row(L("段数バー + FABLE", "tier bars + FABLE"), color: Cat.mauve,
            L("使用中のモデル。バーの本数が能力段位（1=HAIKU〜4=FABLE）— 盤面一望で重いモデルが分かる", "the model in use; filled bars = capability tier (1 = HAIKU … 4 = FABLE) — heavy models read at a glance"))
        row(L("→ 吹き出し + OPUS", "→ bubble + OPUS"), color: Cat.blue,
            L("アドバイザー（--advisor）: 要所だけ自動相談される相談役モデル", "the advisor (--advisor): the model this session consults at key decisions"),
            symbol: "bubble.left")
        row("", color: Cat.overlay,
            L("タイトル先頭の実行環境: 分割ペイン=zellij / </>=エディタ / 窓付き端末 / 素のプロンプト=headless。色が権限モード（紫=PLAN 緑=EDITS 琥珀=NO-ASK 赤=BYPASS 灰=毎回確認）。ホバーで詳細", "the leading where-it-runs glyph: split panes = zellij, </> = editor, terminal window, bare prompt = headless. Its TINT is the permission mode (lavender = PLAN, green = EDITS, amber = NO-ASK, red = BYPASS, grey = ask). Hover for details"),
            symbols: ["square.split.2x1", "chevron.left.forwardslash.chevron.right", "apple.terminal", "terminal"])
        row("±8", color: Cat.overlay, L("未コミットの変更ファイル数", "uncommitted changed-file count"))
        row("◥", color: Cat.amber,
            L("カード右上の折り目 = 未コミットの変更あり", "top-right dog-ear = the worktree has uncommitted changes"))
        row("stale?", color: Cat.peach,
            L("「作業中」表示のまま2分以上動きがない。Esc 中断などで実際は止まっている可能性（transcript が動いていれば出ない）", "looks busy but nothing happened for 2+ min — likely interrupted (Esc) and actually stopped. Suppressed while the transcript is still advancing"),
            symbol: "clock")
        row(L("送信済み", "sent"), color: Cat.green,
            L("ドロップしたファイルをこのセッションへ送った直後の印", "a dropped file was just sent to this session"),
            symbol: "paperclip")
        row(L("子作業中", "child working"), color: Cat.green,
            L("サブエージェント/子セッションが稼働中（サブエージェントのカード名にも同じ印）", "a subagent / child session is working (its own card carries the same mark)"),
            symbol: "sparkles")
        row("◔ 72%", color: Cat.yellow,
            L("コンテキスト使用率（60%で黄・85%で赤）。ホバーで残りトークン数", "context-window usage (yellow ≥60%, red ≥85%). Hover for tokens left"))
        row("", color: Cat.overlay,
            L("右クリックメニューの場所情報: worktree ／ 通常ディレクトリ ／ ブランチ", "the context menu's location rows: linked worktree / plain directory / branch"),
            symbols: ["arrow.triangle.branch", "folder", "arrow.branch"])

        section(L("成果物", "DELIVERABLES"))
        row(L("…（他+2）", "… (+2)"), color: Cat.blue,
            L("Claude が公開した Artifact。1件ならクリックで開く。2件以上は最新タイトル＋件数になり、クリックで一覧から選択", "Artifacts Claude published. A sole one opens on click; 2+ collapse to the newest title + count — click to pick from the list"),
            symbol: "doc.text")
        row(L("PR は右クリック", "PR: right-click"), color: Cat.teal,
            L("PR はカード面には出ません — 右クリックメニューの「✓/✗/● PR #N を開く」から（記号は CI 結果）", "the PR left the card face — open it from the right-click menu (\"✓/✗/● Open PR #N\"; the mark is the CI outcome)"),
            symbol: "checkmark")

        section(L("親子セッション", "PARENT & CHILDREN"))
        row(L("子 2 件", "2 children"), color: Cat.subtext,
            L("カード下端のストリップ。クリックで子カードを開閉、折りたたみ中はホバーで子の一覧を覗き見", "the strip along the card bottom. Click to fold/unfold child cards; hover while folded to peek"),
            symbol: "chevron.right")

        section(L("操作", "ACTIONS"))
        row(L("クリック", "click"), color: Cat.subtext,
            L("その端末ペイン（Ghostty / zellij）へジャンプ", "jump to the session's terminal pane (Ghostty / zellij)"))
        row(L("右クリック", "right-click"), color: Cat.subtext,
            L("回答・遠隔操作・範囲を撮影して送る・セッションを閉じる 等のメニュー", "menu: reply, remote-control, capture & send a screenshot, close the session, …"))
        row(L("ファイルをD&D", "drop a file"), color: Cat.subtext,
            L("カードにドロップするとそのセッションへファイルパスを送信", "drop onto a card to send the file path to that session"))

        section(L("ヘッダー", "HEADER"))
        row("● " + L("24時間以内", "24h"), color: Cat.green,
            L("表示範囲の切替（24時間以内 ／ すべて表示）", "toggle the board range (last 24h / everything)"))
        row("", color: Cat.overlay,
            L("最小化 ／ 新規セッション作成（worktree + claude 起動）／ 設定メニュー", "minimize / start a new session (worktree + claude) / settings menu"),
            symbols: ["rectangle.compress.vertical", "plus", "gearshape.fill"])

        // フッター: GitHub リンク
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        let sepWrap = NSStackView(views: [sep])
        sepWrap.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        body.addArrangedSubview(sepWrap)
        sep.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        let gh = badge("GitHub: sadayuki-matsuno/shepherd ↗", fg: Cat.blue, bg: Cat.blue.withAlphaComponent(0.14),
                       tip: shepherdRepoURL) {
            if let u = URL(string: shepherdRepoURL) { NSWorkspace.shared.open(u) }
        }
        body.addArrangedSubview(gh)

        // タイトルバー（タイトル + ✕）とスクロール本体
        let titleBar = NSStackView()
        titleBar.orientation = .horizontal
        titleBar.spacing = 6
        titleBar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 0, right: 10)
        let title = makeLabel(L("アイコンと表示の説明", "What the icons mean"), size: 12, weight: .heavy, color: Cat.text)
        let barSpacer = NSView()
        barSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let closeBtn = NSButton(title: "", target: self, action: #selector(closeHelpButton))
        closeBtn.image = symbolImage("xmark", size: 12, weight: .bold)
        closeBtn.imagePosition = .imageOnly
        closeBtn.isBordered = false
        closeBtn.contentTintColor = Cat.overlay
        titleBar.addArrangedSubview(title)
        titleBar.addArrangedSubview(barSpacer)
        titleBar.addArrangedSubview(closeBtn)

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: doc.topAnchor),
            body.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.widthAnchor.constraint(equalToConstant: width),
        ])
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 460).isActive = true
        // NSScrollView は原点が左下なので、開いた直後に先頭（最上部）へスクロールしておく。
        DispatchQueue.main.async {
            if let dv = scroll.documentView {
                dv.scroll(NSPoint(x: 0, y: dv.bounds.height))
            }
        }

        let vstack = NSStackView(views: [titleBar, scroll])
        vstack.orientation = .vertical
        vstack.spacing = 6
        vstack.translatesAutoresizingMaskIntoConstraints = false
        titleBar.widthAnchor.constraint(equalToConstant: width).isActive = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
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
        pop.contentSize = NSSize(width: width, height: 500)
        helpPopover = pop

        helpEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeHelp(); return nil }   // Esc
            return event
        }
        // Click-outside-to-close, same pattern as the repo picker (2026-07-11 report). Clicks on
        // the ? button itself pass through — showHelp's own toggle closes then; closing here too
        // would make the button action immediately reopen it.
        helpClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak sender] event in
            guard let self = self else { return event }
            if event.window !== self.helpPopover?.contentViewController?.view.window {
                if let sender = sender, event.window === sender.window,
                   sender.bounds.contains(sender.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                self.closeHelp()
            }
            return event
        }

        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc func closeHelpButton() { closeHelp() }

    func closeHelp() { helpPopover?.close() }

    @objc func openShepherdRepo() {
        if let u = URL(string: shepherdRepoURL) { NSWorkspace.shared.open(u) }
    }
}

let shepherdRepoURL = "https://github.com/sadayuki-matsuno/shepherd"
let shepherdDocsURL = "https://sadayuki-matsuno.github.io/shepherd/"
