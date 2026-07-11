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

// Read the registry directory. A claude killed with SIGKILL leaves its file behind (the CLI
// normally removes it on exit), so entries whose pid is provably gone are skipped — the same
// kill(-0) test the status-dir GC uses.
func readSessionsRegistry() -> [SessionRegistryEntry] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: claudeSessionsDir) else { return [] }
    var out: [SessionRegistryEntry] = []
    for name in names where name.hasSuffix(".json") {
        let path = (claudeSessionsDir as NSString).appendingPathComponent(name)
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
            entrypoint: o["entrypoint"] as? String))
    }
    return out
}
