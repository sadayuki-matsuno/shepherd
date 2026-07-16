import Foundation
#if canImport(Glibc)
import Glibc   // kill / SIGKILL (Darwin re-exports these through Foundation; Glibc does not)
#endif

// MARK: - Subprocess helpers

// corelibs-foundation's blocking Process.waitUntilExit() never returns on Linux (observed
// 2026-07-16 in the swift:noble 6.3.3 container — terminationHandler fires and isRunning
// flips, only the blocking wait hangs). Upstream: swiftlang/swift#79881 — a Swift 6.x
// regression reported on arm64-in-Docker; polling is safe everywhere, so use it on all
// of Linux rather than trusting the wait on untested arch/kernel combos.
// Poll there; Darwin keeps the real wait.
func waitExit(_ p: Process) {
    #if canImport(Darwin)
    p.waitUntilExit()
    #else
    while p.isRunning { usleep(5_000) }
    #endif
}

func runCommand(_ args: [String], cwd: String? = nil, ignoreExit: Bool = false, extraEnv: [String: String] = [:],
                timeout: TimeInterval = 10) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    // Strip HERDR_* from the child env: when Shepherd is launched from inside a herdr pane those
    // vars propagate into every process we spawn, and a nested herdr self-terminates. Harmless to
    // keep now that Shepherd never runs herdr itself. (Verified: herdr CLI
    // subcommands still work with all HERDR_* removed — they fall back to the default socket.)
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") }
    env["GH_PROMPT_DISABLED"] = "1"
    env["GH_NO_UPDATE_NOTIFIER"] = "1"
    for (k, v) in extraEnv { env[k] = v }   // e.g. ZELLIJ_SESSION_NAME to target a specific session
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    // Read on a helper thread so a child that never exits (a network-hung gh, say)
    // can't freeze the whole refresh pipeline. The semaphore orders the data handoff. Callers
    // whose children are legitimately slow (interactive screencapture, worktree create) pass a
    // larger timeout.
    let sem = DispatchSemaphore(value: 0)
    var data = Data()
    let fh = out.fileHandleForReading
    DispatchQueue.global(qos: .utility).async {
        data = fh.readDataToEndOfFile()
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        if sem.wait(timeout: .now() + 1) == .timedOut {   // SIGTERM ignored → force it
            kill(p.processIdentifier, SIGKILL)
            _ = sem.wait(timeout: .now() + 1)
        }
        return nil
    }
    waitExit(p)
    // `gh pr checks` exits non-zero when checks fail/pend but still prints JSON to stdout,
    // so callers that want that output pass ignoreExit.
    guard ignoreExit || p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

func runJSON(_ args: [String], timeout: TimeInterval = 10) -> [String: Any]? {
    guard let s = runCommand(args, timeout: timeout), let d = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

// Claude Code's own session registry: every interactive session and every cc-daemon background agent
// (including finished records, hence --all), whether or not our status hook ever fired for it. Cached
// 5s — a refresh burst must not stack the ~0.27s subprocess. nil = the registry is unavailable (no
// claude binary, non-zero exit, unparseable output), and the board degrades to hook + socket data:
// `claude agents` is never a required dependency (§6.2).
func claudeAgentsList() -> [ClaudeAgentEntry]? {
    guard let claudeBin = claudeBin else { return nil }
    factsLock.lock()
    let cached = claudeAgentsCache
    factsLock.unlock()
    if let c = cached, Date().timeIntervalSince(c.at) < 5 { return c.entries }
    guard let out = runCommand([claudeBin, "agents", "--json", "--all"]),
          let data = out.data(using: .utf8),
          let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
    let entries = parseClaudeAgents(arr)
    factsLock.lock()
    claudeAgentsCache = (entries, Date())
    factsLock.unlock()
    return entries
}

// MARK: - Finding an existing `claude attach`

// Where a background worker is already attached, if it is (2026-07-10). A worker has no terminal of
// its own, so the only trace of a live attach is the `claude attach <short-id>` client process. Two
// facts make this findable:
//   • its pid comes straight out of `ps -axo pid=,command=`;
//   • `ps -wwEp <pid>` prints that process's ENVIRONMENT, for any process of the same uid —
//     including ones Shepherd never spawned (verified on a foreign nvim). zellij sets
//     ZELLIJ_SESSION_NAME / ZELLIJ_PANE_ID in every pane's shell, so an attach running inside zellij
//     names its own pane.
// The cc-daemon can't answer this: its `leases` op reports an empty client list while an attach is
// plainly running (measured), so the process table is the only source.
// nil = nobody is attached. A non-nil result with a nil session = attached, but not inside zellij
// (a plain terminal window — the caller raises the window it opened instead).
struct AttachClient {
    let pid: Int32
    let zellijSession: String?
    let zellijPaneId: String?
}

func findAttachClient(short: String) -> AttachClient? {
    guard !short.isEmpty, let out = runCommand(["/bin/ps", "-axo", "pid=,command="]) else { return nil }
    for line in out.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let sp = trimmed.firstIndex(of: " ") else { continue }
        let cmd = trimmed[trimmed.index(after: sp)...].trimmingCharacters(in: .whitespaces)
        // "…/claude attach <short>" — the trailing id must match exactly, not by prefix.
        guard cmd.hasSuffix(" attach \(short)"), cmd.contains("claude"),
              let pid = Int32(trimmed[..<sp]) else { continue }
        let env = processEnvironment(pid: pid)
        return AttachClient(pid: pid, zellijSession: env["ZELLIJ_SESSION_NAME"], zellijPaneId: env["ZELLIJ_PANE_ID"])
    }
    return nil
}

// `ps -wwEp <pid>` appends the process's environment to its command line, space separated. Only the
// KEY=VALUE tokens we care about are parsed — a value containing spaces would split, but the vars we
// read (ZELLIJ_*, CLAUDE_*, TERM_PROGRAM, __CFBundleIdentifier) never do. Keys may mix case
// (__CFBundleIdentifier), so the key filter admits any letter — a stray command-line `foo=bar`
// token lands in the dict but nothing reads it. Empty on failure (a process that exited, or one
// owned by another user). The env is the block captured at exec: the zellij and parent-session vars
// are set before claude starts, so they are exactly what the status hook would have snapshotted.
func processEnvironment(pid: Int32) -> [String: String] {
    processEnvironments(pids: [pid])[pid] ?? [:]
}

// The same read for many processes in ONE `ps` call (it takes a comma-separated pid list and prints
// a line per process, the pid first). Refresh reads every hook-less session's env this way, so the
// cost is one subprocess, not one per row.
//
// Dead pids are dropped first, and the exit code is ignored, because `ps` is all-or-nothing: given a
// single pid it doesn't know, it prints NOTHING and exits 1 — one session that ended a moment ago
// would otherwise cost us every other session's env (measured). A pid that dies inside this window
// still empties the batch; the next refresh, a second later, has the survivors.
#if canImport(Darwin)
func processEnvironments(pids: [Int32]) -> [Int32: [String: String]] {
    let live = pids.filter { kill($0, 0) == 0 || errno != ESRCH }
    guard !live.isEmpty,
          let out = runCommand(["/bin/ps", "-wwEp", live.map(String.init).joined(separator: ",")],
                               ignoreExit: true) else { return [:] }
    var result: [Int32: [String: String]] = [:]
    for line in out.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let sp = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<sp]) else { continue }  // skips the header
        var env: [String: String] = [:]
        for token in trimmed[sp...].split(separator: " ") {
            guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { continue }
            let key = String(token[..<eq])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[key] = String(token[token.index(after: eq)...])
        }
        result[pid] = env
    }
    return result
}
#else
// Linux: /proc/<pid>/environ IS the env block captured at exec — NUL-separated, values keep
// their spaces, no subprocess at all (and unlike ps, no platform-binary blind spot). Readable
// for same-uid processes; a dead pid has no file and a zombie's is empty, so both just drop out.
func processEnvironments(pids: [Int32]) -> [Int32: [String: String]] {
    var result: [Int32: [String: String]] = [:]
    for pid in pids {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/environ"),
              !data.isEmpty else { continue }
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let s = String(data: Data(entry), encoding: .utf8),
                  let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            let key = String(s[..<eq])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[key] = String(s[s.index(after: eq)...])
        }
        result[pid] = env
    }
    return result
}
#endif

// The whole process table in one `ps` call: pid → (ppid, comm). Feeds zellijDescendant, which is
// how a session carrying BOTH `TERM_PROGRAM=vscode` and leaked ZELLIJ_* vars gets told apart from
// zellij genuinely running inside a VSCode terminal (see resolveBackend). Fetched per refresh only
// when some row actually presents that ambiguity. `comm` is the executable path — it can contain
// spaces, so the line splits on the first two columns only.
func processTable() -> [Int32: (ppid: Int32, comm: String)] {
    guard let out = runCommand(["/bin/ps", "-axo", "pid=,ppid=,comm="]) else { return [:] }
    var table: [Int32: (ppid: Int32, comm: String)] = [:]
    for line in out.split(separator: "\n") {
        let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard cols.count == 3, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
        table[pid] = (ppid, String(cols[2]))
    }
    return table
}

// MARK: - zellij send path (matrix B1)

// Run a `zellij action …` against a specific session by name (the env-var targeting proven to work
// headlessly), regardless of which session Shepherd was launched from.
@discardableResult
func zellijAction(_ session: String, _ action: [String]) -> String? {
    guard let zellij = zellijBin else { return nil }
    return runCommand([zellij] + action, extraEnv: ["ZELLIJ_SESSION_NAME": session])
}

// Is a zellij session safe to send keystrokes to? `write-chars` / `write` target the session's
// FOCUSED pane, so we only send when there's exactly one tab with exactly one terminal pane —
// otherwise we can't know we'd hit the agent, and refuse (matrix B1 誤爆防止). nil = couldn't
// determine (zellij missing / dump failed) → callers treat that as not-sendable.
func zellijSinglePane(_ session: String) -> Bool? {
    guard let out = zellijAction(session, ["action", "dump-layout"]) else { return nil }
    return zellijLayoutIsSinglePane(out)
}

// Parse a `dump-layout` KDL body: exactly one tab with exactly one leaf terminal pane?
func zellijLayoutIsSinglePane(_ out: String) -> Bool {
    // Only the live layout counts; drop the template sections (new_tab_template / swap_*), which
    // also carry `tab`/`pane` tokens.
    var cut = out.endIndex
    for kw in ["new_tab_template", "swap_tiled_layout", "swap_floating_layout"] {
        if let r = out.range(of: kw), r.lowerBound < cut { cut = r.lowerBound }
    }
    let body = String(out[..<cut])
    var tabs = 0, panes = 0
    for raw in body.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("tab ") || line.hasPrefix("tab{") { tabs += 1 }
        // A leaf terminal pane: a `pane …` line that opens no child block and isn't a plugin (the
        // tab-bar pane wraps a `plugin` child; container panes end in `{`).
        if (line == "pane" || line.hasPrefix("pane ")) && !line.contains("{") && !line.contains("plugin") { panes += 1 }
    }
    return tabs == 1 && panes == 1
}

// Send text (+ Enter, CR=13) to a zellij session's focused pane — the analogue of a terminal's
// `pane send-text` / `send-keys enter`. Re-checks the single-pane guard at send time. Returns false
// when the session isn't safe to target. Call off the main thread.
@discardableResult
func sendToZellij(_ session: String, text: String, enter: Bool = true) -> Bool {
    guard zellijSinglePane(session) == true else { return false }
    if !text.isEmpty { zellijAction(session, ["action", "write-chars", text]) }
    if enter { zellijAction(session, ["action", "write", "13"]) }
    return true
}

// The pane an attached client is focused on, as the bare id zellij's own env var uses
// ("terminal_13" → "13", matching the hook-recorded ZELLIJ_PANE_ID). nil = nobody attached
// (or zellij missing) — pane-level focus and targeted sends both need this focus feedback,
// so nil disables them. Measured 2026-07-08 on zellij 0.43.1.
func zellijFocusedPaneId(_ session: String) -> String? {
    guard let out = zellijAction(session, ["action", "list-clients"]) else { return nil }
    return zellijFocusedPaneId(fromListClients: out)
}

// Parse `list-clients` output: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND" header, one row per
// attached client. Mirrored clients share focus, so the first row is the session's focus.
func zellijFocusedPaneId(fromListClients out: String) -> String? {
    for line in out.split(separator: "\n") {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty || l.hasPrefix("CLIENT_ID") { continue }
        let cols = l.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 2 else { continue }
        let pane = String(cols[1])
        return pane.hasPrefix("terminal_") ? String(pane.dropFirst("terminal_".count)) : pane
    }
    return nil
}

// Move a session's focus onto a specific pane. zellij 0.43 has no focus-pane-by-id action, so
// we walk: focus-next-pane through the current tab (checking list-clients after each hop, and
// breaking when the tab's panes start repeating), then go-to-next-tab, over every tab once.
// Bounded, and a no-op walk (single pane per tab) exits on the first repeat. Returns false when
// the pane never came up (detached session, pane closed, floating pane the walk can't reach).
// Call off the main thread.
@discardableResult
func zellijFocusPane(_ session: String, paneId: String) -> Bool {
    guard var current = zellijFocusedPaneId(session) else { return false }   // nobody attached
    if current == paneId { return true }
    let tabCount = zellijAction(session, ["action", "query-tab-names"])
        .map { $0.split(separator: "\n").count } ?? 1
    for _ in 0..<max(1, tabCount) {
        var seenInTab: Set<String> = [current]
        for _ in 0..<24 {   // panes-per-tab bound
            zellijAction(session, ["action", "focus-next-pane"])
            guard let next = zellijFocusedPaneId(session) else { return false }
            if next == paneId { return true }
            if seenInTab.contains(next) { break }   // wrapped — not in this tab
            seenInTab.insert(next)
            current = next
        }
        zellijAction(session, ["action", "go-to-next-tab"])
        guard let hopped = zellijFocusedPaneId(session) else { return false }
        if hopped == paneId { return true }
        current = hopped
    }
    return false
}

// Send text to a SPECIFIC pane of a (possibly multi-pane) zellij session: focus it first —
// verified through list-clients — write, then hand focus back to wherever the user had it.
// Needs an attached client (the focus walk is blind without one); returns false otherwise so
// the caller can hint "open the session first". Call off the main thread.
@discardableResult
func sendToZellijPane(_ session: String, paneId: String, text: String, enter: Bool = true) -> Bool {
    let original = zellijFocusedPaneId(session)
    guard zellijFocusPane(session, paneId: paneId) else { return false }
    if !text.isEmpty { zellijAction(session, ["action", "write-chars", text]) }
    if enter { zellijAction(session, ["action", "write", "13"]) }
    if let original = original, original != paneId { zellijFocusPane(session, paneId: original) }
    return true
}

// (agentRead — the herdr screen scrape behind the reply preview — was retired in P3, 2026-07-10:
// the preview reads the pending question from the transcript instead. See blockedPromptFromTranscript.)

// MARK: - Logged-in account

// The Claude account Shepherd's own machine is logged into, for the header. `email` and `plan`
// (subscriptionType — "max" / "pro" / …) come from `claude auth status --json`. nil when logged out
// or the CLI can't be run.
struct AccountInfo: Equatable {
    let email: String
    let plan: String?
}

// Parse `claude auth status --json`. Only a logged-in first-party account yields an AccountInfo —
// an API-key or logged-out session has no email to show. Split out for tests.
func parseAccount(_ json: [String: Any]) -> AccountInfo? {
    guard (json["loggedIn"] as? Bool) == true,
          let email = json["email"] as? String, !email.isEmpty else { return nil }
    let plan = (json["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return AccountInfo(email: email, plan: plan)
}

// Fires (on a background queue) when a revalidated account differs from the cached one.
// Set once at launch; the AppDelegate repaints through the normal debounced path.
var onAccountChanged: (() -> Void)?

// The logged-in account, cached 5 min (the login rarely changes and this is a subprocess).
// Stale-while-revalidate, like prInfo: ALWAYS returns the cached value immediately and refreshes
// an expired one on a background queue. It must never run the subprocess inline — headerView calls
// this from rebuild() right after every subview was torn down, and the ~0.3s the CLI takes let the
// empty panel reach the screen: the HUD visibly blanked and repopulated every 5 minutes
// (2026-07-14, caught by frame capture).
func claudeAccount() -> AccountInfo? {
    factsLock.lock()
    let cached = accountCache
    let stale = cached == nil || Date().timeIntervalSince(cached!.at) >= 300
    // claudeBin gate inside the flag decision — otherwise a nil CLI would latch
    // accountFetching true forever and block all future revalidation.
    let startFetch = stale && !accountFetching && claudeBin != nil
    if startFetch { accountFetching = true }
    factsLock.unlock()
    if startFetch, let claudeBin = claudeBin {
        DispatchQueue.global(qos: .utility).async {
            let account = runJSON([claudeBin, "auth", "status", "--json"]).flatMap(parseAccount)
            factsLock.lock()
            let changed = accountCache?.account != account
            accountCache = (account, Date())
            accountFetching = false
            factsLock.unlock()
            if changed { onAccountChanged?() }
        }
    }
    return cached?.account
}
