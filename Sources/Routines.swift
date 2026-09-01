import Foundation

// MARK: - Routines — claude.ai's scheduled cloud agents (2026-09-01)
//
// A routine is a cron-scheduled agent that runs in Anthropic's cloud, not on this machine, so
// none of the local sources see it: no pid in the sessions registry, no transcript, no daemon
// job. Two private endpoints are the whole story:
//
//   GET /v1/code/triggers                  → the routines (schedule, enabled, last run)
//   GET /v1/code/sessions?trigger_id=<id>  → that routine's runs, carrying worker_status
//
// Same discipline as oauth/usage and the frames endpoint: parse defensively, return nil on any
// surprise, let a shape change cost the section and nothing else.
//
// Measured 2026-09-01 (headless probe against this account):
//   • BOTH `anthropic-beta: ccr-triggers-2026-01-30` and `anthropic-version: 2023-06-01` are
//     required — the beta header alone answers HTTP 400. The claude-cli User-Agent is not.
//   • `last_run.status` reaching ROUTINE_RUN_STATUS_SUCCEEDED does NOT mean the run's session
//     finished: both live routines reported SUCCEEDED while one of their sessions was still
//     `running`. worker_status therefore has to come from the sessions call, and gating that call
//     on a PENDING last_run (the obvious optimization) would hide every approval prompt.
//   • A bare /v1/code/sessions lists the account's interactive cloud sessions, with no trigger_id
//     at all — it does not cover routine runs, so the per-routine call can't be collapsed into one.

// A routine's most recent run, as the trigger record reports it.
struct RoutineRun: Equatable {
    let status: String?      // "ROUTINE_RUN_STATUS_SUCCEEDED" / "…_PENDING" (FAILED unobserved)
    let sessionId: String?   // "cse_…" — the cloud session that run happened in
    let firedAt: Date?
    let finishedAt: Date?
}

struct Routine: Equatable {
    let id: String              // "trig_…"
    let name: String
    let enabled: Bool
    let cronExpression: String? // absent on run-once routines
    let nextRunAt: Date?
    let lastFiredAt: Date?
    let lastRun: RoutineRun?
    // Filled by the sessions pass. nil = never fetched, or that fetch failed — the row then
    // renders from the trigger record alone rather than claiming the routine is idle.
    var liveState: String?      // "requires_action" / "running" / "idle"
    var liveSessionId: String?  // the run a click should open
    // This cycle's sessions call for THIS routine failed, so liveState is either carried over or
    // unknown — never current. Per-routine, because one endpoint failing out of several says
    // nothing about the others, and a routine whose very first call failed is "unknown", not
    // "confirmed idle".
    var liveStale = false
}

// One row of the sessions listing. Only the two fields the board needs; everything else the
// endpoint returns (participants, tags, unread, …) is ignored on purpose.
struct RoutineSessionRow: Equatable {
    let id: String
    let workerStatus: String?   // "running" / "idle" / "requires_action"
}

// Accepts `{data:[…]}` (live shape) or a bare array; nil on anything else, so a 404 body or a
// reshaped response leaves the section empty-with-an-error instead of a confident "ROUTINES — 0".
func parseTriggers(_ obj: Any?) -> [Routine]? {
    let arr: [[String: Any]]
    if let a = obj as? [[String: Any]] { arr = a }
    else if let d = obj as? [String: Any], let a = (d["data"] ?? d["triggers"]) as? [[String: Any]] { arr = a }
    else { return nil }
    return arr.compactMap { o in
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        var run: RoutineRun?
        if let r = o["last_run"] as? [String: Any] {
            run = RoutineRun(status: r["status"] as? String,
                             sessionId: r["session_id"] as? String,
                             firedAt: parseUsageISODate(r["fired_at"] as? String),
                             finishedAt: parseUsageISODate(r["finished_at"] as? String))
        }
        return Routine(id: id,
                       name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                       // Unknown → enabled: a routine we can't classify should read normally, not
                       // arrive pre-dimmed as if the user had switched it off.
                       enabled: (o["enabled"] as? NSNumber)?.boolValue ?? true,
                       cronExpression: (o["cron_expression"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       nextRunAt: parseUsageISODate(o["next_run_at"] as? String),
                       lastFiredAt: parseUsageISODate(o["last_fired_at"] as? String),
                       lastRun: run)
    }
}

func parseRoutineSessions(_ obj: Any?) -> [RoutineSessionRow]? {
    let arr: [[String: Any]]
    if let a = obj as? [[String: Any]] { arr = a }
    else if let d = obj as? [String: Any], let a = d["data"] as? [[String: Any]] { arr = a }
    else { return nil }
    return arr.compactMap { o in
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        return RoutineSessionRow(id: id, workerStatus: o["worker_status"] as? String)
    }
}

// What a routine's runs say about it now, and which run a click should open. nil when there are
// no rows (the sessions call failed or hasn't run) — "we don't know" must not render as idle.
//
// requires_action outranks everything and lends its own session id: an unanswered permission
// prompt is the reason this section exists, and it stays unanswered whichever run raised it.
// "running" is only ever the run last_run points at — a routine's older sessions keep
// `status: active` forever, and one stuck mid-turn must not make the routine look busy today.
func routineLiveState(rows: [RoutineSessionRow], lastRunSessionId: String?)
    -> (state: String, sessionId: String?)? {
    guard !rows.isEmpty else { return nil }
    if let waiting = rows.first(where: { $0.workerStatus == "requires_action" }) {
        return ("requires_action", waiting.id)
    }
    if let current = rows.first(where: { $0.id == lastRunSessionId }), current.workerStatus == "running" {
        return ("running", current.id)
    }
    return ("idle", lastRunSessionId ?? rows.first?.id)
}

// "cse_01Ucd…" → that run's page on claude.ai. The rows carry no url field; the id's body is the
// session slug verbatim (measured 2026-09-01). nil for anything that isn't a cloud-session id.
func routineSessionURL(_ id: String?) -> String? {
    guard let id = id, id.hasPrefix("cse_") else { return nil }
    return "https://claude.ai/code/session_" + id.dropFirst("cse_".count)
}

// last_run.status → the mark the row shows for the previous run. Matched on substrings, not an
// exact list: only SUCCEEDED and PENDING have been observed, and a failure's real spelling
// (…_FAILED? …_ERRORED?) shouldn't have to be guessed correctly to render as a failure.
func routineRunKind(_ raw: String?) -> String? {
    guard let raw = raw, !raw.isEmpty else { return nil }
    let s = raw.uppercased()
    if s.contains("SUCCEED") { return "succeeded" }
    if s.contains("FAIL") || s.contains("ERROR") { return "failed" }
    if s.contains("CANCEL") { return "cancelled" }
    if s.contains("PENDING") || s.contains("RUNNING") { return "pending" }
    return nil
}

// "9/2 07:00" — the row's next-run stamp, in the viewer's zone. Pinned to en_US_POSIX like the
// shelf's date stamp so the field order can't shift with the system locale.
func routineNextRunText(_ d: Date?, timeZone: TimeZone = .current) -> String? {
    guard let d = d else { return nil }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = timeZone
    fmt.dateFormat = "M/d HH:mm"
    return fmt.string(from: d)
}

// The live state a routine should carry after its sessions pass: what the rows say, or — when the
// call failed or returned nothing usable — what we last knew about it. Dropping to "no live state"
// would turn an approval-waiting row back into an ordinary one, which reads as "resolved" when
// nothing was resolved. Pure, unit-tested.
// `stale` is what the row dims on: nil rows mean the call failed, so whatever state comes back is
// the last thing we knew rather than the current one — including "nothing", which must not read as
// a confirmed idle.
func routineCarriedState(rows: [RoutineSessionRow]?, lastRunSessionId: String?, previous: Routine?)
    -> (state: String?, sessionId: String?, stale: Bool) {
    if let rows = rows, let live = routineLiveState(rows: rows, lastRunSessionId: lastRunSessionId) {
        return (live.state, live.sessionId, false)
    }
    // An empty-but-successful list is not stale — the routine genuinely has no runs to report.
    return (previous?.liveState, previous?.liveSessionId, rows == nil)
}

// Which of the four ways a row can read. The order is the point: an unanswered prompt outranks
// everything (it needs a human whatever else is true), a routine the user switched off reads as
// off even if a run is still winding down (showing it busy invites a click on something the user
// has already decided against), and only then does a live run show.
func routineRowState(_ r: Routine) -> String {
    if r.liveState == "requires_action" { return "requires_action" }
    if !r.enabled { return "disabled" }
    if r.liveState == "running" { return "running" }
    return "idle"
}

// One definition for the approval count, shared by the section bar and the minimized strip — two
// places that drifted apart ("approve N" vs "needs approval N") when each spelled its own.
func routineApprovalLabel(_ count: Int) -> String {
    L("承認待ち \(count)", "needs approval \(count)")
}

// Which routines need the per-routine sessions call. Enabled ones always — that's where a live
// run is. A disabled one only while its last run is still PENDING: a run that started before the
// routine was switched off can still be sitting at a permission prompt, and skipping it would
// bury exactly the state this section exists to surface.
func routineNeedsSessionPass(_ r: Routine) -> Bool {
    r.enabled || routineRunKind(r.lastRun?.status) == "pending"
}

// Staged-capture mode: dev/demo-board.sh and the SHEPHERD_DUMP self-checks point Shepherd's data
// directories elsewhere, and no private API may be called while they do — a staged screenshot must
// never carry the real account's routines.
var routineFixtureMode: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["SHEPHERD_SESSIONS_DIR"] != nil || env["SHEPHERD_PROJECTS_DIR"] != nil
}

// Invented routines for a staged capture (SHEPHERD_FAKE_ROUTINE_ACTION), including the
// approval-waiting state a real board only reaches when a run actually stops at a prompt. Fixture
// mode never fetches, so without these the demo board has nothing to photograph. Names and ids are
// fictional by the same rule the rest of the demo board follows.
func fakeActionRoutines(now: Date = Date()) -> [Routine] {
    [Routine(id: "trig_demo_release_notes", name: "release-notes-digest", enabled: true,
             cronExpression: "0 9 * * 1", nextRunAt: now.addingTimeInterval(3600 * 19),
             lastFiredAt: now.addingTimeInterval(-3600 * 5),
             lastRun: RoutineRun(status: "ROUTINE_RUN_STATUS_PENDING", sessionId: "cse_demoAwaiting",
                                 firedAt: now.addingTimeInterval(-3600 * 5), finishedAt: nil),
             liveState: "requires_action", liveSessionId: "cse_demoAwaiting"),
     Routine(id: "trig_demo_dependency_audit", name: "dependency-audit", enabled: true,
             cronExpression: "0 3 * * *", nextRunAt: now.addingTimeInterval(3600 * 8),
             lastFiredAt: now.addingTimeInterval(-3600 * 16),
             lastRun: RoutineRun(status: "ROUTINE_RUN_STATUS_SUCCEEDED", sessionId: "cse_demoDone",
                                 firedAt: now.addingTimeInterval(-3600 * 16),
                                 finishedAt: now.addingTimeInterval(-3600 * 15)),
             liveState: "idle", liveSessionId: "cse_demoDone")]
}

// The section's row order: anything waiting on approval first, then live routines before disabled
// ones, then soonest next run. Pure, unit-tested.
func routineListOrder(_ routines: [Routine]) -> [Routine] {
    routines.sorted { a, b in
        let aw = a.liveState == "requires_action", bw = b.liveState == "requires_action"
        if aw != bw { return aw }
        if a.enabled != b.enabled { return a.enabled }
        let an = a.nextRunAt ?? .distantFuture, bn = b.nextRunAt ?? .distantFuture
        if an != bn { return an < bn }
        return a.name < b.name
    }
}

// The private-API header pair the triggers/sessions endpoints demand (see the note above).
let routineAPIHeaders = ["anthropic-beta": "ccr-triggers-2026-01-30",
                         "anthropic-version": "2023-06-01"]

// Fetch the account's routines, then their runs for worker_status. nil + a message on failure, so
// the caller can keep the list it has (stale-while-error, same contract as fetchArtifactFrames).
// `previous` is the list already on screen: a routine whose sessions call fails keeps the live
// state it had rather than losing it, because dropping to "no live state" turns an
// approval-waiting row back into an ordinary one — a false all-clear on the one thing this
// section exists to show. Call off the main thread.
func fetchRoutines(previous: [Routine] = []) -> (routines: [Routine]?, error: String?) {
    guard let token = claudeOAuthAccessToken() else {
        return (nil, L("トークンが読めない", "no oauth token"))
    }
    let (status, body, netErr) = anthropicGET("/v1/code/triggers", token: token,
                                              extraHeaders: routineAPIHeaders)
    if let netErr = netErr { return (nil, netErr) }
    guard status == 200 else {
        return (nil, status == 401 ? L("要再認証（claude を起動）", "re-auth needed (run claude)") : "HTTP \(status)")
    }
    guard var routines = parseTriggers(body.flatMap({ try? JSONSerialization.jsonObject(with: $0) }))
    else { return (nil, L("形式が不明", "unexpected shape")) }
    let carried = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // One sessions call per routine, run in parallel like fetchAgents does its rows: sequentially
    // these were N × the request timeout, so a single unreachable endpoint delayed every routine
    // behind it. Each iteration writes its own slot; the lock guards only the shared array.
    let targets = routines.indices.filter { routineNeedsSessionPass(routines[$0]) }
    var results = [Int: (state: String?, sessionId: String?, stale: Bool)]()
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: targets.count) { slot in
        let i = targets[slot]
        // The id comes from the server; encode it rather than trusting it to be URL-safe.
        let id = routines[i].id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? routines[i].id
        let (s, b, _) = anthropicGET("/v1/code/sessions?trigger_id=\(id)", token: token,
                                     extraHeaders: routineAPIHeaders, timeout: 10)
        let rows = s == 200
            ? parseRoutineSessions(b.flatMap({ try? JSONSerialization.jsonObject(with: $0) }))
            : nil
        let live = routineCarriedState(rows: rows, lastRunSessionId: routines[i].lastRun?.sessionId,
                                       previous: carried[routines[i].id])
        lock.lock()
        results[i] = live
        lock.unlock()
    }
    for (i, live) in results {
        routines[i].liveState = live.state
        routines[i].liveSessionId = live.sessionId
        routines[i].liveStale = live.stale
    }
    // Individual failures dim their own row (liveStale). The section-wide message is for the case
    // where nothing at all could be confirmed.
    let failures = results.values.filter { $0.stale }.count
    return (routines, !targets.isEmpty && failures == targets.count
            ? L("実行状況を取得できません", "run states unavailable") : nil)
}
