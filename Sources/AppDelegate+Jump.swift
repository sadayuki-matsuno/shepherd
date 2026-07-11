import AppKit
import ApplicationServices

extension AppDelegate {
    // The one way into a session, wherever it lives: a zellij session attaches in its terminal, a
    // cc-daemon background worker opens its TUI with `claude attach`. A session started outside both
    // has no address we can jump to, so the card explains itself (tooltip) instead of erroring.
    // Shared by the card click, the card menu and the Stream Deck keys.
    func openRow(_ row: AgentRow) {
        // A stop/rm in flight: the card is inert, and the Stream Deck keys (which bypass the card's
        // wiring) must not attach to a session that's being torn down.
        guard !deletingSessions.contains(row.sessionId) else { return }
        if row.backend == .zellij, let zs = row.zellijSession {
            jumpToZellij(zs, paneId: row.zellijPaneId)
        } else if row.isBackground {
            attachBackground(row)
        }
    }

    func activateLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        guard let data = ("[\(f.string(from: Date()))] " + s + "\n").data(using: .utf8) else { return }
        let path = "/tmp/shepherd-activate.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // Raise-or-create a Ghostty window running `command`, tracking its window id in defaults
    // under `windowKey` so a later jump to the same target reuses the window instead of opening a
    // duplicate. Any target — a zellij session, a
    // `claude attach`, a new worktree session — gets the same window-tracking behaviour. `cwd` sets
    // the surface's `initial working directory`, which is how a session starts in its worktree
    // without wrapping the command in a shell. Returns the AppleScript result verb
    // ("raised" / "created:<id>" / "").
    @discardableResult
    func jumpGhostty(command: String, windowKey: String, cwd: String? = nil) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let id = defaults.string(forKey: windowKey) ?? "none"
        let cwdLine = cwd.map { "set initial working directory of cfg to \"\(esc($0))\"" } ?? ""
        let script = """
        tell application "Ghostty"
          try
            set w to window id "\(id)"
            activate window w
            focus (focused terminal of selected tab of w)
            return "raised"
          on error
            set cfg to new surface configuration
            set command of cfg to "\(esc(command))"
            \(cwdLine)
            set nw to new window with configuration cfg
            activate window nw
            return "created:" & (id of nw)
          end try
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        let r = result?.stringValue ?? ""
        activateLog("ghostty jump [\(windowKey)] result=\(r) error=\(err?.description ?? "nil")")
        if r.hasPrefix("created:") { defaults.set(String(r.dropFirst("created:".count)), forKey: windowKey) }
        return r
    }

    // Is `name` in `zellij list-sessions`? Both live and EXITED sessions count as attachable:
    // zellij resurrects an EXITED session on attach ("attach to resurrect"), so only a name that's
    // gone from the list entirely (past its resurrection retention) is truly un-attachable.
    // Returns nil if zellij itself can't be run (so the caller can attach optimistically).
    func zellijSessionListed(_ name: String) -> Bool? {
        guard let zellij = zellijBin,
              let out = runCommand([zellij, "list-sessions", "--no-formatting"]) else { return nil }
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            // Lines look like "implacable-cactus [Created 1h ago]" or "… (EXITED - …)".
            if l == name || l.hasPrefix(name + " ") { return true }
        }
        return false
    }

    // Is the zellij session already attached to a client? (Phase E) `zellij action list-clients`
    // prints a header row plus one row per attached client; any non-header row → attached, and we
    // then bring the existing terminal window forward instead of spawning a fresh attach.
    func zellijAttached(_ session: String) -> Bool {
        guard let zellij = zellijBin,
              let out = runCommand([zellij, "action", "list-clients"], extraEnv: ["ZELLIJ_SESSION_NAME": session]) else { return false }
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("CLIENT_ID") { continue }   // skip the header
            return true
        }
        return false
    }

    // Raise the existing Ghostty window showing this zellij session (Phase E). zellij sets each
    // pane's title to "<session> | <OSC title>", so we match a window/tab whose title contains the
    // session name and activate it + select that tab. Returns true if we found and raised one.
    // (Measured 2026-07-07: window/tab name starts with the session; working directory is the
    // shell's, not the pane's, so title match — not cwd — is the reliable key. See v5-phase0-zellij.)
    // The app-level `activate` matters: without it macOS may grant the window RAISE but deny Ghostty
    // becoming the ACTIVE app when the request originates from this never-active accessory app —
    // the pane shows but typing goes elsewhere (2026-07-08 report). Pairs with the
    // yieldActivation(...) the jump does on our side.
    @discardableResult
    func focusGhosttyZellijWindow(_ session: String) -> Bool {
        let esc = session.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
          activate
          repeat with w in windows
            if name of w contains "\(esc)" then
              activate window w
              try
                focus (focused terminal of selected tab of w)
              end try
              return "raised"
            end if
            repeat with t in tabs of w
              if name of t contains "\(esc)" then
                select t
                activate window w
                try
                  focus (focused terminal of t)
                end try
                return "raised"
              end if
            end repeat
          end repeat
          return "notfound"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        let r = result?.stringValue ?? ""
        activateLog("zellij focus-existing [\(session)] result=\(r) error=\(err?.description ?? "nil")")
        return r == "raised"
    }

    // Jump to a zellij session (P3 + Phase E). If it's already attached in a terminal, bring that
    // window forward (don't spawn a second attach). Otherwise raise-or-open a Ghostty window running
    // `zellij attach <name>` (which resurrects an EXITED session), reusing the window we opened for
    // it before. If the session is gone from zellij's list entirely, say so rather than opening a
    // window that immediately fails. With a paneId (hook-recorded ZELLIJ_PANE_ID) the jump also
    // walks the session's focus onto that pane, so a multi-pane session lands on the agent instead
    // of wherever focus happened to be.
    func jumpToZellij(_ session: String, paneId: String? = nil) {
        if replyPopover != nil { closeReply(); return }
        if repoPickerPopover != nil { closeRepoPicker(); return }
        if dropPopover != nil { dropPopover?.close(); return }
        guard terminalApp == "Ghostty", let zellij = zellijBin else {
            flashHint(L("zellij へのジャンプは Ghostty でのみ対応しています", "jumping to zellij needs Ghostty"))
            return
        }
        // Cooperative activation (macOS 14+): we just received the user's click, so hand the
        // activation right to Ghostty. Without this the AppleScript can raise the window but the
        // system may refuse to make Ghostty the active app — the pane shows, typing goes elsewhere.
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.mitchellh.ghostty")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let listed = self.zellijSessionListed(session)   // nil = couldn't check → try anyway
            let attached = self.zellijAttached(session)
            DispatchQueue.main.async {
                guard listed != false else {
                    self.flashHint(L("zellij セッション「\(session)」は見つかりません（削除済み）",
                                     "zellij session “\(session)” is gone — nothing to attach to"))
                    return
                }
                // Already attached → focus the existing terminal window (Phase E). Fall through to a
                // fresh attach only if we can't find that window.
                if attached, self.focusGhosttyZellijWindow(session) {
                    self.focusZellijPaneAsync(session, paneId: paneId)
                    return
                }
                self.jumpGhostty(command: "\(zellij) attach \(session)", windowKey: "zellijWin." + session)
                self.focusZellijPaneAsync(session, paneId: paneId, waitForClient: true)
            }
        }
    }

    // Open a background session's live TUI (2026-07-10): `claude attach <short-id>` — the native way
    // into a cc-daemon worker (the same hidden command `claude agents` uses). Detaching (← to agent
    // view, Ctrl+Z to shell) leaves the worker running, so this never changes the card's lifecycle —
    // stop stays a separate, explicit action.
    //
    // If the worker is ALREADY attached somewhere, go there instead of opening a second attach
    // (findAttachClient reads the client process's env, so an attach living in a zellij pane names
    // its own session + pane). Otherwise raise-or-create our own Ghostty window, tracked per session
    // as "attachWin.<uuid>".
    func attachBackground(_ row: AgentRow) {
        if replyPopover != nil { closeReply(); return }
        guard terminalApp == "Ghostty", let claude = claudeBin else {
            flashHint(L("attach には Ghostty と claude CLI が必要です", "attaching needs Ghostty and the claude CLI"))
            return
        }
        // A live worker attaches immediately. Resuming a FINISHED record spins a real claude
        // process back up — the card stops being a cost-free archive entry — so that path confirms
        // first, on a sheet anchored to the HUD (same style/reasoning as removeAgentRecord).
        guard let id = removableRecord(row) else {
            openAttachWindow(claude: claude, row: row)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("終了済みセッションを再開しますか？", "Resume this finished session?")
        alert.informativeText = L("claude attach \(id) を Ghostty で開きます。再開するとプロセスが起動し、ウィンドウを閉じてもバックグラウンドで動き続けます（止めるには右クリック→停止）。",
                                  "Opens `claude attach \(id)` in Ghostty. Resuming starts a real process again, and it keeps running in the background after you close the window (right-click → stop to end it).")
        alert.addButton(withTitle: L("再開", "Resume"))
        alert.addButton(withTitle: L("キャンセル", "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.openAttachWindow(claude: claude, row: row)
        }
    }

    // Follow an existing attach if there is one, else open our own window. The `ps` probes cost ~10ms
    // and run off the main thread, on the click only — never on a refresh.
    private func openAttachWindow(claude: String, row: AgentRow) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.mitchellh.ghostty")
        }
        let short = shortSessionId(row.sessionId)
        DispatchQueue.global(qos: .userInitiated).async {
            let client = findAttachClient(short: short)
            DispatchQueue.main.async {
                // Attached inside a zellij pane: raise that terminal and walk focus onto the pane,
                // exactly as a zellij row's jump does. Opening a second attach here would leave the
                // user's own session sitting in a window they can no longer find (2026-07-10 report).
                if let c = client, let session = c.zellijSession {
                    self.activateLog("attach follow [\(short)] pid=\(c.pid) zellij=\(session):\(c.zellijPaneId ?? "-")")
                    if self.focusGhosttyZellijWindow(session) {
                        self.focusZellijPaneAsync(session, paneId: c.zellijPaneId)
                        return
                    }
                    // The pane exists but its terminal window doesn't (detached client): fall through
                    // and let jumpGhostty open a window on `zellij attach`, then walk to the pane.
                    if let zellij = zellijBin {
                        self.jumpGhostty(command: "\(zellij) attach \(session)", windowKey: "zellijWin." + session)
                        self.focusZellijPaneAsync(session, paneId: c.zellijPaneId, waitForClient: true)
                        return
                    }
                }
                // Attached in a plain terminal we opened before → raising "attachWin.<uuid>" lands on
                // it. Attached in someone else's plain terminal → we can't find that window; say so
                // rather than silently starting a second attach to the same worker.
                if let c = client, defaults.string(forKey: "attachWin." + row.sessionId) == nil {
                    self.activateLog("attach exists elsewhere [\(short)] pid=\(c.pid), no window to raise")
                    self.flashHint(L("別のターミナルで attach 中です（pid \(c.pid)）— そちらのウィンドウで操作してください",
                                     "already attached in another terminal (pid \(c.pid)) — use that window"))
                    return
                }
                self.jumpGhostty(command: "\(claude) attach \(short)", windowKey: "attachWin." + row.sessionId)
            }
        }
    }

    // Background pane-focus walk after a jump. A fresh attach needs a moment before the client
    // shows up in list-clients, so optionally poll for it (~5s) before walking.
    func focusZellijPaneAsync(_ session: String, paneId: String?, waitForClient: Bool = false) {
        guard let paneId = paneId else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if waitForClient {
                for _ in 0..<10 where zellijFocusedPaneId(session) == nil {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            let ok = zellijFocusPane(session, paneId: paneId)
            self.activateLog("zellij pane focus [\(session):\(paneId)] result=\(ok)")
        }
    }

}
