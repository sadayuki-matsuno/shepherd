import Foundation

// Fixture factory: only the fields a test cares about vary; the rest take neutral defaults.
func makeRow(sessionId: String = "", status: String = "idle",
             label: String = "", cwd: String = "", repoKey: String? = nil, repoName: String? = nil,
             changedFiles: Int? = nil, backend: Backend = .other,
             statusSince: Date = Date.distantPast, parentSessionId: String? = nil,
             startedAt: Date? = nil, forkKey: String? = nil, isFork: Bool = false,
             isBackground: Bool = false, pid: Int32? = nil, isWorktree: Bool = false) -> AgentRow {
    AgentRow(sessionId: sessionId, model: nil, contextPct: nil,
             status: status, label: label, cwd: cwd, dirName: "", dirPath: "",
             branch: nil, changedFiles: changedFiles, issueNo: nil, prNo: nil, prUrl: nil, ciState: nil,
             repoKey: repoKey, repoName: repoName, isWorktree: isWorktree, activity: nil, links: [],
             statusSince: statusSince, backend: backend, zellijSession: nil,
             zellijPaneId: nil, stale: false,
             parentSessionId: parentSessionId, subagents: [], zellijSendable: false,
             updatedAt: nil, lastMessage: nil, startedAt: startedAt, forkKey: forkKey, isFork: isFork,
             isBackground: isBackground, pid: pid)
}

// A reduced `claude agents --json --all` payload, field-for-field as measured on 2026-07-09
// (claude 2.1.205): an interactive session carries pid+status, a live background worker carries
// pid+status+state, and a stopped background record carries only state.
let claudeAgentsFixture: [[String: Any]] = [
    ["pid": 13852, "cwd": "/x/roid_senpai", "kind": "interactive", "startedAt": 1783170439690,
     "sessionId": "847e22de-00b3-4c77-98fe-4e53cedebbc4", "name": "roid-senpai-1f", "status": "idle"],
    ["pid": 37200, "id": "f0415bb1", "cwd": "/x/throwaway", "kind": "background", "startedAt": 1783598751724,
     "sessionId": "f0415bb1-24b8-4c16-a210-8cd0ef35d7a5", "name": "sleep then reply",
     "status": "busy", "state": "working"],
    ["id": "1b6c4535", "cwd": "/x/party-game", "kind": "background", "startedAt": 1782571963594,
     "sessionId": "1b6c4535-1111-2222-3333-444444444444", "name": "バトルシップ観戦時のマーキング表示改善",
     "state": "done"],
    ["kind": "interactive", "pid": 999],   // no sessionId — unusable, dropped
]

// A `{"proto":1,"op":"list"}` reply from cc-daemon's control socket, field-for-field as measured on
// 2026-07-09 (claude 2.1.205). Note `detail`/`intent` come back as "" rather than being omitted, and
// only a blocked worker carries `needs`.
let daemonListFixture: [[String: Any]] = [
    ["short": "53d154ed", "nonce": "47fee446", "sessionId": "53d154ed-ec6a-4435-aa31-8646f9681120",
     "pid": 75447, "attempt": 1, "startedAt": 1783600747149, "cwd": "/x/sandbox", "backend": "daemon",
     "tempo": "active", "state": "running", "detail": "", "intent": "", "cliVersion": "2.1.205",
     "source": "shell"],
    ["short": "7ef1f785", "nonce": "ea105490", "sessionId": "7ef1f785-2a94-4f47-b41b-75e9b9191d4a",
     "pid": 75469, "attempt": 1, "startedAt": 1783600760705, "cwd": "/x/battleship", "backend": "daemon",
     "tempo": "blocked", "state": "blocked", "detail": "marking UI clarification — awaiting direction",
     "intent": "", "name": "marking clarity improvement", "agent": "claude", "cliVersion": "2.1.205",
     "source": "fleet",
     "needs": "confirm desired marking style (thicker ring, overlay marker, label) or provide direction"],
    ["short": "nosession", "state": "running"],   // no sessionId — unusable, dropped
]

func runModelsTests() {
    test("modelInfo") {
        expectEq(modelInfo(from: "claude-fable-5")?.name, "FABLE")
        expectEq(modelInfo(from: "claude-opus-4-8")?.name, "OPUS")
        expectEq(modelInfo(from: "claude-sonnet-5")?.name, "SONNET")
        expectEq(modelInfo(from: "claude-haiku-4-5-20251001")?.name, "HAIKU")
        expectEq(modelInfo(from: "CLAUDE-FABLE-5")?.name, "FABLE", "case-insensitive")
        expectNil(modelInfo(from: "gpt-4"), "unknown model")
        expectNil(modelInfo(from: ""), "empty")
    }

    test("permissionModeChip") {
        expectNil(permissionModeChip(nil), "no mode recorded")
        expectNil(permissionModeChip("default"), "default mode shows nothing")
        expectEq(permissionModeChip("plan")?.label, "PLAN")
        expectEq(permissionModeChip("acceptEdits")?.label, "⏵⏵ EDITS")
        expectEq(permissionModeChip("dontAsk")?.label, "⏵⏵ NO-ASK")
        expectEq(permissionModeChip("bypassPermissions")?.label, "BYPASS")
        expectEq(permissionModeChip("futureMode")?.label, "FUTUREMODE", "unknown mode passes through")
    }

    test("promptTitle") {
        expectNil(promptTitle(nil))
        expectNil(promptTitle(""))
        expectNil(promptTitle("   \n "))
        expectNil(promptTitle("<task-notification>agent finished"), "machine notification")
        expectEq(promptTitle("  fix the bug  "), "fix the bug", "trims")
    }

    test("formatDuration") {
        expectEq(formatDuration(0), L("0秒", "0s"))
        expectEq(formatDuration(-5), L("0秒", "0s"), "negative clamps to 0")
        expectEq(formatDuration(59), L("59秒", "59s"))
        expectEq(formatDuration(60), L("1分", "1m"))
        expectEq(formatDuration(3599), L("59分", "59m"))
        expectEq(formatDuration(3600), L("1時間", "1h"))
        expectEq(formatDuration(5400), L("1時間30分", "1h30m"))
        expectEq(formatDuration(7200), L("2時間", "2h"), "whole hours drop minutes")
    }

    test("style ordering") {
        expectEq(style(for: "error").order, 0)
        expectEq(style(for: "blocked").order, 0)
        expectEq(style(for: "working").order, 1)
        expectEq(style(for: "idle").order, 3)
        expectEq(style(for: "whatever").order, 4, "unknown status ranks last")
        expectEq(style(for: "blocked").word, L("応答待ち", "needs input"))
    }

    test("groupByRepo: grouping and headers") {
        let rows = [
            makeRow(sessionId: "a", status: "working", label: "a", repoKey: "K", repoName: "shepherd"),
            makeRow(sessionId: "solo", status: "idle", label: "solo"),
            makeRow(sessionId: "b", status: "blocked", label: "b", repoKey: "K", repoName: "shepherd"),
        ]
        let sections = groupByRepo(rows)
        expectEq(sections.count, 2, "one repo group + the shared other section")
        let repo = sections.first { $0.header == "shepherd" }
        expect(repo != nil, "repo section exists")
        expectEq(repo?.rows.count, 2, "both worktree rows land in it")
        expectEq(repo?.rows.first?.sessionId, "b", "blocked sorts before working within a group")
        let other = sections.first { $0.header == nil }
        expectEq(other?.rows.map { $0.sessionId }, ["solo"], "the repo-less row has no header")
    }

    test("groupByRepo: every repo-less row shares ONE headerless section") {
        let rows = [
            makeRow(sessionId: "rec1", status: "idle", label: "scratch"),
            makeRow(sessionId: "k", status: "working", label: "k", repoKey: "K", repoName: "shepherd"),
            makeRow(sessionId: "rec2", status: "idle", label: "tmp"),
            makeRow(sessionId: "rec3", status: "blocked", label: "bare"),
        ]
        let sections = groupByRepo(rows)
        expectEq(sections.count, 2, "not one column per homeless row (2026-07-10)")
        let other = sections.first { $0.header == nil }
        expectEq(other?.rows.map { $0.sessionId }, ["rec3", "rec1", "rec2"],
                 "all three together, ranked by urgency inside the section")
        expectEq(other.map(repoGroupKey), "other", "and it keys on a constant, so pins/folds survive membership changes")
    }

    test("groupByRepo: section order by most-urgent status") {
        let rows = [
            makeRow(sessionId: "d", status: "idle", label: "d", repoKey: "R1", repoName: "r1"),
            makeRow(sessionId: "x", status: "blocked", label: "x", repoKey: "R2", repoName: "r2"),
        ]
        let sections = groupByRepo(rows)
        expectEq(sections.first?.header, "r2", "section containing blocked comes first")
    }

    test("groupByRepo: ties break on newest statusSince") {
        let old = Date(timeIntervalSinceNow: -1000), new = Date()
        let rows = [
            makeRow(sessionId: "o", status: "working", label: "o", repoKey: "R1", repoName: "r-old", statusSince: old),
            makeRow(sessionId: "n", status: "working", label: "n", repoKey: "R2", repoName: "r-new", statusSince: new),
        ]
        expectEq(groupByRepo(rows).first?.header, "r-new", "most recently changed group first")
    }

    test("groupByRepo: header sticks to the main checkout, not the top-ranked worktree row") {
        // gitFacts names a worktree row after its worktree DIRECTORY (`shepherd-main-fix`), so
        // before 2026-07-11 a busy child in a worktree renamed the whole column to its own name.
        let rows = [
            makeRow(sessionId: "main", status: "idle", label: "main",
                    repoKey: "/x/shepherd/.git", repoName: "shepherd"),
            makeRow(sessionId: "child", status: "working", label: "child",
                    repoKey: "/x/shepherd/.git", repoName: "shepherd-main-fix", isWorktree: true),
        ]
        let sections = groupByRepo(rows)
        expectEq(sections.count, 1, "worktrees share the repo's column")
        expectEq(sections.first?.rows.first?.sessionId, "child", "the busy worktree still ranks first")
        expectEq(sections.first?.header, "shepherd", "but the column keeps the repo's name")
    }

    test("groupByRepo: a repoName-less child can't blank the column header") {
        // A child session in a non-repo cwd joins its parent's column through the adopted repoKey
        // (AgentFetch's child→repoKey pass) but carries no repoName of its own. Blocked, it ranked
        // first and named the column nil → "その他" (2026-07-11, the VSCode probe sessions).
        let rows = [
            makeRow(sessionId: "main", status: "idle", label: "main",
                    repoKey: "/x/shepherd/.git", repoName: "shepherd"),
            makeRow(sessionId: "probe", status: "blocked", label: "probe",
                    repoKey: "/x/shepherd/.git"),
        ]
        let sections = groupByRepo(rows)
        expectEq(sections.count, 1, "the adopted repoKey keeps the child in the repo's column")
        expectEq(sections.first?.rows.first?.sessionId, "probe", "the blocked child still ranks first")
        expectEq(sections.first?.header, "shepherd", "but the column keeps the repo's name")
    }

    test("groupByRepo: a section with only nameless rows falls back to the common-dir key") {
        let rows = [
            makeRow(sessionId: "probe", status: "blocked", label: "probe",
                    repoKey: "/x/shepherd/.git"),
        ]
        expectEq(groupByRepo(rows).first?.header, "shepherd",
                 "a named header still beats nil when every row lacks a repoName")
    }

    test("groupByRepo: all-worktree group derives its header from the shared .git key") {
        let rows = [
            makeRow(sessionId: "w1", status: "working", label: "w1",
                    repoKey: "/x/shepherd/.git", repoName: "shepherd-main-a", isWorktree: true),
            makeRow(sessionId: "w2", status: "idle", label: "w2",
                    repoKey: "/x/shepherd/.git", repoName: "shepherd-main-b", isWorktree: true),
        ]
        expectEq(groupByRepo(rows).first?.header, "shepherd", "common-dir parent names the column")
    }

    test("treeOrder: children nest under parents") {
        let rows = [
            makeRow(sessionId: "p", label: "p"),
            makeRow(sessionId: "c", label: "c", parentSessionId: "p"),
            makeRow(sessionId: "g", label: "g", parentSessionId: "c"),
        ]
        let out = treeOrder(rows)
        expectEq(out.map { $0.row.sessionId }, ["p", "c", "g"])
        expectEq(out.map { $0.depth }, [0, 1, 2])
    }

    test("treeOrder: depth is capped at 3") {
        let rows = (0...4).map { i in
            makeRow(sessionId: "n\(i)", label: "n\(i)", parentSessionId: i == 0 ? nil : "n\(i-1)")
        }
        let out = treeOrder(rows)
        expectEq(out.count, 5, "every row is emitted exactly once")
        expectEq(out.map { $0.depth }.max(), 3, "no depth beyond 3")
        expectEq(Set(out.map { $0.row.sessionId }).count, 5, "no duplicates")
    }

    test("treeOrder: cycles don't loop or drop rows") {
        let rows = [
            makeRow(sessionId: "a", label: "a", parentSessionId: "b"),
            makeRow(sessionId: "b", label: "b", parentSessionId: "a"),
        ]
        let out = treeOrder(rows)
        expectEq(out.count, 2, "both rows survive a parent cycle")
        expectEq(Set(out.map { $0.row.sessionId }), Set(["a", "b"]))
    }

    test("linkForks: sessions sharing a first-message fingerprint become forks of the earliest") {
        let t0 = Date(timeIntervalSince1970: 1000)   // root (earliest)
        let t1 = Date(timeIntervalSince1970: 2000)
        let t2 = Date(timeIntervalSince1970: 3000)
        let fp = "2026-07-05T18:55:33.558Z"   // the copied first user message's timestamp
        let rows = [
            makeRow(sessionId: "fork-late", cwd: "/p", startedAt: t2, forkKey: fp),
            makeRow(sessionId: "root", cwd: "/p", startedAt: t0, forkKey: fp),
            makeRow(sessionId: "fork-mid", cwd: "/p", startedAt: t1, forkKey: fp),
        ]
        let out = linkForks(rows)
        func row(_ id: String) -> AgentRow { out.first { $0.sessionId == id }! }
        expect(!row("root").isFork, "earliest is the root, not a fork")
        expectNil(row("root").parentSessionId, "root keeps no parent")
        expect(row("fork-mid").isFork && row("fork-late").isFork, "the later two are forks")
        expectEq(row("fork-mid").parentSessionId, "root", "fork points at the root session")
        expectEq(row("fork-late").parentSessionId, "root")
    }

    test("linkForks: different cwd, different fingerprint, or no fingerprint are never merged") {
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        let fp = "2026-07-05T18:55:33.558Z"
        let rows = [
            makeRow(sessionId: "a", cwd: "/p", startedAt: t0, forkKey: fp),
            makeRow(sessionId: "b-other-cwd", cwd: "/p/sub", startedAt: t1, forkKey: fp),   // same fp, different cwd
            makeRow(sessionId: "c-other-fp", cwd: "/p", startedAt: t1, forkKey: "different"),
            makeRow(sessionId: "d-no-fp", cwd: "/p", startedAt: t1),   // no transcript → no fingerprint
        ]
        let out = linkForks(rows)
        expect(out.allSatisfy { !$0.isFork }, "each session is alone in its (cwd, fingerprint) group")
    }

    test("linkForks: a real child session (different fingerprint) is not turned into a fork") {
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        let rows = [
            makeRow(sessionId: "root", cwd: "/p", startedAt: t0, forkKey: "fp-root"),
            makeRow(sessionId: "child", cwd: "/p", parentSessionId: "root", startedAt: t1, forkKey: "fp-child"),
        ]
        let out = linkForks(rows)
        expect(!out.first { $0.sessionId == "child" }!.isFork, "a genuine child keeps its normal child status")
    }

    test("treeOrder: fork children are emitted before normal children") {
        let rows = [
            makeRow(sessionId: "p", label: "p"),
            makeRow(sessionId: "c", label: "c", parentSessionId: "p"),
            makeRow(sessionId: "f", label: "f", parentSessionId: "p", isFork: true),
        ]
        let out = treeOrder(rows)
        expectEq(out.map { $0.row.sessionId }, ["p", "f", "c"], "the fork sorts to the top of the children")
        expectEq(out.map { $0.depth }, [0, 1, 1])
    }

    test("treeOrder: self-parent and unknown parent are roots") {
        let rows = [
            makeRow(sessionId: "s", label: "s", parentSessionId: "s"),
            makeRow(sessionId: "u", label: "u", parentSessionId: "not-here"),
        ]
        let out = treeOrder(rows)
        expectEq(out.map { $0.depth }, [0, 0])
    }

    test("hudSizeMode: raw values round-trip / unknown falls back at the call site") {
        expectEq(HUDSizeMode(rawValue: "auto"), .auto)
        expectEq(HUDSizeMode(rawValue: "small"), .small)
        expectEq(HUDSizeMode(rawValue: "medium"), .medium)
        expectEq(HUDSizeMode(rawValue: "large"), .large)
        expectEq(HUDSizeMode(rawValue: "fullDisplay"), .fullDisplay)
        expectNil(HUDSizeMode(rawValue: "huge"), "unknown raw value")
    }

    test("hudPreset: fixed presets are 1/2/3 columns; auto and fullDisplay have none") {
        expectEq(hudPreset(.small)?.columns, 1)
        expectEq(hudPreset(.medium)?.columns, 2)
        expectEq(hudPreset(.large)?.columns, 3)
        expect(hudPreset(.small)!.height < hudPreset(.medium)!.height, "heights grow with size")
        expect(hudPreset(.medium)!.height < hudPreset(.large)!.height, "heights grow with size")
        expectNil(hudPreset(.auto), "auto tracks content")
        expectNil(hudPreset(.fullDisplay), "fullDisplay tracks the screen")
    }

    test("hudPanelWidth: side padding + N columns + (N-1) gaps") {
        expectEq(hudPanelWidth(columns: 1, columnWidth: 268, gap: 12, sidePadding: 12), 292)
        expectEq(hudPanelWidth(columns: 2, columnWidth: 268, gap: 12, sidePadding: 12), 572)
        expectEq(hudPanelWidth(columns: 3, columnWidth: 268, gap: 12, sidePadding: 12), 852)
    }

    test("hudFitColumns: how many columns fit a panel width, never below 1") {
        expectEq(hudFitColumns(panelWidth: 292, columnWidth: 268, gap: 12, sidePadding: 12), 1)
        expectEq(hudFitColumns(panelWidth: 571, columnWidth: 268, gap: 12, sidePadding: 12), 1)
        expectEq(hudFitColumns(panelWidth: 572, columnWidth: 268, gap: 12, sidePadding: 12), 2)
        expectEq(hudFitColumns(panelWidth: 851, columnWidth: 268, gap: 12, sidePadding: 12), 2)
        expectEq(hudFitColumns(panelWidth: 852, columnWidth: 268, gap: 12, sidePadding: 12), 3)
        expectEq(hudFitColumns(panelWidth: 1920, columnWidth: 268, gap: 12, sidePadding: 12), 6)
        expectEq(hudFitColumns(panelWidth: 100, columnWidth: 268, gap: 12, sidePadding: 12), 1, "tiny width clamps to 1")
        expectEq(hudFitColumns(panelWidth: 0, columnWidth: 268, gap: 12, sidePadding: 12), 1, "zero clamps to 1")
    }

    test("shortSessionId: the first UUID segment is the agent-view / `claude stop` id") {
        expectEq(shortSessionId("99678571-c5b8-4452-97c0-b7db4aac822b"), "99678571")
        expectEq(shortSessionId("nodashes"), "nodashes", "no dash — the whole string")
        expectEq(shortSessionId(""), "", "empty stays empty")
    }

    test("parseClaudeAgents: every kind's fields, ms epoch, and the unusable entry") {
        let es = parseClaudeAgents(claudeAgentsFixture)
        expectEq(es.count, 3, "the entry without a sessionId is dropped")

        let interactive = es[0]
        expectEq(interactive.sessionId, "847e22de-00b3-4c77-98fe-4e53cedebbc4")
        expectEq(interactive.shortId, "847e22de", "no `id` field — the UUID's first segment")
        expectEq(interactive.isBackground, false)
        expectEq(interactive.pid, 13852)
        expectEq(interactive.rawStatus, "idle")
        expectNil(interactive.rawState, "interactive sessions carry no job state")
        expectNil(interactive.aiTitle, "an interactive `name` is a session name, not a work title")
        expectEq(interactive.startedAt, Date(timeIntervalSince1970: 1783170439.690), "ms epoch → Date")

        let worker = es[1]
        expectEq(worker.shortId, "f0415bb1", "the `id` field wins")
        expectEq(worker.isBackground, true)
        expectEq(worker.pid, 37200, "a LIVE background worker does have a pid")
        expectEq(worker.rawStatus, "busy")
        expectEq(worker.rawState, "working")
        expectEq(worker.aiTitle, "sleep then reply", "a background `name` is the AI-generated title")
        expectEq(worker.cwd, "/x/throwaway")

        let record = es[2]
        expectEq(record.shortId, "1b6c4535")
        expectEq(record.isBackground, true)
        expectNil(record.pid, "a stopped background record has no process")
        expectNil(record.rawStatus)
        expectEq(record.rawState, "done")
    }

    test("statusFromClaudeAgent: state (job lifecycle) wins over status (process activity)") {
        func entry(status: String? = nil, state: String? = nil) -> ClaudeAgentEntry {
            ClaudeAgentEntry(sessionId: "s", shortId: "s", isBackground: true, pid: nil,
                             rawStatus: status, rawState: state, name: nil, cwd: "", startedAt: nil)
        }
        expectEq(statusFromClaudeAgent(entry(status: "busy")), "working", "interactive busy")
        expectEq(statusFromClaudeAgent(entry(status: "idle")), "idle", "interactive idle")
        expectEq(statusFromClaudeAgent(entry(state: "working")), "working", "measured background state")
        expectEq(statusFromClaudeAgent(entry(state: "done")), "idle",
                 "a finished job is simply not working — Shepherd has no separate done state")
        expectEq(statusFromClaudeAgent(entry(state: "running")), "working", "defensive: a plausible synonym")
        expectEq(statusFromClaudeAgent(entry(state: "failed")), "error")
        expectEq(statusFromClaudeAgent(entry(status: "idle", state: "done")), "idle",
                 "a worker that just finished its turn reports idle+done")
        expectEq(statusFromClaudeAgent(entry(status: "busy", state: "working")), "working")
        expectEq(statusFromClaudeAgent(entry(state: "quiesced")), "quiesced", "an unknown word passes through")
        expectEq(statusFromClaudeAgent(entry()), "unknown", "nothing to go on")
    }

    test("parseDaemonJobs: the control socket's live-worker list, empty strings normalised away") {
        let jobs = parseDaemonJobs(daemonListFixture)
        expectEq(jobs.count, 2, "the malformed third entry is dropped")

        let running = jobs[0]
        expectEq(running.short, "53d154ed")
        expectEq(running.sessionId, "53d154ed-ec6a-4435-aa31-8646f9681120")
        expectEq(running.state, "running")
        expectNil(running.detail, "the daemon writes \"\" for a field it has nothing for")
        expectNil(running.needs, "a running worker needs nothing")

        let blocked = jobs[1]
        expectEq(blocked.short, "7ef1f785")
        expectEq(blocked.state, "blocked")
        expectEq(blocked.detail, "marking UI clarification — awaiting direction")
        expectEq(blocked.needs, "confirm desired marking style (thicker ring, overlay marker, label) or provide direction")
        expectEq(blocked.name, "marking clarity improvement")
    }

    test("envFacts: a hook-less session's env supplies its home and its parent") {
        let env = ["ZELLIJ_SESSION_NAME": "implacable-cactus", "ZELLIJ_PANE_ID": "60",
                   "SHEPHERD_PARENT_SESSION_ID": "aaaa-bbbb", "PATH": "/usr/bin"]
        let interactive = envFacts(env, isBackground: false)
        expectEq(interactive.zellijSession, "implacable-cactus")
        expectEq(interactive.zellijPaneId, "60")
        expectEq(interactive.parentSessionId, "aaaa-bbbb")

        // A worker inherits the env of whatever pane ran `claude --bg`, so those zellij vars name the
        // SPAWNER's pane. Honouring them turned the card's click into a jump to that pane (2026-07-10).
        let worker = envFacts(env, isBackground: true)
        expectNil(worker.zellijSession, "a background worker has no terminal of its own")
        expectNil(worker.zellijPaneId, "nor a pane of its own")
        expectEq(worker.parentSessionId, "aaaa-bbbb", "but its parent id is still honest")

        expectEq(envFacts([:], isBackground: false), EnvFacts(), "no env, no facts — never a crash")
        expectEq(envFacts(["ZELLIJ_SESSION_NAME": ""], isBackground: false), EnvFacts(),
                 "an empty value is as good as absent")
    }

    test("claudeAgentRow: env facts make a hook-less session clickable and nestable") {
        let e = parseClaudeAgents(claudeAgentsFixture)[0]   // an interactive session
        let plain = claudeAgentRow(e, updatedAt: nil)
        expect(plain.backend == .other, "without env it is display-only")
        expect(!plain.sendable, "and nothing to send keystrokes to")

        let enriched = claudeAgentRow(e, updatedAt: nil,
                                      env: EnvFacts(zellijSession: "cactus", zellijPaneId: "7",
                                                    parentSessionId: "parent-1"))
        expect(enriched.backend == .zellij, "the env names its zellij home → the card can jump")
        expectEq(enriched.zellijPaneId, "7")
        expect(enriched.sendable, "and a pane id makes it sendable-to")
        expectEq(enriched.parentSessionId, "parent-1", "and it nests under its spawner")
    }

    test("statusFromDaemon: a non-empty needs means blocked even when state says running") {
        func job(state: String, needs: String?) -> DaemonJob {
            DaemonJob(short: "s", sessionId: "s", state: state, detail: nil, needs: needs, name: nil)
        }
        expectEq(statusFromDaemon(job(state: "running", needs: "answer: A or B?")), "blocked",
                 "a waiting worker can report state=running with only needs set (measured 2026-07-11)")
        expectEq(statusFromDaemon(job(state: "blocked", needs: "answer: A or B?")), "blocked")
        expectEq(statusFromDaemon(job(state: "running", needs: nil)), "working")
        expectEq(statusFromDaemon(job(state: "running", needs: "")), "working", "empty needs is not blocked")
        expectEq(statusFromDaemon(job(state: "done", needs: nil)), "idle")
    }

    test("liveBlocked: a real-time source vetoes the transcript's blocked→idle recovery") {
        let blockedJob = parseDaemonJobs(daemonListFixture)[1]
        let runningJob = parseDaemonJobs(daemonListFixture)[0]
        func reg(_ status: String) -> SessionRegistryEntry {
            SessionRegistryEntry(pid: 1, sessionId: "s", cwd: "/", kind: "background", name: nil,
                                 status: status, waitingFor: nil, startedAt: nil, updatedAt: nil)
        }
        expect(liveBlocked(job: blockedJob, registry: nil), "the daemon watches its worker directly")
        expect(liveBlocked(job: nil, registry: reg("waiting")), "a process writes `waiting` the moment it prompts")
        expect(!liveBlocked(job: runningJob, registry: reg("busy")), "neither source sees a prompt")
        expect(!liveBlocked(job: nil, registry: nil), "a finished record has no live source — the transcript decides")
    }

    test("mergedStatus: the first live source with an opinion decides") {
        expectEq(mergedStatus(live: ["blocked", "idle"]), "blocked", "the daemon outranks the registry")
        expectEq(mergedStatus(live: ["unknown", "idle"]), "idle", "a source with no opinion is skipped")
        expectEq(mergedStatus(live: ["", "unknown", "working"]), "working", "so is an empty verdict")
        expectEq(mergedStatus(live: []), "unknown", "nothing to go on")
    }

    test("statusFromAgentState: the socket's vocabulary joins the CLI's") {
        expectEq(statusFromAgentState("running"), "working", "the socket's word for a busy worker")
        expectEq(statusFromAgentState("queued"), "working", "dispatched, not started — still 'going'")
        expectEq(statusFromAgentState("blocked"), "blocked", "passes through to the blocked lane")
        expectEq(statusFromAgentState("done"), "idle", "no unread concept: a finished agent is idle")
        expectEq(statusFromAgentState(""), "unknown")
    }

    test("claudeAgentRow: the daemon's state wins over the CLI's, which was measured stale") {
        // Measured 2026-07-09 on a live worker: the socket said blocked (correct — it was waiting on
        // the user) while `claude agents --json` still said working. The socket sees the worker
        // directly; the CLI's answer is up to 5s old and, here, simply wrong.
        let e = parseClaudeAgents(claudeAgentsFixture)[1]   // background, CLI state = "working"
        let blockedJob = parseDaemonJobs(daemonListFixture)[1]

        expectEq(claudeAgentRow(e, updatedAt: nil).status, "working", "no daemon: the CLI is all we have")
        expectEq(claudeAgentRow(e, updatedAt: nil, daemon: blockedJob).status, "blocked",
                 "the socket sees the worker directly and outranks the CLI")

        let runningJob = parseDaemonJobs(daemonListFixture)[0]
        expectEq(claudeAgentRow(e, updatedAt: nil, daemon: runningJob).status, "working",
                 "the socket's 'running' maps onto our 'working'")
    }

    test("claudeAgentRow: a live worker's daemon detail becomes the activity line, and needs rides along") {
        let e = parseClaudeAgents(claudeAgentsFixture)[1]   // the background worker
        let job = parseDaemonJobs(daemonListFixture)[1]     // blocked, with detail + needs

        let plain = claudeAgentRow(e, updatedAt: nil)
        expectEq(plain.activity, "sleep then reply", "no daemon: the AI title is all we have")
        expectNil(plain.needs)

        let enriched = claudeAgentRow(e, updatedAt: nil, daemon: job)
        expectEq(enriched.activity, "marking UI clarification — awaiting direction",
                 "what it is doing now beats the conversation's title")
        expectEq(enriched.needs, "confirm desired marking style (thicker ring, overlay marker, label) or provide direction")

        let running = claudeAgentRow(e, updatedAt: nil, daemon: parseDaemonJobs(daemonListFixture)[0])
        expectEq(running.activity, "sleep then reply", "an empty detail falls back to the AI title")
    }

    test("controlSocketPath: derived from the roster's rendezvous socket, not a /tmp glob") {
        let roster: [String: Any] = ["proto": 1, "supervisorPid": 49633, "workers": [
            "12f808b4": ["pid": 49657,
                         "rendezvousSock": "/tmp/cc-daemon-501/2b28878b/rv/12f808b4.sock",
                         "ptySock": "/tmp/cc-daemon-501/2b28878b/pty/12f808b4.sock"]]]
        expectEq(controlSocketPath(roster: roster), "/tmp/cc-daemon-501/2b28878b/control.sock")

        expectNil(controlSocketPath(roster: ["proto": 1, "workers": [:] as [String: Any]]),
                  "no workers → no daemon worth talking to")
        expectNil(controlSocketPath(roster: ["proto": 1]), "a roster without a workers map")
        expectNil(controlSocketPath(roster: ["workers": ["x": ["pid": 1]]]), "a worker with no socket recorded")
    }

    test("claudeAgentRow: an agents-only session becomes a display-only row aged by its transcript") {
        let seen = Date(timeIntervalSince1970: 1_000_000)
        let e = parseClaudeAgents(claudeAgentsFixture)[2]   // the done background record
        let row = claudeAgentRow(e, updatedAt: seen)
        expectEq(row.sessionId, "1b6c4535-1111-2222-3333-444444444444")
        expectEq(row.status, "idle", "a finished background job maps onto idle")
        expectEq(row.isBackground, true)
        expectEq(row.activity, "バトルシップ観戦時のマーキング表示改善", "the AI title becomes the card title")
        expectEq(row.cwd, "/x/party-game")
        expectEq(row.updatedAt, seen, "transcript mtime drives the existing 24h filter")
        expectEq(row.statusSince, seen, "and seeds the elapsed clock")
        expect(row.backend == .other, "no zellij info: can't jump or send")
        expect(!row.sendable, "not sendable")
        expect(!row.replyable, "a finished record has no process to reply to")
    }

    test("claudeAgentRow: an interactive entry keeps its session name as the label, not the title") {
        let e = parseClaudeAgents(claudeAgentsFixture)[0]
        let row = claudeAgentRow(e, updatedAt: nil)
        expectEq(row.label, "roid-senpai-1f")
        expectNil(row.activity, "an interactive name isn't a work title")
        expectEq(row.status, "idle")
        expectEq(row.pid, 13852)
        expectEq(row.isBackground, false)
        expectNil(row.updatedAt, "no transcript → no mtime; the 24h filter's `nil` policy applies")
    }

    test("claudeAgentRow: git facts group the record under its repo instead of a solo card") {
        let g = GitFacts(branch: "feat/issue42-marking", changed: 0, repoKey: "/x/party-game/.git",
                         repoName: "party-game", isWorktree: false, prNo: 7, prUrl: "https://github.com/x/pr/7",
                         ciState: .pass)
        let e = parseClaudeAgents(claudeAgentsFixture)[2]
        let row = claudeAgentRow(e, updatedAt: nil, git: g)
        expectEq(row.repoKey, "/x/party-game/.git", "joins its repo group — no more solo section")
        expectEq(row.repoName, "party-game")
        expectEq(row.branch, "feat/issue42-marking")
        expectEq(row.prNo, 7, "the PR badge carries over")
        expectEq(row.issueNo, 42, "issue number parsed from the branch, like every other row")
        let bare = claudeAgentRow(e, updatedAt: nil)
        expectNil(bare.repoKey, "without git facts it stays a plain solo row")
    }

    test("parkedChip: a live idle/done background worker reads as parked; escalates with duration") {
        let now = Date()
        let justParked = makeRow(sessionId: "s-1", status: "idle", statusSince: now.addingTimeInterval(-60),
                                 isBackground: true, pid: 75503)
        expectEq(parkedChip(justParked, now: now)?.label, L("駐機中", "parked"),
                 "a freshly parked worker gets the plain chip (the parkingsign symbol is the UI's)")
        expectEq(parkedChip(justParked, now: now)?.color, Cat.yellow)

        let longParked = makeRow(sessionId: "s-2", status: "idle", statusSince: now.addingTimeInterval(-6600),
                                 isBackground: true, pid: 75503)
        expectEq(parkedChip(longParked, now: now)?.label,
                 L("駐機 1時間50分 — 停止し忘れ?", "parked 1h50m — forgot to stop?"),
                 "≥30min escalates to the duration + nudge")
        expectEq(parkedChip(longParked, now: now)?.color, Cat.amber, "and the amber nudge colour")

        expectNil(parkedChip(makeRow(sessionId: "s-3", status: "working", statusSince: now, isBackground: true, pid: 1), now: now),
                  "a working background agent is doing its job, not parked")
        expectNil(parkedChip(makeRow(sessionId: "s-4", status: "idle", statusSince: now, isBackground: true), now: now),
                  "no pid = a finished record (archive lane) — nothing is parked")
        expectNil(parkedChip(makeRow(sessionId: "s-5", status: "idle", statusSince: now, pid: 123), now: now),
                  "a plain interactive session is not a daemon worker")
    }

    test("repoGroupKey: repo identity, then header, then the one shared other section") {
        let repo = RepoSection(header: "shepherd", rows: [makeRow(sessionId: "a", repoKey: "K", repoName: "shepherd")])
        expectEq(repoGroupKey(repo), "K", "repo sections key on repo identity")
        let named = RepoSection(header: "h", rows: [makeRow(sessionId: "b")])
        expectEq(repoGroupKey(named), "h", "no repoKey falls back to the header")
        // groupByRepo emits at most ONE headerless section, so a constant key can't collide — and
        // unlike a row-derived key it doesn't move when a row joins or leaves (pins/folds survive).
        let other = RepoSection(header: nil, rows: [makeRow(sessionId: "one"), makeRow(sessionId: "two")])
        expectEq(repoGroupKey(other), "other")
        expectEq(repoGroupKey(RepoSection(header: nil, rows: [makeRow(sessionId: "two")])), "other",
                 "stable across rebuilds as its membership changes")
        expectEq(repoGroupKey(RepoSection(header: nil, rows: [])), "other", "and when it is empty")
    }

    test("closeMethod: background worker / background record / interactive / nothing") {
        expectEq(closeMethod(for: makeRow(sessionId: "f0415bb1-24b8", status: "working", isBackground: true, pid: 37200)),
                 .stopBackgroundAgent("f0415bb1"),
                 "a live background worker: `claude stop` removes it from the roster, killing the leaf pid with it")
        expectEq(closeMethod(for: makeRow(sessionId: "1b6c4535-1111", status: "idle", isBackground: true)),
                 .stopBackgroundAgent("1b6c4535"),
                 "a background record with no process: stop is idempotent (exit 0); `rm` is the separate menu item")
        expectEq(closeMethod(for: makeRow(sessionId: "0ce9b801-ea44", status: "idle", pid: 35991)),
                 .stopSession(id: "0ce9b801", pid: 35991),
                 "a bare/zellij interactive: `claude stop` is a no-op here (measured), so SIGTERM does the work")
        expectEq(closeMethod(for: makeRow(status: "idle")), .unavailable, "no session id — nothing to act on")
    }

    test("removableRecord: only a background agent whose process is gone") {
        expectEq(removableRecord(makeRow(sessionId: "1b6c4535-1111", status: "idle", isBackground: true)), "1b6c4535",
                 "`claude rm` is the only way off the agent-view list")
        expectNil(removableRecord(makeRow(sessionId: "f0415bb1-24b8", status: "working", isBackground: true, pid: 37200)),
                  "still running — stop it first")
        expectNil(removableRecord(makeRow(sessionId: "0ce9b801-ea44", status: "idle")), "not a background agent")
        expectNil(removableRecord(makeRow(status: "idle", isBackground: true)), "no session id")
    }

    test("partitionRecords: finished background records split off, everything else stays live") {
        let rows = [
            makeRow(sessionId: "live-zellij", status: "working", backend: .zellij),
            makeRow(sessionId: "rec1-aaaa", status: "idle", isBackground: true),
            makeRow(sessionId: "bgworker-bb", status: "working", isBackground: true, pid: 37200),
            makeRow(sessionId: "rec2-cccc", status: "idle", isBackground: true),
        ]
        let p = partitionRecords(rows)
        expectEq(p.live.map { $0.sessionId }, ["live-zellij", "bgworker-bb"],
                 "a live background worker (it has a pid) is not a record")
        expectEq(p.records.map { $0.sessionId }, ["rec1-aaaa", "rec2-cccc"],
                 "records keep their incoming order (dots render in this order)")
    }

    test("partitionRecords: a repo of nothing but records leaves live empty") {
        let rows = (1...4).map { makeRow(sessionId: "rec\($0)-aaaa", status: "idle", isBackground: true) }
        let p = partitionRecords(rows)
        expectEq(p.live.count, 0, "nothing to draw above the lane")
        expectEq(p.records.count, 4, "all four go in the lane")
    }

    test("closableFinished: only clean done/idle with a close method, de-duped, spares left alone") {
        let rows = [
            makeRow(sessionId: "a", status: "idle", changedFiles: 0),               // closable (claude stop)
            makeRow(sessionId: "b", status: "idle", changedFiles: 0),               // closable (claude stop)
            makeRow(sessionId: "c", status: "working", changedFiles: 0),            // not finished
            makeRow(sessionId: "d", status: "idle", changedFiles: 3),               // dirty → skipped
            makeRow(status: "idle", changedFiles: 0),                               // no session id → no close method
        ]
        let r = closableFinished(rows)
        expectEq(r.closable.map { $0.sessionId }.sorted(), ["a", "b"], "clean finished, closeable rows")
        expectEq(r.dirtySkipped, 1, "the uncommitted idle row is counted, not closed")
    }

    test("closableFinished: a session appearing twice counts once") {
        let rows = [
            makeRow(sessionId: "dup", status: "idle", changedFiles: 0),
            makeRow(sessionId: "dup", status: "idle", changedFiles: 0),
        ]
        expectEq(closableFinished(rows).closable.count, 1, "de-duped by session id")
    }

    test("subagentChildRow: a worktree teammate becomes a display-only card nested under its parent") {
        let started = Date(timeIntervalSince1970: 1_783_645_000)
        let updated = Date(timeIntervalSince1970: 1_783_645_600)
        let parent = makeRow(sessionId: "p-1", status: "working", label: "shepherd-7f",
                             cwd: "/repo/main", repoKey: "/repo/main/.git", repoName: "main", pid: 42)
        let rec = SubagentRecord(agentId: "abc123", type: "general-purpose",
                                 name: "lineage-probe", description: "検証用",
                                 worktreePath: "/repo/main/.claude/worktrees/agent-abc123",
                                 worktreeBranch: "worktree-agent-abc123",
                                 working: true, startedAt: started, updatedAt: updated)
        // gitFacts names a worktree after its own toplevel dir ("agent-abc123") — useless as a
        // section header, so the child must inherit the parent's repoName instead.
        let git = GitFacts(branch: "worktree-agent-abc123", changed: 1,
                           repoKey: "/repo/main/.git", repoName: "agent-abc123", isWorktree: true)
        let row = subagentChildRow(parent: parent, rec: rec, git: git)
        expectEq(row.sessionId, "p-1/subagents/agent-abc123",
                 "the synthetic id doubles as the transcript key (dir/<id>.jsonl resolves the agent's own jsonl)")
        expectEq(row.sessionId, rec.transcriptKey(parent: "p-1"), "builder and fetcher must agree on the key")
        expectEq(row.parentSessionId, "p-1", "nests under the parent via the existing treeOrder")
        expectEq(row.label, "lineage-probe",
                 "the teammate's given name, plain — the subagent mark is the UI's sparkles symbol")
        expectEq(row.status, "working")
        expectEq(row.cwd, "/repo/main/.claude/worktrees/agent-abc123", "the worktree is where it works")
        expectEq(row.branch, "worktree-agent-abc123")
        expectEq(row.changedFiles, 1)
        expectEq(row.repoKey, "/repo/main/.git", "same repo → same board section as the parent")
        expectEq(row.repoName, "main",
                 "the parent's repoName wins — a first-sorted child must not retitle the section header")
        expect(row.isWorktree, "worktree isolation shows the ⑂ mark")
        expect(row.isSubagent, "flagged so actions (close/open) stay off")
        expectEq(row.backend, Backend.other)
        expect(!row.sendable, "no terminal to send keystrokes to")
        expect(!row.replyable, "no reply route either")
        expectNil(row.pid, "lives inside the parent process — no pid of its own")
        expectEq(row.statusSince, started, "elapsed time counts from the agent's spawn")
        expectEq(row.updatedAt, updated)
    }

    test("subagentChildRow: no worktree → runs in the parent's cwd; label falls back") {
        let parent = makeRow(sessionId: "p-2", status: "working", cwd: "/repo/main",
                             repoKey: "/repo/main/.git", pid: 42)
        let unnamed = SubagentRecord(agentId: "x1", type: "Explore", working: true)
        let row = subagentChildRow(parent: parent, rec: unnamed, git: nil)
        expectEq(row.cwd, "/repo/main", "no isolation → it works in the parent's directory")
        expectEq(row.label, "Explore", "no name/description → the agent type")
        expectEq(row.repoKey, "/repo/main/.git", "git facts missing → inherit the parent's grouping")
        let described = SubagentRecord(agentId: "x2", type: "general-purpose",
                                       description: "調査タスク", working: true)
        expectEq(subagentChildRow(parent: parent, rec: described, git: nil).label, "調査タスク",
                 "description beats the bare type")
    }

    test("closeMethod: a subagent card offers no close — nothing external can stop it") {
        let parent = makeRow(sessionId: "p-3", cwd: "/repo/main", pid: 42)
        let rec = SubagentRecord(agentId: "y1", type: "general-purpose", working: true)
        let row = subagentChildRow(parent: parent, rec: rec, git: nil)
        expectEq(closeMethod(for: row), CloseMethod.unavailable)
    }

    // Stream Deck two-screen navigation (2026-07-11): the top screen lists repo columns
    // (key 0 = logo), a column screen lists that column's sessions (key 0 = back).
    test("deckKeyLayout: columns page — logo on key 0, one key per section, blanks after") {
        let sections = [
            RepoSection(header: "shepherd", rows: [makeRow(sessionId: "s1", repoKey: "/a/.git")]),
            RepoSection(header: nil, rows: [makeRow(sessionId: "s2")]),
        ]
        let keys = deckKeyLayout(sections: sections, page: .columns, keyCount: 5)
        expectEq(keys.count, 5, "always exactly keyCount entries")
        expectEq(keys[0], DeckKey.logo)
        expectEq(keys[1], DeckKey.column(repoKey: "/a/.git"))
        expectEq(keys[2], DeckKey.column(repoKey: otherSectionKey), "repo-less section keys on the shared constant")
        expectEq(keys[3], DeckKey.blank)
        expectEq(keys[4], DeckKey.blank)
    }

    test("deckKeyLayout: columns page — sections beyond the board are dropped, not wrapped") {
        let sections = (0..<6).map { RepoSection(header: "r\($0)", rows: [makeRow(sessionId: "s\($0)", repoKey: "/r\($0)/.git")]) }
        let keys = deckKeyLayout(sections: sections, page: .columns, keyCount: 5)
        expectEq(keys.count, 5)
        expectEq(keys[4], DeckKey.column(repoKey: "/r3/.git"), "keys 1..4 hold the first 4 sections")
    }

    test("deckKeyLayout: sessions page — back on key 0, that column's sessions only") {
        let sections = [
            RepoSection(header: "a", rows: [makeRow(sessionId: "a1", repoKey: "/a/.git"),
                                            makeRow(sessionId: "a2", repoKey: "/a/.git")]),
            RepoSection(header: "b", rows: [makeRow(sessionId: "b1", repoKey: "/b/.git")]),
        ]
        let keys = deckKeyLayout(sections: sections, page: .sessions(repoKey: "/a/.git"), keyCount: 5)
        expectEq(keys[0], DeckKey.back)
        expectEq(keys[1], DeckKey.session(sessionId: "a1"))
        expectEq(keys[2], DeckKey.session(sessionId: "a2"))
        expectEq(keys[3], DeckKey.blank, "the other column's session must not leak in")
        expectEq(keys[4], DeckKey.blank)
    }

    test("deckKeyLayout: sessions page for a vanished column renders as the top screen") {
        let keys = deckKeyLayout(sections: [], page: .sessions(repoKey: "/gone/.git"), keyCount: 3)
        expectEq(keys[0], DeckKey.logo, "no such column → the layout degrades to the column list")
    }

    test("resolvedDeckPage: a vanished column falls back to the top screen") {
        let sections = [RepoSection(header: "a", rows: [makeRow(sessionId: "a1", repoKey: "/a/.git")])]
        expectEq(resolvedDeckPage(sections: sections, page: .sessions(repoKey: "/a/.git")),
                 DeckPage.sessions(repoKey: "/a/.git"), "a live column keeps its screen")
        expectEq(resolvedDeckPage(sections: sections, page: .sessions(repoKey: "/gone/.git")),
                 DeckPage.columns, "column gone → back to the column list")
        expectEq(resolvedDeckPage(sections: [], page: .columns), DeckPage.columns)
    }
}
