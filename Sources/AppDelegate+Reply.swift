import AppKit

extension AppDelegate {
    // (cleanPrompt — the heuristic that stripped TUI chrome from herdr screen captures — was
    // retired in P3, 2026-07-10: the preview now reads the question from the transcript's
    // tool_use input, which has no chrome to strip. See blockedPromptFromTranscript.)

    // Popover to preview a blocked agent's prompt and answer it inline. It closes on ✕/Esc
    // or right after a reply is sent; the "waiting for the agent" state then shows on the
    // row card (rebuild is paused while the popover is up so its anchor view survives).
    func showReply(for row: AgentRow, from anchor: NSView) {
        guard row.replyable else { return }
        replyPopover?.close()

        let width: CGFloat = 340
        var rawText = ""       // full visible capture (for "show full text" / copy)
        var cleanedText = ""   // extracted prompt block

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true        // read-only but drag-selectable
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textView.textColor = Cat.text
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = L("読込中…", "loading…")
        scroll.documentView = textView

        let fullToggle = ActionButton(title: L("全文を表示", "show full text"), target: nil, action: nil)
        fullToggle.setButtonType(.switch)
        fullToggle.font = NSFont.systemFont(ofSize: 11)
        fullToggle.target = fullToggle; fullToggle.action = #selector(ActionButton.fire)
        fullToggle.onPress = { [weak textView, weak fullToggle] in
            guard let tv = textView else { return }
            if fullToggle?.state == .on {
                tv.string = rawText.isEmpty ? cleanedText : rawText
                tv.scrollToEndOfDocument(nil)
            } else {
                tv.string = cleanedText
                tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }

        // header: label · copy · close
        let titleLabel = makeLabel(row.label, size: 12, weight: .semibold)
        let copyBtn = ActionButton(title: "", target: nil, action: nil)
        copyBtn.image = symbolImage("doc.on.doc", size: 12)
        copyBtn.imagePosition = .imageOnly
        copyBtn.contentTintColor = Cat.overlay
        copyBtn.onPress = { [weak fullToggle] in
            let text = (fullToggle?.state == .on) ? (rawText.isEmpty ? cleanedText : rawText) : cleanedText
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        copyBtn.target = copyBtn; copyBtn.action = #selector(ActionButton.fire)
        copyBtn.isBordered = false; copyBtn.font = NSFont.systemFont(ofSize: 12)
        copyBtn.toolTip = L("プレビュー全文をコピー", "copy the preview")
        let closeBtn = ActionButton(title: "", target: nil, action: nil)
        closeBtn.image = symbolImage("xmark", size: 12)
        closeBtn.imagePosition = .imageOnly
        closeBtn.onPress = { [weak self] in self?.closeReply() }
        closeBtn.target = closeBtn; closeBtn.action = #selector(ActionButton.fire)
        closeBtn.isBordered = false; closeBtn.font = NSFont.systemFont(ofSize: 12)
        closeBtn.contentTintColor = Cat.overlay
        let headerSpacer = NSView(); headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, headerSpacer, copyBtn, closeBtn])
        header.orientation = .horizontal

        let field = NSTextField()
        field.placeholderString = L("回答を入力（送信で Enter 付き）", "type a reply (sent with Enter)")
        field.translatesAutoresizingMaskIntoConstraints = false

        let approve = ActionButton(title: L("承認 (Enter)", "Approve (Enter)"), target: nil, action: nil)
        approve.bezelStyle = .rounded; approve.target = approve; approve.action = #selector(ActionButton.fire)
        let sendBtn = ActionButton(title: L("送信", "Send"), target: nil, action: nil)
        sendBtn.bezelStyle = .rounded; sendBtn.target = sendBtn; sendBtn.action = #selector(ActionButton.fire)
        sendBtn.keyEquivalent = "\r"
        approve.onPress = { [weak self] in self?.sendReplyToRow(row, text: nil) }
        sendBtn.onPress = { [weak self, weak field] in self?.sendReplyToRow(row, text: field?.stringValue) }
        // A background worker has no TUI, so there is no "press Enter on the highlighted option" to
        // approve — the socket reply carries text only. Typing the answer is the one path.
        approve.isHidden = row.isBackground
        let buttons = NSStackView(views: [approve, NSView(), sendBtn])
        buttons.orientation = .horizontal; buttons.distribution = .fill

        let vstack = NSStackView(views: [header, scroll, fullToggle, field, buttons])
        vstack.orientation = .vertical
        vstack.spacing = 8
        vstack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        vstack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 250))
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
        pop.behavior = .applicationDefined   // we control closing; don't dismiss on focus loss
        pop.delegate = self
        pop.contentSize = NSSize(width: width, height: 250)
        replyPopover = pop

        // Esc closes it; ⌘C copies the selection (or the whole preview). An accessory app
        // with no Edit menu doesn't route ⌘C to copy: on its own, so we handle it here.
        replyEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak textView, weak fullToggle] event in
            if event.keyCode == 53 { self?.closeReply(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
                let sel = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
                let toCopy: String
                if let tv = textView, sel.length > 0 { toCopy = (tv.string as NSString).substring(with: sel) }
                else { toCopy = (fullToggle?.state == .on && !rawText.isEmpty) ? rawText : cleanedText }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(toCopy, forType: .string)
                return nil
            }
            return event
        }

        // An accessory / nonactivating app must activate to accept keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        panel.makeKey()
        container.window?.makeKey()
        container.window?.makeFirstResponder(field)

        DispatchQueue.global(qos: .userInitiated).async {
            // The question comes straight from the transcript: a pending AskUserQuestion /
            // ExitPlanMode tool_use input carries it verbatim (P3 — no screen to scrape since the
            // herdr read went away).
            //
            // A BACKGROUND worker is the exception: it doesn't flush the blocking assistant record
            // until the turn completes, so while it waits its transcript ends at the user prompt
            // and holds no question at all (measured 2026-07-10). The daemon's `needs` is the only
            // live account of what it's asking — and it always has one, since that's what marks the
            // worker blocked in the first place.
            let needs = row.needs?.trimmingCharacters(in: .whitespacesAndNewlines)
            let question = blockedPromptFromTranscript(cwd: row.cwd, sessionId: row.sessionId)
                ?? (needs?.isEmpty == false ? needs : nil)
            let last = lastAssistantTextFromTranscript(cwd: row.cwd, sessionId: row.sessionId)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = question ?? last
                ?? L("（読み取れませんでした。ジャンプして確認してください）", "(couldn't read the prompt — click the row to jump)")
            DispatchQueue.main.async {
                rawText = last ?? ""
                cleanedText = cleaned
                textView.string = cleaned
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))   // question is at the top
            }
        }
    }

    // Send the reply: a background worker takes it over the daemon socket's authed `reply` op;
    // anything else goes down the zellij route (deliverText: focus pane → write-chars → Enter →
    // focus back). The card shows a session-keyed "waiting" state until the agent unblocks —
    // repainted NOW so it doesn't lag until the next refresh.
    func sendReplyToRow(_ row: AgentRow, text: String?) {
        let text = text ?? ""
        if row.isBackground, text.isEmpty {
            flashHint(L("回答を入力してください（バックグラウンドにはテキストのみ送れます）",
                        "type an answer — a background worker only takes text"))
            return
        }
        replyWaitingSession = row.sessionId
        replyWaitingSince = Date()
        replyWaitingTimedOut = false
        if let m = replyEscMonitor { NSEvent.removeMonitor(m); replyEscMonitor = nil }
        replyPopover?.close()
        replyPopover = nil
        rebuild(rows: lastRows)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = row.isBackground
                ? daemonReply(short: shortSessionId(row.sessionId), text: text)
                : self.deliverText(text, to: row)
            DispatchQueue.main.async {
                if !ok {
                    if row.isBackground {
                        self.flashHint(L("送信できませんでした（daemon に届きません）— attach で直接回答してください",
                                         "couldn't reach the daemon — attach and answer there"))
                    } else {
                        self.zellijBlockedHint()
                    }
                }
                self.refresh()
            }
        }
    }

    func closeReply() { replyPopover?.close() }

    func popoverDidClose(_ notification: Notification) {
        let pop = notification.object as? NSPopover
        if pop === replyPopover {
            if let m = replyEscMonitor { NSEvent.removeMonitor(m); replyEscMonitor = nil }
            replyPopover = nil
        } else if pop === repoPickerPopover {
            if let m = repoPickerEscMonitor { NSEvent.removeMonitor(m); repoPickerEscMonitor = nil }
            if let m = repoPickerClickMonitor { NSEvent.removeMonitor(m); repoPickerClickMonitor = nil }
            repoPickerPopover = nil
        } else if pop === dropPopover {
            if let m = dropEscMonitor { NSEvent.removeMonitor(m); dropEscMonitor = nil }
            dropPopover = nil
        } else if pop === helpPopover {
            if let m = helpEscMonitor { NSEvent.removeMonitor(m); helpEscMonitor = nil }
            if let m = helpClickMonitor { NSEvent.removeMonitor(m); helpClickMonitor = nil }
            helpPopover = nil
        }
    }

    // While a reply is pending, drive the row card's "waiting" state: clear it once the
    // agent unblocks, or flag it as timed-out after 30s so the user can resend.
    func updateReplyWaiting(rows: [AgentRow]?) {
        guard let session = replyWaitingSession, let since = replyWaitingSince else { return }
        let stillBlocked = rows?.first { $0.sessionId == session }?.status == "blocked"
        if !stillBlocked {
            replyWaitingSession = nil; replyWaitingSince = nil; replyWaitingTimedOut = false
        } else if !replyWaitingTimedOut && Date().timeIntervalSince(since) > 30 {
            replyWaitingTimedOut = true
        }
    }


}
