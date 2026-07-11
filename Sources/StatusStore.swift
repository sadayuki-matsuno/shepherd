import Foundation

// MARK: - Data collection

enum CIState { case pass, fail, pending }

var prCache: [String: (num: Int?, ci: CIState?, url: String?, at: Date)] = [:]   // key: cwd. Guarded by prLock (GitHubFacts).

// Guards every fact cache below (and gitFactsCache): fetchAgents builds its rows concurrently
// (concurrentPerform), so "background queue only" became "any builder thread". Take the lock
// around dictionary reads/writes only — never across subprocess or file IO.
let factsLock = NSLock()

// key: cwd. The git-derived half of gitFacts (branch / dirty count / repo identity), cached 15s —
// state must repaint instantly, these can lag a few seconds. PR facts are NOT in here (overlaid
// live from prCache on every gitFacts call).
var gitFactsCache: [String: (facts: GitFacts, at: Date)] = [:]

// key: zellij session name. The single-pane sendability probe (`zellij action dump-layout`),
// cached 30s — layout changes are rare and the probe spawns a process per zellij row.
var zellijSendableCache: [String: (ok: Bool, at: Date)] = [:]

// key: "sess:<session id>". No source reports a status-change time, so we remember when each session
// last entered its current status. Guarded by factsLock.
var statusSeen: [String: (status: String, at: Date)] = [:]

// key: session id. Model + context usage read from the transcript tail; refreshed at most
// every ~20s (transcripts change slower than the refresh cadence). Guarded by factsLock.
var contextCache: [String: (model: ModelInfo?, pct: Double?, at: Date)] = [:]

// key: session id. Deliverable links accumulated from the transcript jsonl, plus the byte
// offset already scanned (so each poll only reads newly-appended bytes — the incremental parse
// from design §6). Links accumulate so one that scrolled past the read window never vanishes.
// Guarded by factsLock.
var transcriptLinksCache: [String: (links: [AgentLink], offset: UInt64)] = [:]

// key: session id. Claude Code's AI-generated session title (the zellij pane title) read from
// the transcript tail; refreshed at most every ~20s. nil is cached as a value (sessions from
// before the ai-title transcript line existed) so they aren't rescanned every poll. Guarded by
// factsLock.
var aiTitleCache: [String: (title: String?, at: Date)] = [:]

// `claude agents --json --all` — the list of sessions (claudeAgentsList). Cached 5s: FSEvents can fire
// a burst of refreshes, and the probe is a ~0.27s subprocess that must not stack up. Guarded by factsLock.
var claudeAgentsCache: (entries: [ClaudeAgentEntry], at: Date)? = nil

// cc-daemon's control socket (`{"op":"list"}` — daemonJobs). Cached only 2s: the round trip is well
// under a millisecond with no subprocess, so this exists to collapse a burst of FSEvents rather than
// to hide a cost. nil = no daemon running, which is the common case. Guarded by factsLock.
var daemonJobsCache: (jobs: [DaemonJob], at: Date)? = nil

// `claude auth status --json` — the logged-in account (claudeAccount). The login barely changes, so
// this is cached 5 min: the header reads it on every rebuild but the subprocess runs at most that
// often. Guarded by factsLock.
var accountCache: (account: AccountInfo?, at: Date)? = nil

// key: session id. Was a "blocked" state already answered / Ctrl+C'd (blockedResolved)? Keyed on the
// transcript's size+mtime, since the verdict can only change when the transcript grows — a stat, in
// place of re-reading its last 256KB on every refresh of every blocked row. Guarded by factsLock.
var blockedResolvedCache: [String: (size: UInt64, mtime: Date, resolved: Bool)] = [:]

// key: session id. Did the session's last turn end in an API error (transcriptErrored)? Same
// size+mtime keying, same reason. Guarded by factsLock.
var transcriptErrorCache: [String: (size: UInt64, mtime: Date, errored: Bool)] = [:]

// key: session id. Fork fingerprint = the FIRST user message's timestamp (linkForks). Immutable
// once a session has its first prompt, so cached for the process lifetime ("" = confirmed no
// fingerprint, e.g. a transcript-less session, so it isn't re-read every poll). Guarded by factsLock.
var forkKeyCache: [String: String] = [:]

// key: session id. Resolved fallback "what is this" line (last transcript user prompt /
// sessions-index firstPrompt) for rows with no last-prompt line. "" caches a
// confirmed-nothing so a genuinely quiet session isn't rescanned every poll. Guarded by factsLock.
var activityFallbackCache: [String: String] = [:]

// key: session id. The session's latest assistant text (A2), the "last utterance" shown on an
// idle/blocked card (✓ result / ? question). Cached with the updatedAt it was read for, so we only
// re-read the transcript tail when the session actually advanced. Guarded by factsLock.
var lastMessageCache: [String: (msg: String, at: Date)] = [:]

// The latest assistant text for a session, cached by its updatedAt so an idle session isn't
// re-scanned every poll. First line only, trimmed for the one-line card row (A2).
func lastMessageFor(cwd: String, sessionId: String, updatedAt: Date?) -> String? {
    let stamp = updatedAt ?? .distantPast
    factsLock.lock()
    let c = lastMessageCache[sessionId]
    factsLock.unlock()
    if let c = c, c.at == stamp { return c.msg.isEmpty ? nil : c.msg }
    let raw = lastAssistantTextFromTranscript(cwd: cwd, sessionId: sessionId)
    // Collapse to the first non-empty line and squash whitespace — a card row is one line.
    let msg = raw?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .first(where: { !$0.isEmpty }).map { String($0.prefix(160)) } ?? ""
    factsLock.lock()
    lastMessageCache[sessionId] = (msg, stamp)
    factsLock.unlock()
    return msg.isEmpty ? nil : msg
}

// Is a pid still around? (A permission error means "alive, not ours to signal".)
func pidAlive(_ pid: Int32) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno != ESRCH
}
