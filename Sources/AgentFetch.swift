import Foundation

// Every Claude Code session on this machine, from Claude Code's own bookkeeping — no status hook
// (2026-07-10). Four native sources, each answering what only it can:
//   • `claude agents --json --all` — which sessions exist, live or finished (the finished background
//     records live nowhere else). The one subprocess in this function.
//   • ~/.claude/sessions/<pid>.json — the live status a session writes about itself, fresher than the
//     CLI's 5s cache, with `waiting` + why (SessionsRegistry).
//   • the cc-daemon control socket — for background workers: their real state, what they're doing
//     this turn (`detail`), and what a blocked one needs to be told (DaemonControl).
//   • the session's own process env, via `ps` — where it lives (zellij session + pane) and who
//     spawned it. One `ps` for every row.
// Everything else (model, context %, deliverable links, title, subagents, API errors) comes out of
// the transcript. Each source is additive: any of them can be missing and the board degrades.
func fetchAgents() -> [AgentRow] {
    var claudeEntries: [ClaudeAgentEntry] = []
    let probe = DispatchGroup()
    probe.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        claudeEntries = claudeAgentsList() ?? []
        probe.leave()
    }

    var daemonBySession: [String: DaemonJob] = [:]
    for job in daemonJobs() ?? [] { daemonBySession[job.sessionId] = job }

    var registryBySession: [String: SessionRegistryEntry] = [:]
    for e in readSessionsRegistry() { registryBySession[e.sessionId] = e }

    let now = Date()
    probe.wait()
    let envs = processEnvironments(pids: claudeEntries.compactMap { $0.pid })

    // Ancestry snapshot, fetched once per refresh and only when some session carries BOTH
    // TERM_PROGRAM=vscode and zellij vars — the one combination env facts can't classify alone
    // (a VSCode cold-started from a zellij pane leaks ZELLIJ_* into its terminals; measured
    // 2026-07-11, see resolveBackend).
    let ancestryTable: [Int32: (ppid: Int32, comm: String)] =
        envs.values.contains(where: { $0["TERM_PROGRAM"] == "vscode" && $0["ZELLIJ_SESSION_NAME"] != nil })
        ? processTable() : [:]

    func buildRow(_ e: ClaudeAgentEntry) -> AgentRow {
        let cwd = e.cwd
        let job = daemonBySession[e.sessionId]
        let reg = registryBySession[e.sessionId]
        let env = envFacts(e.pid.flatMap { envs[$0] } ?? [:], isBackground: e.isBackground)
        // No ancestry snapshot (or no pid to look up) = "unknown", per resolveBackend's contract —
        // nil and false resolve the same today, but the distinction keeps the contract honest.
        let backend = resolveBackend(
            zellijSession: env.zellijSession, termProgram: env.termProgram,
            underZellij: ancestryTable.isEmpty ? nil
                : e.pid.map { zellijDescendant(pid: $0, table: ancestryTable) },
            entrypoint: reg?.entrypoint)
        // The zellij vars a non-zellij verdict leaves behind are the rejected leak — a pane the
        // session doesn't live in. Cleared here so sendable/jump/capture never target it.
        let zellijSession = backend == .zellij ? env.zellijSession : nil
        let zellijPaneId = backend == .zellij ? env.zellijPaneId : nil

        // The daemon watches its worker directly; the registry is the session's own account of
        // itself; the CLI is a 5s-cached snapshot with no word for blocked. First opinion wins.
        var status = mergedStatus(live: [job.map(statusFromDaemon) ?? "unknown",
                                         reg.map(statusFromRegistry) ?? "unknown",
                                         statusFromClaudeAgent(e)])
        // A prompt dismissed with Ctrl+C leaves a finished record frozen at blocked; the transcript
        // proves it was answered. Never applied while a live source still sees the prompt open — a
        // background worker's transcript lags a turn behind, so it would clear a real block.
        if status == "blocked", !liveBlocked(job: job, registry: reg),
           blockedResolved(cwd: cwd, sessionId: e.sessionId) { status = "idle" }
        // A turn that died on an API error leaves the session idle with nothing running; the
        // transcript's synthetic error message is the same event the StopFailure hook reported.
        if status == "idle", transcriptErrored(cwd: cwd, sessionId: e.sessionId) { status = "error" }

        // On the FIRST sighting of a status, age it from the session's own clock (the registry's
        // status-change time, else the transcript's mtime) so a session already running when
        // Shepherd launched shows its true age instead of "just now".
        let key = "sess:\(e.sessionId)"
        factsLock.lock()
        if statusSeen[key]?.status != status {
            statusSeen[key] = (status, reg?.updatedAt ?? transcriptMtime(cwd: cwd, sessionId: e.sessionId) ?? now)
        }
        let statusSince = statusSeen[key]!.at
        factsLock.unlock()

        let (model, contextPct) = transcriptCtx(cwd: cwd, sessionId: e.sessionId)
        let g = cwd.isEmpty ? GitFacts(isWorktree: false) : gitFacts(cwd: cwd)
        let dirName = (cwd as NSString).lastPathComponent
        let parentName = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent

        var issueNo: Int? = nil
        if let b = g.branch { issueNo = firstMatchInt("issue(\\d+)", in: b) }
        if issueNo == nil { issueNo = firstMatchInt("#(\\d+)", in: dirName) }

        // A zellij row is sendable-to when its session is a single tab/pane (B1); the dump-layout
        // probe is a process, so its verdict is cached 30s per session.
        var zellijSendable = false
        if let zs = zellijSession {
            factsLock.lock()
            let cached = zellijSendableCache[zs]
            factsLock.unlock()
            if let c = cached, Date().timeIntervalSince(c.at) < 30 {
                zellijSendable = c.ok
            } else {
                zellijSendable = zellijSinglePane(zs) ?? false
                factsLock.lock()
                zellijSendableCache[zs] = (zellijSendable, Date())
                factsLock.unlock()
            }
        }

        // A background worker's `claude agents` name is its AI title and belongs on the activity
        // line; an interactive session's ("shepherd-c3") is a better label than the bare directory.
        let lastPrompt = transcriptTailValue(cwd: cwd, sessionId: e.sessionId, type: "last-prompt", field: "lastPrompt")
        return AgentRow(sessionId: e.sessionId, model: model, contextPct: contextPct,
                        permissionMode: transcriptTailValue(cwd: cwd, sessionId: e.sessionId,
                                                            type: "permission-mode", field: "permissionMode"),
                        status: status,
                        label: (e.isBackground ? nil : e.name) ?? dirName,
                        cwd: cwd, dirName: dirName,
                        dirPath: parentName.isEmpty ? dirName : "\(parentName)/\(dirName)",
                        branch: g.branch, changedFiles: g.changed, issueNo: issueNo, prNo: g.prNo,
                        prUrl: g.prUrl, ciState: g.ciState, repoKey: g.repoKey, repoName: g.repoName,
                        isWorktree: g.isWorktree,
                        activity: job?.detail
                            ?? transcriptAITitle(cwd: cwd, sessionId: e.sessionId)
                            ?? e.aiTitle
                            ?? promptTitle(lastPrompt)
                            ?? activityFallback(cwd: cwd, sessionId: e.sessionId),
                        links: extractLinksFromTranscript(cwd: cwd, sessionId: e.sessionId),
                        statusSince: statusSince,
                        backend: backend,
                        zellijSession: zellijSession, zellijPaneId: zellijPaneId, stale: false,
                        parentSessionId: env.parentSessionId,
                        subagents: subagentsFromTranscript(cwd: cwd, sessionId: e.sessionId),
                        zellijSendable: zellijSendable,
                        updatedAt: reg?.updatedAt ?? transcriptMtime(cwd: cwd, sessionId: e.sessionId) ?? e.startedAt,
                        lastMessage: (status == "idle" || status == "blocked")
                            ? lastMessageFor(cwd: cwd, sessionId: e.sessionId, updatedAt: reg?.updatedAt) : nil,
                        startedAt: e.startedAt,
                        forkKey: transcriptForkKey(cwd: cwd, sessionId: e.sessionId),
                        isBackground: e.isBackground, pid: e.pid,
                        needs: job?.needs ?? (reg?.status == "waiting" ? reg?.waitingFor : nil),
                        editorBundleId: backend == .vscode ? env.bundleId : nil,
                        termProgram: env.termProgram, entrypoint: reg?.entrypoint)
    }

    // Each row's facts are dominated by subprocess / file IO, so build rows concurrently — wall-clock
    // becomes the slowest single row instead of the sum. Shared caches are guarded by factsLock
    // inside the builder; results land in fixed slots under rowsLock (plain array writes from
    // multiple threads violate exclusivity).
    let rowsLock = NSLock()
    var built = [AgentRow?](repeating: nil, count: claudeEntries.count)
    DispatchQueue.concurrentPerform(iterations: claudeEntries.count) { i in
        let row = buildRow(claudeEntries[i])
        rowsLock.lock(); built[i] = row; rowsLock.unlock()
    }
    var rows = built.compactMap { $0 }

    // Working Agent-tool subagents (teammates) get their own display-only card nested under their
    // parent; finished ones show nothing — nothing external can attach to or resume them, and a
    // teammate revived by a later SendMessage turns working again and simply reappears (2026-07-10).
    // Only parents with a live process qualify: a crashed parent leaves the child's jsonl frozen
    // mid-turn, which would otherwise pin a ghost "working" card forever. The transcript helpers all
    // resolve <dir>/<sessionId>.jsonl, so the record's transcriptKey reads the agent's own transcript
    // through them (and keys the per-session caches, which the GC below keeps while the card lives).
    var subagentRows: [AgentRow] = []
    for r in rows where r.pid != nil && !r.cwd.isEmpty {
        for rec in r.subagents where rec.working {
            let key = rec.transcriptKey(parent: r.sessionId)
            let (model, contextPct) = transcriptCtx(cwd: r.cwd, sessionId: key)
            let agentCwd = rec.worktreePath ?? r.cwd
            // The subagent's activity is its own last tool call / message (subagentTail), read in
            // its language — not the caller-given task name. Fall back to the name only if its jsonl
            // said nothing (a just-spawned agent that hasn't acted yet).
            subagentRows.append(subagentChildRow(
                parent: r, rec: rec, git: gitFacts(cwd: agentCwd),
                // Model: the agent's own jsonl first (the resolved id), else the spawn-time alias
                // from its meta — a just-spawned agent has no assistant line yet, and an inherited
                // model has no meta entry either, so both sources are needed.
                model: model ?? rec.model.flatMap(modelInfo),
                contextPct: contextPct,
                activity: rec.activity ?? rec.description ?? rec.name,
                links: extractLinksFromTranscript(cwd: r.cwd, sessionId: key)))
        }
    }
    rows += subagentRows

    // Fold same-conversation forks (session picker / /branch / --fork-session) under their origin
    // so a fork doesn't stand alone as a duplicate card. Runs before the child→repoKey pass below,
    // which then also carries a fork into its root's repo group via the parentSessionId it just set.
    rows = linkForks(rows)

    // Child Claude sessions (parent_session_id set, parent also on the board) join their root
    // parent's repo group so groupByRepo keeps the whole family in one section; the actual
    // parent→child nesting (↳ prefix, indent, depth cap) is applied at render time (treeOrder).
    let sessionsInSet = Set(rows.map { $0.sessionId })
    var parentOf: [String: String] = [:]
    var repoKeyBySession: [String: String] = [:]
    for r in rows {
        if let p = r.parentSessionId, p != r.sessionId { parentOf[r.sessionId] = p }
        if let k = r.repoKey { repoKeyBySession[r.sessionId] = k }
    }
    for i in rows.indices {
        guard rows[i].parentSessionId != nil else { continue }
        var cur = rows[i].sessionId
        var visited: Set<String> = [cur]
        while let p = parentOf[cur], sessionsInSet.contains(p), !visited.contains(p) { visited.insert(p); cur = p }
        if cur != rows[i].sessionId, let k = repoKeyBySession[cur] { rows[i].repoKey = k }
    }

    // Drop cache entries whose row disappeared this round.
    let liveKeys = Set(rows.map { "sess:\($0.sessionId)" })
    let liveSessions = Set(rows.map { $0.sessionId }.filter { !$0.isEmpty })
    let liveCwds = Set(rows.map { $0.cwd })
    let liveZellij = Set(rows.compactMap { $0.zellijSession })
    factsLock.lock()
    statusSeen = statusSeen.filter { liveKeys.contains($0.key) }
    gitFactsCache = gitFactsCache.filter { liveCwds.contains($0.key) }
    zellijSendableCache = zellijSendableCache.filter { liveZellij.contains($0.key) }
    contextCache = contextCache.filter { liveSessions.contains($0.key) }
    transcriptLinksCache = transcriptLinksCache.filter { liveSessions.contains($0.key) }
    forkKeyCache = forkKeyCache.filter { liveSessions.contains($0.key) }
    blockedResolvedCache = blockedResolvedCache.filter { liveSessions.contains($0.key) }
    transcriptErrorCache = transcriptErrorCache.filter { liveSessions.contains($0.key) }
    activityFallbackCache = activityFallbackCache.filter { liveSessions.contains($0.key) }
    lastMessageCache = lastMessageCache.filter { liveSessions.contains($0.key) }
    factsLock.unlock()
    // Ordering is handled per repo group at render time (see groupByRepo).
    return rows
}
