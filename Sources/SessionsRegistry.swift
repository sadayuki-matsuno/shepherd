import Foundation

// MARK: - Claude Code's per-process session registry (~/.claude/sessions/<pid>.json)
//
// Written by each claude process ITSELF and updated live on state changes — it is what
// `claude agents` reads for its interactive list (measured 2026-07-10). One JSON object per file:
// pid, sessionId, cwd, kind ("interactive" / "background"), name ("shepherd-1f"), status
// ("busy" / "idle" / "waiting"), waitingFor ("permission prompt" / "worker request" /
// "sandbox request" / "dialog open" / "input needed"), startedAt / updatedAt (ms epoch).
//
// This is the hook-FREE state source, and the P2 replacement for herdr's `agent list`
// (herdr-removal-plan): it needs no hook installed in the session, costs a directory read instead
// of a subprocess, updates within the CLI's own render loop, and — unlike the hooks — carries
// `waiting` + waitingFor for states the hook only learns indirectly. The directory is watched by
// the same FSEvents stream as the status dir, so a hook-less session's busy/idle flip repaints the
// board without any polling.
//
// It is an undocumented internal file: read everything additively (missing/unknown fields → nil,
// malformed files skipped) so a CLI version bump degrades this source instead of breaking the HUD.

struct SessionRegistryEntry {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let kind: String          // "interactive" / "background"
    let name: String?
    let status: String?       // "busy" / "idle" / "waiting"
    let waitingFor: String?   // present when status == "waiting"
    let startedAt: Date?
    let updatedAt: Date?
    var entrypoint: String? = nil  // "cli" (interactive REPL) / "sdk-cli" (`claude -p` and SDK runs,
                                   // measured 2026-07-11) — the only source that tells them apart
    var configDir: String? = nil   // the CLAUDE_CONFIG_DIR this entry was read from; nil = the
                                   // default ~/.claude (see discoveredConfigDirs)
}

// Overridable for tests, like statusDir / claudeProjectsDir.
var claudeSessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")

// The registry's status vocabulary → the board's. The CLI validates `status` against exactly four
// values (busy / shell / idle / waiting — read out of the binary, 2026-07-10) and drops anything
// else, so this switch is total: `shell` is an idle session whose user is typing a `!` shell
// command. A compacting session simply reads `busy`; `error` comes from the transcript
// (transcriptErrored) or, for a background worker, the daemon's `failed` state.
func statusFromRegistry(_ e: SessionRegistryEntry) -> String {
    switch e.status {
    case "busy": return "working"
    case "waiting": return "blocked"
    case "idle", "shell": return "idle"
    default: return "unknown"
    }
}

// MARK: - Sessions living under another CLAUDE_CONFIG_DIR

// `CLAUDE_CONFIG_DIR=<dir>` moves a session's WHOLE state under that dir — sessions/<pid>.json and
// projects/<sanitized-cwd>/<session>.jsonl both — so such a session is invisible to every
// default-path source, `claude agents --json --all` included (it reads only its own config dir;
// verified 2026-08-23 against a live session under ~/.claude-omeroid). The dirs in use are
// recoverable from the sessions themselves: the variable is in the env of every claude process
// started with it, and `ps` prints the env of any process of this uid.
//
// One `ps` for the whole table (0.06s / 400KB measured 2026-08-23), cached 30s — a dir only appears
// when a session starts under a new one, and the board's 30s fallback timer bounds the wait anyway.
// Nothing is configured: whatever is running is what shows up.
func discoveredConfigDirs(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
    // A fixture run (dev/demo-board.sh) stages its own sessions/projects dirs; discovering the real
    // ones would mix live sessions into a staged capture.
    guard env["SHEPHERD_SESSIONS_DIR"] == nil, env["SHEPHERD_PROJECTS_DIR"] == nil else { return [] }
    factsLock.lock()
    let cached = configDirsCache
    factsLock.unlock()
    if let c = cached, Date().timeIntervalSince(c.at) < 30 { return c.dirs }
    // Stale-while-error, like prInfo and the usage snapshot: a `ps` that didn't answer (timeout,
    // spawn failure) is not evidence that nothing is running. Caching "no dirs" on it would drop
    // every second-account session off the board — and keep it off for the next 30 seconds.
    guard let out = runCommand(["/bin/ps", "-axwwEo", "pid=,command="], ignoreExit: true) else {
        return cached?.dirs ?? []
    }
    // A dir without a sessions/ subdir is not a config dir in use (a stale value, a relative path
    // we can't resolve) — dropping it here keeps the FSEvents watch set to real directories.
    let dirs = configDirsFromPS(out).filter {
        FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("sessions"))
    }
    factsLock.lock()
    configDirsCache = (dirs, Date())
    factsLock.unlock()
    return dirs
}

// The CLAUDE_CONFIG_DIR values in a `ps -E` dump, minus the default ~/.claude (already read),
// deduped and sorted so an unchanged machine yields a byte-identical watch set. A value containing
// spaces would split — the same limitation every other var read out of `ps` has (see
// processEnvironments); config dirs in practice don't.
func configDirsFromPS(_ out: String, home: String = NSHomeDirectory()) -> [String] {
    let key = "CLAUDE_CONFIG_DIR="
    var dirs: Set<String> = []
    for token in out.split(whereSeparator: { $0 == " " || $0 == "\n" }) where token.hasPrefix(key) {
        guard let dir = nonDefaultConfigDir(String(token.dropFirst(key.count)), home: home) else { continue }
        dirs.insert(dir)
    }
    return dirs.sorted()
}

// Read the registry directories: the default one, then the sessions/ of each config dir passed in.
// A session id seen twice keeps the DEFAULT dir's entry — and with it the default transcript path.
// Each extra dir's entries are tagged with their config dir, and their transcript location is
// published to sessionProjectsDirs, which is how transcriptDir sends every transcript read for
// those sessions into the right projects/ tree.
func readSessionsRegistry(configDirs: [String] = []) -> [SessionRegistryEntry] {
    var out = readSessionsDir(claudeSessionsDir, configDir: nil)
    var seen = Set(out.map { $0.sessionId })
    var projectsDirs: [String: String] = [:]
    for configDir in configDirs {
        let dir = (configDir as NSString).appendingPathComponent("sessions")
        for e in readSessionsDir(dir, configDir: configDir) where !seen.contains(e.sessionId) {
            seen.insert(e.sessionId)
            projectsDirs[e.sessionId] = (configDir as NSString).appendingPathComponent("projects")
            out.append(e)
        }
    }
    // MERGED, never replaced: a caller that scans only the default dir — readSessionsRegistry() with
    // no configDirs, the obvious thing for future code to write — must not wipe the routing of
    // sessions it never looked at, which would silently send their transcript reads to the default
    // projects/ tree. fetchAgents prunes the map by live session instead.
    projectsDirLock.lock()
    for (sid, dir) in projectsDirs { sessionProjectsDirs[sid] = dir }
    projectsDirLock.unlock()
    return out
}

// Read one registry directory. A claude killed with SIGKILL leaves its file behind (the CLI
// normally removes it on exit), so entries whose pid is provably gone are skipped — the same
// kill(-0) test the status-dir GC uses.
func readSessionsDir(_ sessionsDir: String, configDir: String?) -> [SessionRegistryEntry] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return [] }
    var out: [SessionRegistryEntry] = []
    for name in names where name.hasSuffix(".json") {
        let path = (sessionsDir as NSString).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: path),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = o["sessionId"] as? String, !sessionId.isEmpty,
              let pid = (o["pid"] as? NSNumber)?.int32Value else { continue }
        if kill(pid, 0) != 0 && errno == ESRCH { continue }   // stale file of a dead process
        func ms(_ key: String) -> Date? {
            (o[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        out.append(SessionRegistryEntry(
            pid: pid,
            sessionId: sessionId,
            cwd: o["cwd"] as? String ?? "",
            kind: o["kind"] as? String ?? "interactive",
            name: o["name"] as? String,
            status: o["status"] as? String,
            waitingFor: o["waitingFor"] as? String,
            startedAt: ms("startedAt"),
            updatedAt: ms("statusUpdatedAt") ?? ms("updatedAt"),
            entrypoint: o["entrypoint"] as? String,
            configDir: configDir))
    }
    return out
}
