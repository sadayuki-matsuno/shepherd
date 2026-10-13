import AppKit

// メニューバー常駐アイコン（NSStatusItem）。常に出しておき、クリックで HUD の表示/非表示を
// トグルする（位置・サイズは orderOut / orderFrontRegardless なので保持される）。バッジは
// attentionCount（Models.swift・テスト済み）＝ローカルの blocked ＋ routine の承認待ち。
// 件数の更新は canRebuildNow() と無関係に呼ぶ — ポップオーバー表示中でも、HUD を隠していても
// メニューバーの数字は止めない（refresh 完了・routines 取得完了・rebuild のそれぞれから）。
// 非表示状態は永続化しない（起動時は常に HUD を出す）。
//
// ホバーパネル: アイコンにカーソルを載せると、直下に最小化ストリップと同じ中身（compact
// ダッシュボード＋ステータス行）を出す。NSPopover＋NSApp.activate は使わない — ホバーだけで
// 他アプリのキーボードフォーカスを奪うため。HUD 本体と同じ borderless・nonactivatingPanel で、
// key にはならない。閉じる判定は enter/exit の順序に頼らず（新ビュー enter → 旧ビュー exit の順で
// 来ることがある・地雷リスト）、exit の数百ms後にカーソル位置をアイコン/パネルの矩形で調べる。
extension AppDelegate {

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // button.action で直接トグルする（statusItem.menu を付けるとクリックがメニューに取られる）。
        item.button?.target = self
        item.button?.action = #selector(toggleHUDVisible)
        // ボタンに透明ビューを重ねるとクリックを奪うので、tracking area だけ足して owner を HoverView にする。
        let tracker = HoverView()
        tracker.onHover = { [weak self] inside in
            if inside { self?.showStatusHover() } else { self?.scheduleStatusHoverClose() }
        }
        item.button?.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                    owner: tracker))
        statusHoverTracker = tracker
        statusItem = item
        updateStatusItem()
    }

    // メニューバー側の面（バッジ・ホバーパネル）の更新口。refresh / routines / usage の完了と rebuild から呼ぶ。
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        if statusHoverPanel != nil { fillStatusHover() }
        // ヘッダーの「応答待ち」ピルと同じ 24h フィルタ後の rows で数える（盤面と数字を揃える）。
        let count = attentionCount(rows: applyFilter(lastRows ?? []), routines: displayedRoutines)
        guard count != statusItemCount else { return }
        statusItemCount = count
        let mark = (markIcon?.copy() as? NSImage) ?? NSImage()
        let markRect = NSRect(x: 0, y: 1, width: 16, height: 16)
        if count == 0 {
            // 平常時はテンプレート画像＝ライト/ダークは AppKit 任せ。
            mark.size = markRect.size
            mark.isTemplate = true
            mark.accessibilityDescription = "Shepherd"
            button.image = mark
            button.toolTip = "Shepherd"
            return
        }
        // 要注意: マーク（labelColor）＋桃のカプセル＋暗色の数字。drawingHandler は描画時に解決
        // されるので、labelColor はメニューバーのその時の外観（壁紙で明暗が変わる）に追従する。
        // カプセルは自前の地を持つので、数字（Cat.crust）の読みやすさは明暗どちらでも変わらない。
        let text = NSAttributedString(string: count > 99 ? "99+" : "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: Cat.crust,
        ])
        let textSize = text.size()
        let capsule = NSRect(x: markRect.maxX + 3, y: 2, width: max(14, ceil(textSize.width) + 8), height: 14)
        let image = NSImage(size: NSSize(width: capsule.maxX, height: 18), flipped: false) { _ in
            // マークの着色は透明レイヤーの中で sourceAtop — 外で行うとボタンの下地ごと塗ってしまう。
            if let cg = NSGraphicsContext.current?.cgContext {
                cg.beginTransparencyLayer(in: markRect, auxiliaryInfo: nil)
                mark.draw(in: markRect)
                NSColor.labelColor.setFill()
                markRect.fill(using: .sourceAtop)
                cg.endTransparencyLayer()
            }
            Cat.peach.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
            text.draw(at: NSPoint(x: capsule.midX - textSize.width / 2, y: capsule.midY - textSize.height / 2))
            return true
        }
        image.accessibilityDescription = L("Shepherd — 要対応 \(count) 件", "Shepherd — \(count) need you")
        button.image = image
        button.toolTip = image.accessibilityDescription
    }

    // アイコンがノッチの裏に溢れる・メニューバーの表示許可で消される等で見えないときの逃げ道:
    // Finder / Spotlight / `open -a Shepherd` で起動し直すと（既に動いていれば reopen が来て）HUD を戻す。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isVisible && !regionCaptureActive { showHUD() }
        return false
    }

    @objc func toggleHUDVisible() {
        closeStatusHover()
        // 範囲撮影中の非表示はユーザーの「隠す」ではない — ここで戻すと HUD が撮影に写り込む。
        guard !regionCaptureActive else { return }
        if panel.isVisible { hideHUD() } else { showHUD() }
    }

    func hideHUD() {
        // ポップオーバーは全部閉じてから隠す。開いたままだと canRebuildNow() が false に固定され、
        // 隠れた盤面が（閉じる手段の無いまま）更新されなくなる。
        closeReply()
        closeRepoPicker()
        dropPopover?.close()
        closeHelp()
        hideHoverTip()
        familyPeekPopover?.close()
        familyPeekPopover = nil
        panel.orderOut(nil)
    }

    func showHUD() {
        closeStatusHover()   // ホバーパネルのチップ（承認待ち等）から HUD を開いたときに残さない
        // 隠れている間は canRebuildNow() が組み直しを止めているので、戻す瞬間に最新で組んでから前面化する。
        rebuild(rows: lastRows)
        panel.orderFrontRegardless()
    }

    // ブランドバーの最小化ボタン。メニューバーモードでは HUD を隠し、ストリップモード（または
    // 旧版から持ち越した最小化状態）では従来どおり最小化をトグルする。
    @objc func minimizeButtonPressed() {
        if minimizeButtonHidesHUD(minimized: minimized, action: minimizeAction) { hideHUD() } else { toggleMinimized() }
    }

    @objc func setMinimizeAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = MinimizeAction(rawValue: raw), action != minimizeAction else { return }
        minimizeAction = action
        defaults.set(action.rawValue, forKey: "minimizeAction")
        rebuild(rows: lastRows)   // ボタンのアイコンとツールチップが変わる
    }

    // MARK: - ホバーパネル

    func showStatusHover() {
        statusHoverCloseWork?.cancel()
        // HUD が出ているなら同じ情報は盤面にある — ホバーパネルは HUD を隠しているときだけ。
        // （出ている最中に HUD が戻った場合は showHUD が閉じる。）
        if statusHoverPanel != nil || panel.isVisible || regionCaptureActive { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu   // HUD（.floating）より上
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.appearance = NSAppearance(named: .darkAqua)
        // 背景・枠は HUD 本体と同じ。ルートは HoverView で、パネル上の滞在も追う（子のチップへ移っても
        // exit は来ない）。ルートは表示中ずっと同じものを使い、refresh では中身だけ差し替える —
        // カーソルの下でルートごと作り直すと、新ルートには enter も exit も確実には来ず、閉じる契機を失う。
        let root = HoverView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Cat.base.withAlphaComponent(0.97).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Cat.surface.cgColor
        root.onHover = { [weak self] inside in
            if inside { self?.statusHoverCloseWork?.cancel() } else { self?.scheduleStatusHoverClose() }
        }
        p.contentView = root
        statusHoverPanel = p
        fillStatusHover()
        p.orderFrontRegardless()
    }

    // 中身は最小化ストリップと同じ部品（compact ダッシュボード＋ headerView の strip 版ステータス行）。
    // 表示中は updateStatusItem から組み直して最新に保つ。
    func fillStatusHover() {
        guard let p = statusHoverPanel, let root = p.contentView, let anchor = statusItem?.button?.window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        if showUsageDashboard { stack.addArrangedSubview(usageDashboardView(width: contentWidth - 24, compact: true)) }
        if let status = headerView(rows: lastRows.map(applyFilter), asStrip: true).status {
            stack.addArrangedSubview(status)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: contentWidth, height: stack.fittingSize.height)
        root.subviews.forEach { $0.removeFromSuperview() }
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        ])
        // アイコン直下に中央揃えで置き、載っている画面の右端（と左端）でクランプする。
        let icon = anchor.frame
        let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? icon
        let x = min(max(icon.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        p.setFrame(NSRect(x: x, y: icon.minY - statusHoverGap - size.height, width: size.width, height: size.height), display: true)
        // 組み直しでパネルが縮む・動くと、静止したカーソルの下からパネルが抜けても exit は来ない。
        // 位置での判定を一度走らせておく（カーソルがアイコン/パネルに居れば何もしない）。
        scheduleStatusHoverClose()
    }

    // exit のたびに少し待ってから、カーソルがアイコンにもパネル（とアイコンとの隙間）にも居なければ閉じる。
    // 位置で判定するので、enter/exit の到着順や、組み直しで消えた旧ビューの遅れた exit に左右されない。
    func scheduleStatusHoverClose() {
        statusHoverCloseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let p = self.statusHoverPanel else { return }
            let mouse = NSEvent.mouseLocation
            let icon = self.statusItem?.button?.window?.frame ?? .zero
            let pf = p.frame
            let panelArea = NSRect(x: pf.minX, y: pf.minY, width: pf.width, height: pf.height + statusHoverGap + 1)
            if !icon.contains(mouse) && !panelArea.contains(mouse) { self.closeStatusHover() }
        }
        statusHoverCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func closeStatusHover() {
        statusHoverCloseWork?.cancel()
        guard let p = statusHoverPanel else { return }
        statusHoverPanel = nil
        p.orderOut(nil)
        // パネル上のチップのクリック（revealRoutines → showHUD → ここ）は、まだそのパネルの
        // sendEvent の中にいる。唯一の強参照をここで落とすと解放済みのビューにイベントが戻るので、
        // 現在のイベント処理が終わるまで生かしておく。
        DispatchQueue.main.async { _ = p }
    }

}

private let statusHoverGap: CGFloat = 4   // アイコン下端とパネル上端の隙間

