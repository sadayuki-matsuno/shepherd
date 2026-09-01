import Foundation

// Routines.swift — parsing of the triggers / sessions endpoints and the pure row logic on top.
// The fixtures mirror the live response shape measured 2026-09-01 (field names, the 9-digit
// fractional seconds, ROUTINE_RUN_STATUS_* spellings) with invented names and ids.

private func json(_ s: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(s.utf8))
}

private let triggersFixture = """
{"has_more": false, "data": [
  {"id": "trig_01AaaBbbCccDddEeeFffGgg",
   "name": "morning-digest",
   "enabled": true,
   "cron_expression": "0 0 * * *",
   "next_run_at": "2026-09-02T00:08:57.992834671Z",
   "last_fired_at": "2026-09-01T00:15:24.842679Z",
   "created_at": "2026-08-01T10:00:00Z",
   "job_config": {"prompt": "…"},
   "last_run": {"status": "ROUTINE_RUN_STATUS_SUCCEEDED",
                "session_id": "cse_01HhhIiiJjjKkkLllMmmNnn",
                "fired_at": "2026-09-01T00:15:24.842679Z",
                "finished_at": "2026-09-01T00:19:02.101Z"}},
  {"id": "trig_01OooPppQqqRrrSssTttUuu",
   "name": "weekly-report",
   "enabled": false,
   "next_run_at": "2026-09-03T22:01:07.531638863Z",
   "last_run": {"status": "ROUTINE_RUN_STATUS_PENDING",
                "session_id": "cse_01VvvWwwXxxYyyZzzAaaBbb",
                "fired_at": "2026-09-01T05:03:34.811215Z"}}
]}
"""

func runRoutinesTests() {
    test("parseTriggers — live shape") {
        guard let routines = parseTriggers(json(triggersFixture)) else {
            return expect(false, "fixture should parse")
        }
        expectEq(routines.count, 2, "routine count")
        let first = routines[0]
        expectEq(first.id, "trig_01AaaBbbCccDddEeeFffGgg", "id")
        expectEq(first.name, "morning-digest", "name")
        expect(first.enabled, "enabled: true")
        expectEq(first.cronExpression, "0 0 * * *", "cron")
        // 9 fractional digits — ISO8601DateFormatter handles them (verified 2026-09-01), so a
        // next-run stamp must never come back nil for a live record.
        expect(first.nextRunAt != nil, "next_run_at parses despite 9 fractional digits")
        expect(first.lastFiredAt != nil, "last_fired_at parses")
        expectEq(first.lastRun?.status, "ROUTINE_RUN_STATUS_SUCCEEDED", "last run status")
        expectEq(first.lastRun?.sessionId, "cse_01HhhIiiJjjKkkLllMmmNnn", "last run session")
        expect(first.lastRun?.finishedAt != nil, "finished_at parses")
        // Live state is the sessions pass's business; the triggers parse must not invent one.
        expectNil(first.liveState, "liveState unset before the sessions pass")

        let second = routines[1]
        expect(!second.enabled, "enabled: false")
        expectNil(second.cronExpression, "a run-once routine carries no cron expression")
    }

    test("parseTriggers — defensive") {
        // A present-but-empty list is a real answer; a surprise is not. Collapsing the two would
        // render a 404 body as a confident "ROUTINES — 0".
        expectEq(parseTriggers(json(#"{"data": []}"#))?.count, 0, "empty data[] parses to []")
        expectNil(parseTriggers(json(#"{"error": {"message": "not found"}}"#)), "error body → nil")
        expectNil(parseTriggers(json("[1, 2, 3]")), "array of scalars → nil")
        expectNil(parseTriggers(nil), "nil input → nil")
        expectNil(parseTriggers("plain string"), "non-JSON object → nil")
        // Rows without an id are skipped, not fatal (additive parsing).
        expectEq(parseTriggers(json(#"{"data": [{"name": "no id"}, {"id": "trig_x"}]}"#))?.count, 1,
                 "id-less rows are skipped")
        // An unknown `enabled` must read as enabled — an unclassifiable routine shouldn't arrive
        // pre-dimmed as though the user had switched it off.
        expect(parseTriggers(json(#"{"data": [{"id": "trig_x"}]}"#))?.first?.enabled == true,
               "missing enabled defaults to true")
        expectEq(parseTriggers(json(#"{"data": [{"id": "trig_x"}]}"#))?.first?.name, "trig_x",
                 "a nameless routine falls back to its id")
    }

    test("parseRoutineSessions") {
        let rows = parseRoutineSessions(json("""
        {"resume_token": "rt_1", "data": [
          {"id": "cse_01Aaa", "status": "active", "worker_status": "requires_action", "title": "⚡ x"},
          {"id": "cse_01Bbb", "status": "active", "worker_status": "idle"},
          {"id": "cse_01Ccc", "status": "active"}
        ]}
        """))
        expectEq(rows?.count, 3, "row count")
        expectEq(rows?[0].workerStatus, "requires_action", "worker_status")
        expectNil(rows?[2].workerStatus, "absent worker_status stays nil")
        expectNil(parseRoutineSessions(json(#"{"detail": "nope"}"#)), "unexpected shape → nil")
    }

    test("routineLiveState") {
        let waiting = RoutineSessionRow(id: "cse_wait", workerStatus: "requires_action")
        let running = RoutineSessionRow(id: "cse_last", workerStatus: "running")
        let idle = RoutineSessionRow(id: "cse_old", workerStatus: "idle")

        // No rows at all means "unknown", never "idle" — a failed sessions call must not paint a
        // routine as quiet.
        expectNil(routineLiveState(rows: [], lastRunSessionId: "cse_last").map { $0.state },
                  "no rows → nil")

        // An unanswered prompt wins over everything and lends its own session to the click.
        let a = routineLiveState(rows: [idle, waiting, running], lastRunSessionId: "cse_last")
        expectEq(a?.state, "requires_action", "requires_action outranks running")
        expectEq(a?.sessionId, "cse_wait", "click target is the run that is asking")

        let b = routineLiveState(rows: [idle, running], lastRunSessionId: "cse_last")
        expectEq(b?.state, "running", "the last run's own session may be running")
        expectEq(b?.sessionId, "cse_last", "click target is that run")

        // A stale older session stuck mid-turn must not make the routine look busy today.
        let stale = RoutineSessionRow(id: "cse_ancient", workerStatus: "running")
        let c = routineLiveState(rows: [stale, idle], lastRunSessionId: "cse_last")
        expectEq(c?.state, "idle", "a running row that isn't the last run doesn't count")
        expectEq(c?.sessionId, "cse_last", "idle still opens the last run")

        let d = routineLiveState(rows: [idle], lastRunSessionId: nil)
        expectEq(d?.sessionId, "cse_old", "no last run → fall back to the first row")
    }

    test("routineSessionURL") {
        expectEq(routineSessionURL("cse_01UcdC2NRB6BWXXA6TwqCGPL"),
                 "https://claude.ai/code/session_01UcdC2NRB6BWXXA6TwqCGPL", "cse_ → session_")
        expectNil(routineSessionURL(nil), "nil id")
        expectNil(routineSessionURL("trig_01Aaa"), "a trigger id is not a session")
        expectNil(routineSessionURL(""), "empty id")
    }

    test("routineRunKind") {
        expectEq(routineRunKind("ROUTINE_RUN_STATUS_SUCCEEDED"), "succeeded", "succeeded")
        expectEq(routineRunKind("ROUTINE_RUN_STATUS_PENDING"), "pending", "pending")
        // FAILED-family spellings were never observed; matching on the substring means the real
        // one renders as a failure whatever it turns out to be called.
        expectEq(routineRunKind("ROUTINE_RUN_STATUS_FAILED"), "failed", "failed")
        expectEq(routineRunKind("ROUTINE_RUN_STATUS_ERRORED"), "failed", "errored")
        expectEq(routineRunKind("ROUTINE_RUN_STATUS_CANCELLED"), "cancelled", "cancelled")
        expectNil(routineRunKind("ROUTINE_RUN_STATUS_SOMETHING_NEW"), "unknown → no mark")
        expectNil(routineRunKind(nil), "nil → no mark")
        expectNil(routineRunKind(""), "empty → no mark")
    }

    test("routineNextRunText") {
        // Timezone passed explicitly: a local-format expectation would pass here and fail on a
        // machine set to another zone.
        let d = parseUsageISODate("2026-09-02T00:08:57.992834671Z")
        expectEq(routineNextRunText(d, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "9/2 09:08", "JST")
        expectEq(routineNextRunText(d, timeZone: TimeZone(identifier: "UTC")!), "9/2 00:08", "UTC")
        expectNil(routineNextRunText(nil), "no date → no stamp")
    }

    test("routineCarriedState — a failed sessions call keeps what we knew") {
        let waiting = Routine(id: "trig_x", name: "x", enabled: true, cronExpression: nil,
                              nextRunAt: nil, lastFiredAt: nil, lastRun: nil,
                              liveState: "requires_action", liveSessionId: "cse_wait")
        // The failure case this exists for: losing the state would quietly clear an approval
        // prompt that is still sitting there unanswered.
        let kept = routineCarriedState(rows: nil, lastRunSessionId: "cse_last", previous: waiting)
        expectEq(kept.state, "requires_action", "nil rows carry the previous state")
        expectEq(kept.sessionId, "cse_wait", "and the previous click target")

        // An empty list is as uninformative as a failure — same carry.
        let empty = routineCarriedState(rows: [], lastRunSessionId: "cse_last", previous: waiting)
        expectEq(empty.state, "requires_action", "empty rows carry too")

        // Fresh rows always win over the carry, including when they say the prompt is gone.
        let fresh = routineCarriedState(rows: [RoutineSessionRow(id: "cse_last", workerStatus: "idle")],
                                        lastRunSessionId: "cse_last", previous: waiting)
        expectEq(fresh.state, "idle", "live rows override the carry")
        expectEq(fresh.sessionId, "cse_last", "and its click target")

        // Nothing known and nothing carried stays unknown — never a confident "idle".
        let unknown = routineCarriedState(rows: nil, lastRunSessionId: "cse_last", previous: nil)
        expectNil(unknown.state, "no rows and no history → still unknown")
        expectNil(unknown.sessionId, "and no click target from thin air")
    }

    test("routineNeedsSessionPass") {
        func routine(enabled: Bool, lastStatus: String?) -> Routine {
            Routine(id: "trig_x", name: "x", enabled: enabled, cronExpression: nil, nextRunAt: nil,
                    lastFiredAt: nil,
                    lastRun: lastStatus.map { RoutineRun(status: $0, sessionId: "cse_x",
                                                         firedAt: nil, finishedAt: nil) })
        }
        expect(routineNeedsSessionPass(routine(enabled: true, lastStatus: nil)),
               "an enabled routine is always asked about")
        expect(routineNeedsSessionPass(routine(enabled: true, lastStatus: "ROUTINE_RUN_STATUS_SUCCEEDED")),
               "enabled + finished still asked — SUCCEEDED doesn't mean the session ended")
        // A run that started before the routine was switched off can still be sitting at a
        // permission prompt; skipping it would bury the state the section exists to surface.
        expect(routineNeedsSessionPass(routine(enabled: false, lastStatus: "ROUTINE_RUN_STATUS_PENDING")),
               "disabled with a run still pending IS asked about")
        expect(!routineNeedsSessionPass(routine(enabled: false, lastStatus: "ROUTINE_RUN_STATUS_SUCCEEDED")),
               "disabled with a finished run is skipped")
        expect(!routineNeedsSessionPass(routine(enabled: false, lastStatus: nil)),
               "disabled and never run is skipped")
    }

    test("fakeActionRoutines — staged capture data") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staged = fakeActionRoutines(now: now)
        expectEq(staged.filter { $0.liveState == "requires_action" }.count, 1,
                 "exactly one routine stages the approval state")
        expect(staged.count > 1, "and at least one ordinary row for contrast")
        expect(staged.allSatisfy { $0.nextRunAt != nil }, "every staged row has a schedule to show")
        // The demo board must never carry a real account's names or ids.
        expect(staged.allSatisfy { $0.id.hasPrefix("trig_demo") }, "ids are visibly fictional")
        expect(routineSessionURL(staged[0].liveSessionId) != nil, "the staged row is still clickable")
    }

    test("routineListOrder") {
        func routine(_ name: String, enabled: Bool = true, next: TimeInterval?,
                     live: String? = nil) -> Routine {
            Routine(id: "trig_" + name, name: name, enabled: enabled, cronExpression: nil,
                    nextRunAt: next.map { Date(timeIntervalSince1970: $0) }, lastFiredAt: nil,
                    lastRun: nil, liveState: live, liveSessionId: nil)
        }
        let order = routineListOrder([
            routine("soon", next: 100),
            routine("off", enabled: false, next: 50),
            routine("later", next: 300),
            routine("waiting", next: 900, live: "requires_action"),
            routine("never", next: nil),
        ]).map { $0.name }
        expectEq(order, ["waiting", "soon", "later", "never", "off"], "approval → live → soonest")

        // A disabled routine waiting on approval still comes first: the prompt is unanswered
        // whatever the schedule now says.
        let stopped = routineListOrder([
            routine("soon", next: 100),
            routine("off-waiting", enabled: false, next: nil, live: "requires_action"),
        ]).map { $0.name }
        expectEq(stopped, ["off-waiting", "soon"], "approval outranks enabled")

        expectEq(routineListOrder([]).count, 0, "empty list")
    }
}
