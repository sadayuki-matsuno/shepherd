import Foundation
#if canImport(Glibc)
import Glibc   // socket / connect / setsockopt (Darwin re-exports these through Foundation)
#endif

// cc-daemon's control socket — the undocumented protocol `claude stop` speaks.
//
//   • One newline-delimited JSON request, one reply, over a unix socket at
//     /tmp/cc-daemon-<uid>/<hash>/control.sock (found via the roster — see controlSocketPath).
//   • `proto` is mandatory; a mismatch is rejected outright ({"code":"EPROTO"}), which is how the
//     daemon guards against a CLI of a different version.
//   • There is no authentication — the daemon relies on the 0700 directory and a uid check. (The
//     32-byte ~/.claude/daemon/control.key belongs to `attach`, not to this.)
//   • `claude stop <id>` is `{"op":"kill","short":"<id>"}` plus a recovery the socket cannot offer: on
//     ENOCONN/ETIMEOUT the CLI hunts the process down and SIGTERMs it. closeWorkspace keeps the CLI for
//     exactly that, and uses the socket for the fast, common path.
//
// Three properties shape the code below:
//   • kill is ASYNCHRONOUS. `{"ok":true}` means "accepted", not "stopped" — the worker leaves the list a
//     few hundred ms later. Callers that need certainty poll daemonJobExists.
//   • kill of an id the daemon no longer has answers `{"ok":false,"code":"ENOJOB"}`. That is not an error
//     to act on: the worker is gone, which is what the caller wanted.
//   • Talking to this socket does not keep the daemon alive — with its last worker gone it exits after 5
//     idle seconds, because only `attach` takes a lease. The refresh loop may call daemonJobs() freely.
//
// Everything here fails soft: no daemon, a stale socket, a proto bump, a malformed reply — all
// return nil, and every caller treats the data as additive.

let daemonRosterPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/daemon/roster.json")

private let daemonProto = 1

// One request/response round trip. nil means we never got an answer (no daemon, stale socket, timeout,
// garbage) — distinct from an answered `{"ok":false,"code":…}`, which callers read for themselves.
private func daemonRPC(_ message: [String: Any], timeoutMs: Int32 = 300) -> [String: Any]? {
    guard let rosterData = FileManager.default.contents(atPath: daemonRosterPath),
          let roster = (try? JSONSerialization.jsonObject(with: rosterData)) as? [String: Any],
          let sockPath = controlSocketPath(roster: roster) else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(sockPath.utf8)
    // sun_path is 104 bytes on Darwin and must stay NUL-terminated.
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = b }
        }
    }

    // Glibc's SOCK_STREAM is an enum (__socket_type), Darwin's a plain Int32.
    #if canImport(Glibc)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    // A hung daemon must not stall a refresh (the CLI waits 5s here; we won't).
    // suseconds_t is Int32 on Darwin but Int on Glibc — spell the field type, not a literal one.
    var tv = timeval(tv_sec: time_t(timeoutMs / 1000), tv_usec: suseconds_t((timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    var request = message
    request["proto"] = daemonProto
    guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    var payload = [UInt8](body)
    payload.append(0x0a)   // the daemon reads newline-delimited JSON
    var sent = 0
    while sent < payload.count {
        let n = payload.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), payload.count - sent) }
        guard n > 0 else { return nil }
        sent += n
    }

    // Read until the terminating newline — a `list` reply runs to several KB.
    var reply = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while !reply.contains(0x0a) {
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { break }
        reply.append(contentsOf: chunk[0..<n])
        if reply.count > 4_000_000 { return nil }
    }
    guard let end = reply.firstIndex(of: 0x0a) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(reply[0..<end]))) as? [String: Any]
}

// The live workers a `list` reply describes, or nil if the daemon never answered / refused (a proto
// bump answers {"ok":false,"code":"EPROTO"} — we go quiet rather than misread a future schema).
private func daemonListJobs() -> [DaemonJob]? {
    guard let reply = daemonRPC(["op": "list"]), reply["ok"] as? Bool == true,
          let arr = reply["jobs"] as? [[String: Any]] else { return nil }
    return parseDaemonJobs(arr)
}

// The live background workers, or nil when no daemon is up. Cached 2s (see daemonJobsCache).
func daemonJobs() -> [DaemonJob]? {
    factsLock.lock()
    let cached = daemonJobsCache
    factsLock.unlock()
    if let c = cached, Date().timeIntervalSince(c.at) < 2 { return c.jobs }

    guard let jobs = daemonListJobs() else { return nil }
    factsLock.lock()
    daemonJobsCache = (jobs, Date())
    factsLock.unlock()
    return jobs
}

// Is this short id still a live worker? Bypasses the cache — the callers are close paths confirming
// that a kill actually landed, and a 2s-stale "yes" would defeat the point. An unreachable daemon
// answers "no", which is the safe reading here: the caller then falls back to the CLI, which knows
// how to hunt down and SIGTERM a worker that outlived its daemon.
func daemonJobExists(_ short: String) -> Bool {
    daemonListJobs()?.contains { $0.short == short } ?? false
}

// Ask the daemon to stop a background worker — what `claude stop` does, without the 0.3s subprocess.
// True means the daemon owns the outcome: it either accepted the kill (the worker exits a few hundred
// ms later — confirm with daemonJobExists) or told us it has no such job, which is the same end state.
// False means we couldn't reach it, and the caller should fall back to the CLI.
func daemonKill(_ short: String) -> Bool {
    guard let reply = daemonRPC(["op": "kill", "short": short]) else { return false }
    if reply["ok"] as? Bool == true { return true }
    return reply["code"] as? String == "ENOJOB"   // already gone — measured, and what the CLI concludes too
}

// Answer a blocked background worker over the socket — the text lands as the user's reply to its
// pending question (measured 2026-07-10: an AskUserQuestion-blocked worker took the answer and
// finished its turn). Unlike kill, `reply` demands auth: the 32-byte ~/.claude/daemon/control.key
// (EAUTH without it — the same key `attach` presents). True = the daemon accepted the reply; the
// worker's state flips a moment later (the refresh loop picks it up).
func daemonReply(short: String, text: String) -> Bool {
    let keyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/daemon/control.key")
    guard let key = (try? String(contentsOfFile: keyPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return false }
    guard let reply = daemonRPC(["op": "reply", "short": short, "text": text, "auth": key]) else { return false }
    return reply["ok"] as? Bool == true
}
