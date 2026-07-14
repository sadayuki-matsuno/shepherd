import Foundation

// ~/.claude/teams/<team>/ — agent teams' on-disk state (measured 2026-07-14):
//   config.json        — the roster. members[] carry name/agentType/model/color/joinedAt; a
//                        teammate that approves a shutdown_request is REMOVED from members, so
//                        membership distinguishes "idle, can be re-activated" from "gone".
//                        Finished-but-idle members stay listed indefinitely.
//   inboxes/<name>.json — a member's message queue: a JSON array of
//                        {"from","text","timestamp","msgV":1,"msg_id","type":"message","read":false}.
//                        The harness watches these files: appending a well-formed entry from an
//                        OUTSIDE process resumes an idle teammate, which receives it as a
//                        <teammate-message> (verified end-to-end on party-game, 2026-07-14 — the
//                        teammate replied). The file drains to [] on delivery.
//
// The write path is UNAUTHENTICATED and UNVALIDATED: an entry missing "text" crashed the
// receiving teammate's resume (`t.replace` on undefined) and killed its delivery for good
// (measured on a probe teammate). So injectTeammateMessage never improvises — it writes exactly
// the proven shape, refuses to touch an inbox it can't parse, and fails soft like every other
// data source here.
//
// One race is inherent and accepted: read-append-write against a queue the harness drains
// concurrently. An idle teammate's inbox is quiet by definition, but the LEAD's inbox is live —
// if the harness drains between our read and our write, the drained entries are written back and
// get delivered twice. The window is microseconds against a manual, occasional action, and a
// duplicate message is confusing rather than destructive, so this stays documented rather than
// locked (there is no lock the harness would honor). All writes funnel through one serial queue
// so at least Shepherd never races itself.
var claudeTeamsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/teams")

// A lead session's team config. The implicit team dir is session-<first 8 of the session id>;
// config.json's leadSessionId is checked so a stale or colliding dir never reads as this
// session's team. nil = no team (the common case).
func teamConfig(leadSessionId: String) -> [String: Any]? {
    guard !leadSessionId.isEmpty else { return nil }
    let dir = (claudeTeamsDir as NSString).appendingPathComponent("session-\(leadSessionId.prefix(8))")
    guard let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("config.json")),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          (obj["leadSessionId"] as? String) == leadSessionId else { return nil }
    return obj
}

// Current roster names, minus the lead itself. nil = the session has no team.
func teamMemberNames(leadSessionId: String) -> Set<String>? {
    guard let config = teamConfig(leadSessionId: leadSessionId),
          let members = config["members"] as? [[String: Any]] else { return nil }
    var names = Set<String>()
    for member in members {
        guard let name = member["name"] as? String, !name.isEmpty,
              (member["agentType"] as? String) != "team-lead" else { continue }
        names.insert(name)
    }
    return names
}

// Append one message to a member's inbox — the exact shape the harness itself writes (see the
// header comment for why nothing here is optional or improvised). `from` defaults to "team-lead",
// the sender proven to deliver end-to-end; "shepherd" is used for requests addressed TO the lead
// so the lead can tell a HUD-originated request from its own teammates' traffic.
// Returns false without touching the file on any doubt: no team, an unparsable existing inbox
// (never clobber another writer's queue), or a failed write.
func injectTeammateMessage(leadSessionId: String, to name: String, text: String,
                           from: String = "team-lead") -> Bool {
    guard !name.isEmpty, !text.isEmpty,
          teamConfig(leadSessionId: leadSessionId) != nil else { return false }
    let inboxes = ((claudeTeamsDir as NSString)
        .appendingPathComponent("session-\(leadSessionId.prefix(8))") as NSString)
        .appendingPathComponent("inboxes")
    let path = (inboxes as NSString).appendingPathComponent("\(name).json")
    var entries: [[String: Any]] = []
    if let data = FileManager.default.contents(atPath: path) {
        guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return false
        }
        entries = existing
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    entries.append([
        "from": from,
        "text": text,
        "timestamp": iso.string(from: Date()),
        "msgV": 1,
        "msg_id": UUID().uuidString.lowercased(),
        "type": "message",
        "read": false,
    ])
    guard let out = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted]) else {
        return false
    }
    try? FileManager.default.createDirectory(atPath: inboxes, withIntermediateDirectories: true)
    return (try? out.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
}
