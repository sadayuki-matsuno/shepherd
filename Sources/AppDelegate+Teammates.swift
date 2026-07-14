import AppKit

// Actions on idle roster teammates (2026-07-14). Both write the team's inbox files — the same
// queue the harness drains — so they work from an outside process with no socket and no pid:
//   • message → inboxes/<teammate>.json as "team-lead" (the sender proven to deliver end-to-end;
//     an idle teammate resumes on delivery, so this doubles as "re-activate").
//   • cleanup → inboxes/team-lead.json as "shepherd", asking the LEAD to send the teammate a
//     shutdown_request. Shutdown must originate from the lead (only it holds the request/approve
//     handshake), and routing it as a request keeps the lead a deliberate gate rather than
//     Shepherd terminating agents behind its back.
// Serial: two quick actions on the same inbox must not interleave their read-append-write.
let teamInboxQueue = DispatchQueue(label: "shepherd.team-inbox", qos: .userInitiated)

extension AppDelegate {
    // Compact reply-style popover: one field, one send. Stored in replyPopover so the refresh
    // guard (no rebuild while a popover is up), Esc handling and popoverDidClose cleanup all
    // apply unchanged.
    func showTeammateMessage(row: AgentRow, teammate: String, from anchor: NSView) {
        replyPopover?.close()
        let width: CGFloat = 340

        let titleLabel = symbolLabel("moon.zzz", teammate, size: 12, weight: .semibold,
                                     color: Cat.text, symbolColor: Cat.overlay)
        let closeBtn = ActionButton(title: "", target: nil, action: nil)
        closeBtn.image = symbolImage("xmark", size: 12)
        closeBtn.imagePosition = .imageOnly
        closeBtn.onPress = { [weak self] in self?.closeReply() }
        closeBtn.target = closeBtn; closeBtn.action = #selector(ActionButton.fire)
        closeBtn.isBordered = false
        closeBtn.contentTintColor = Cat.overlay
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, spacer, closeBtn])
        header.orientation = .horizontal

        let caption = makeLabel(L("team-lead 名義で inbox に投函します — 待機中の teammate はこのメッセージで再開します",
                                  "posted to its inbox as team-lead — an idle teammate resumes on delivery"),
                                size: 10.5, color: Cat.subtext)
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 2

        let field = NSTextField()
        field.placeholderString = L("指示を入力", "type an instruction")
        field.translatesAutoresizingMaskIntoConstraints = false
        let sendBtn = ActionButton(title: L("送信", "Send"), target: nil, action: nil)
        sendBtn.bezelStyle = .rounded; sendBtn.target = sendBtn; sendBtn.action = #selector(ActionButton.fire)
        sendBtn.keyEquivalent = "\r"
        sendBtn.onPress = { [weak self, weak field] in
            guard let text = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                self?.flashHint(L("指示を入力してください", "type an instruction first"))
                return
            }
            self?.sendToTeammate(row: row, teammate: teammate, text: text)
        }
        let buttons = NSStackView(views: [NSView(), sendBtn])
        buttons.orientation = .horizontal; buttons.distribution = .fill

        let vstack = NSStackView(views: [header, caption, field, buttons])
        vstack.orientation = .vertical
        vstack.spacing = 8
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

        let vc = NSViewController()
        vc.view = container
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .applicationDefined
        pop.delegate = self
        pop.contentSize = NSSize(width: width, height: 130)
        replyPopover = pop

        replyEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeReply(); return nil }
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        panel.makeKey()
        container.window?.makeKey()
        container.window?.makeFirstResponder(field)
    }

    func sendToTeammate(row: AgentRow, teammate: String, text: String) {
        closeReply()
        teamInboxQueue.async {
            let ok = injectTeammateMessage(leadSessionId: row.sessionId, to: teammate, text: text)
            DispatchQueue.main.async {
                self.flashHint(ok
                    ? L("\(teammate) の inbox に投函しました（配達で再開します）",
                        "posted to \(teammate)'s inbox — it resumes on delivery")
                    : L("投函できませんでした（team の inbox に書けません）",
                        "couldn't write to the team inbox"))
                self.refresh()
            }
        }
    }

    func cleanupTeammate(row: AgentRow, teammate: String) {
        teamInboxQueue.async {
            let text = L("Shepherd からユーザーの操作です: teammate「\(teammate)」は役目を終えたので片付けてください。SendMessage で shutdown_request を \(teammate) に送り、終了したことを確認してください。",
                         "User action via the Shepherd HUD: teammate \"\(teammate)\" is no longer needed. Please send it a shutdown_request via SendMessage and confirm it terminated.")
            let ok = injectTeammateMessage(leadSessionId: row.sessionId, to: "team-lead",
                                           text: text, from: "shepherd")
            DispatchQueue.main.async {
                self.flashHint(ok
                    ? L("lead に \(teammate) の片付けを依頼しました（lead が shutdown を送ります）",
                        "asked the lead to shut \(teammate) down")
                    : L("依頼を送れませんでした（team の inbox に書けません）",
                        "couldn't write to the team inbox"))
            }
        }
    }
}
