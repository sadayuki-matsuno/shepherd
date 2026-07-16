import Foundation
#if canImport(AppKit)
import AppKit
// The logic layer stores colours as data; only the AppKit UI draws them. On macOS HUDColor
// IS NSColor so the UI keeps consuming these fields untouched.
typealias HUDColor = NSColor
#else
// Linux port: NSColor stand-in with just the shape the logic layer needs.
struct HUDColor: Equatable {
    let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    init(srgbRed: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        red = srgbRed; self.green = green; self.blue = blue; self.alpha = alpha
    }
}
#endif

// MARK: - Catppuccin Mocha palette

func rgb(_ hex: UInt32) -> HUDColor {
    HUDColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
             green: CGFloat((hex >> 8) & 0xff) / 255,
             blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

enum Cat {
    static let base = rgb(0x1e1e2e)
    static let mantle = rgb(0x181825)
    static let surface = rgb(0x313244)
    static let surface1 = rgb(0x45475a)
    static let text = rgb(0xcdd6f4)
    static let subtext = rgb(0xa6adc8)
    static let overlay = rgb(0x6c7086)
    static let green = rgb(0xa6e3a1)     // working
    static let peach = rgb(0xfab387)     // blocked
    static let blue = rgb(0x89b4fa)      // OPUS chip, PR link
    static let teal = rgb(0x94e2d5)      // PR badge
    static let yellow = rgb(0xf9e2af)    // launching
    static let red = rgb(0xf38ba8)       // server down
    static let mauve = rgb(0xcba6f7)     // FABLE chip
    static let lavender = rgb(0xb4befe)
    static let amber = rgb(0xf5c97b)     // uncommitted dog-ear (distinct from peach)
    static let crust = rgb(0x11111b)     // dark text on solid status banners
}

// A model badge (normalized display name + tier colour) shown on a card's first line.
// `raw` keeps the transcript's full model id so the card can resolve the context window
// (contextWindow matches on the raw id, e.g. "opus-4-8" — the display name alone can't).
struct ModelInfo {
    let name: String
    let color: HUDColor
    var raw: String = ""
}

// Context-window denominator for a transcript's model id. The jsonl records no window size —
// verified 2026-07-08 across all local transcripts: `message.model` is the bare id (never a
// "[1m]" suffix) and no contextWindow/maxContext field exists anywhere. So we map by substring,
// calibrated against observed peak usage on this machine (fable-5: 435k, opus-4-8: 948k,
// opus-4-7: 676k — all clearly 1M windows). Everything else stays 200k, but escalates to 1M the
// moment its own observed total disproves 200k. Override any of this via
// `defaults write com.sadayuki-matsuno.shepherd contextLimits -dict-add <substring> -int <window>`.
var contextLimitOverrides: [String: Int] =
    (defaults.dictionary(forKey: "contextLimits") as? [String: Int]) ?? [:]

func contextWindow(model raw: String?, observedTotal: Int = 0) -> Int {
    let l = (raw ?? "").lowercased()
    for (pattern, window) in contextLimitOverrides where l.contains(pattern.lowercased()) { return window }
    if l.contains("[1m]") { return 1_000_000 }
    if l.contains("fable") || l.contains("opus-4-8") || l.contains("opus-4-7") { return 1_000_000 }
    return observedTotal > 200_000 ? 1_000_000 : 200_000
}

func modelInfo(from raw: String) -> ModelInfo? {
    let l = raw.lowercased()
    if l.contains("fable") { return ModelInfo(name: "FABLE", color: Cat.mauve, raw: raw) }
    if l.contains("opus") { return ModelInfo(name: "OPUS", color: Cat.blue, raw: raw) }
    if l.contains("sonnet") { return ModelInfo(name: "SONNET", color: Cat.teal, raw: raw) }
    if l.contains("haiku") { return ModelInfo(name: "HAIKU", color: Cat.overlay, raw: raw) }
    return nil
}

// Capability rank for the tier-bar instrument (M1, 2026-07-15): 1=haiku … 4=fable.
// 0 = unknown display name → the card falls back to the plain text chip.
func modelTier(_ name: String) -> Int {
    switch name {
    case "HAIKU":  return 1
    case "SONNET": return 2
    case "OPUS":   return 3
    case "FABLE":  return 4
    default:       return 0
    }
}

// Permission-mode classifier (the drawn lock glyph itself is gone, 2026-07-15 evening —
// the mode now tints the title row's where-it-runs glyph; this enum remains as the
// "known mode" predicate behind lockGlyph(for:)). Lives here (not Components) so the
// Linux build, which excludes the AppKit UI, still gets it.
enum LockGlyph { case closed, unlatched, open }

// Lock glyph for a permission mode (P1, 2026-07-15): how far the guard is off.
// nil/"default" shows nothing (unremarkable case); unknown future modes return nil here and
// keep the text-chip fallback so they stay visible.
func lockGlyph(for mode: String?) -> LockGlyph? {
    switch mode {
    case "plan":               return .closed
    case "acceptEdits":        return .unlatched
    case "dontAsk":            return .unlatched
    case "bypassPermissions":  return .open
    default:                   return nil
    }
}

// Permission-mode chip (2026-07-08): how Claude Code is being run, from the hook's
// permission_mode. "default" (ask every time) is the unremarkable case and shows nothing;
// unknown future modes fall through as-is so they're at least visible.
func permissionModeChip(_ mode: String?) -> (label: String, color: HUDColor)? {
    switch mode {
    case nil, "default":       return nil
    case "plan":               return ("PLAN", Cat.lavender)
    case "acceptEdits":        return ("⏵⏵ EDITS", Cat.green)
    case "dontAsk":            return ("⏵⏵ NO-ASK", Cat.amber)
    case "bypassPermissions":  return ("BYPASS", Cat.red)
    case let m?:               return (m.uppercased(), Cat.overlay)
    }
}

// MARK: - Model

struct AgentRow {
    let sessionId: String   // the Claude session id → resolves the transcript file
    let model: ModelInfo?   // model in use (from the transcript)
    // Advisor model when the session runs with one (`--advisor` / advisorModel setting; read from
    // the transcript's line-level advisorModel field). Means "configured", not "consulted".
    var advisor: ModelInfo? = nil
    let contextPct: Double? // context-window usage 0…1 (from the transcript's last usage)
    var permissionMode: String? = nil  // Claude Code permission mode (hook-recorded: default /
                                       // plan / acceptEdits / bypassPermissions / dontAsk)
    var status: String      // working / blocked / idle / error / unknown
    let label: String       // workspace label
    let cwd: String
    let dirName: String
    let dirPath: String     // last two path components, e.g. "sadayuki-matsuno/shepherd"
    let branch: String?
    let changedFiles: Int?
    let issueNo: Int?
    let prNo: Int?
    let prUrl: String?      // PR web URL (for the unified badge click)
    let ciState: CIState?   // CI rollup for the PR (pass / fail / pending)
    var repoKey: String?    // git repo identity (.git path); shared across a repo's worktrees
                            // (var: a child session inherits its root parent's key for grouping)
    let repoName: String?
    let isWorktree: Bool    // true = a linked git worktree, false = the main checkout / non-repo
    let activity: String?   // one-line "what it's doing now" (OSC title, else last ⏺ line)
    let links: [AgentLink]  // deliverables (PR / Artifact URLs) the agent produced
    let statusSince: Date   // when this agent last entered its current status (tracked locally)
    let backend: Backend    // where this session lives → which row actions apply
    let zellijSession: String?  // zellij session name (for the P3 jump), if any
    let zellijPaneId: String?   // the claude pane's ZELLIJ_PANE_ID (bare int, hook-recorded) —
                                // enables pane-level focus and multi-pane sends
    let stale: Bool         // pid alive but updated_at is old (Stop hook may have been missed)
    var parentSessionId: String?  // parent Claude session id (child-session tree), if any
                                  // (var: linkForks re-parents a same-slot fork onto its root)
    let subagents: [SubagentRecord]  // Agent-tool subagents spawned by this session (all states)
    let zellijSendable: Bool  // a zellij row we can safely send keystrokes to (1 tab / 1 pane, B1)
    let updatedAt: Date?      // status file's updated_at (last real event) — drives the 24h filter (A3)
    let lastMessage: String?  // latest assistant text (A2) — the finished/blocked "last utterance" line
    // Trailing defaulted fields (kept last so existing positional call sites are unaffected):
    var startedAt: Date? = nil    // session start (status file's started_at) — picks the root of a fork group
    var forkKey: String? = nil    // fork fingerprint: the FIRST user message's timestamp. A --fork-session
                                  // / /branch / /rewind copies history verbatim, so a fork and its origin
                                  // share this byte-identical value — the one definitive proof two session
                                  // ids are the same conversation (there is no fork flag in the status file)
    var isFork: Bool = false      // a fork/resume of the root above it (linkForks); rendered at the top of
                                  // its root's children with a ⑂ mark, not the round status dot
    var isBackground: Bool = false // a cc-daemon background agent (`claude agents` kind) — carries the BG
                                   // chip, and `claude stop` is what closes it (SIGTERM gets respawned)
    var pid: Int32? = nil          // the claude process (status file, or `claude agents` for a live
                                   // session) — the SIGTERM target when `claude stop` doesn't apply
    var needs: String? = nil       // what a blocked background worker is waiting to be told, in cc-daemon's
                                   // own words (control socket `needs`). No other source has it: the CLI's
                                   // `claude agents --json` omits it and the transcript only has the raw
                                   // question. Shown on the card and seeded into the reply popover.
    var isSubagent: Bool = false   // an Agent-tool subagent's own card (subagentChildRow) — display-only:
                                   // it runs inside its parent's process, so there is no pid to signal,
                                   // no terminal to open and no attach route (verified 2026-07-10)
    var editorBundleId: String? = nil  // .vscode only: the hosting editor's __CFBundleIdentifier
                                       // (com.microsoft.VSCode / a fork's id) — the `open -b` target
    var termProgram: String? = nil     // TERM_PROGRAM from the session's env — names the terminal a
                                       // bare (.other) session lives in
    var entrypoint: String? = nil      // registry entrypoint: "cli" / "sdk-cli" (`claude -p`)

    // What this session runs on, as chip text ("zellij" / "VS Code" / "Ghostty" / "claude -p" …).
    var runtime: String? {
        runtimeLabel(backend: backend, termProgram: termProgram, editorBundleId: editorBundleId,
                     entrypoint: entrypoint, isBackground: isBackground, isSubagent: isSubagent)
    }

    // Can Shepherd deliver keystrokes to this row? A single-pane zellij session (B1), or a zellij
    // pane we can target by id (multi-pane — needs an attached client at send time; deliverText
    // handles that refusal).
    var sendable: Bool { zellijSendable || zellijPaneId != nil }
    // Inline reply reaches a session either through its terminal (sendable) or — for a live
    // background worker — through the daemon control socket's authed `reply` op (P3, 2026-07-10).
    // A VSCode terminal is deliberately NOT replyable: no external key injection exists, and the
    // card click already lands keyboard focus in the editor — answer there (2026-07-11 decision;
    // a clipboard+paste-hint fallback was built and then removed as not worth the extra step).
    var replyable: Bool { sendable || (isBackground && pid != nil) }
}

// MARK: - claude agents

// One entry of `claude agents --json --all` — Claude Code's own session registry, which knows every
// interactive session and every cc-daemon background agent whether or not our status hook ever fired.
// Measured 2026-07-09 (claude 2.1.205): no field is exclusive to one kind. An interactive session has
// pid+status; a LIVE background worker has pid+status+state; a stopped background record has only
// state. So parse defensively and let statusFromClaudeAgent reconcile the two status vocabularies.
struct ClaudeAgentEntry: Equatable {
    let sessionId: String     // full UUID — the join key with status files and transcripts
    let shortId: String       // `id` for a background agent, else the UUID's first segment; the
                              // argument `claude stop` / `claude rm` expect
    let isBackground: Bool    // kind == "background"
    let pid: Int32?
    let rawStatus: String?    // process activity: busy / idle
    let rawState: String?     // job lifecycle (background only): working / done
    let name: String?
    let cwd: String
    let startedAt: Date?

    // Only a background agent's `name` is the AI-generated work title (the same string the transcript's
    // ai-title lines carry). An interactive session's `name` is its derived session name ("shepherd-c3"),
    // which belongs on the label, not on the card's title line.
    var aiTitle: String? { isBackground ? name : nil }
}

func parseClaudeAgents(_ arr: [[String: Any]]) -> [ClaudeAgentEntry] {
    arr.compactMap { o in
        guard let sid = o["sessionId"] as? String, !sid.isEmpty else { return nil }
        return ClaudeAgentEntry(
            sessionId: sid,
            shortId: (o["id"] as? String) ?? shortSessionId(sid),
            isBackground: (o["kind"] as? String) == "background",
            pid: (o["pid"] as? NSNumber)?.int32Value,
            rawStatus: o["status"] as? String,
            rawState: o["state"] as? String,
            name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            cwd: o["cwd"] as? String ?? "",
            startedAt: (o["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
    }
}

// Map the status vocabularies Shepherd meets onto its own. Claude's CLI and control socket speak
// busy/idle (a process's activity), working/done (a background job's lifecycle) and
// running/blocked/queued/failed. Anything unknown passes
// through, so a future word shows up as itself rather than being silently mis-coloured.
//
// `done` collapses onto `idle`. Every source means something different by it — the CLI means "finished
// and you haven't looked yet", Claude means "this background job has terminated" — and Shepherd tracks
// neither: a session that isn't working is idle, and a terminated background job is a record, sorted
// into the archive lane by removableRecord rather than by a status word.
func statusFromAgentState(_ raw: String) -> String {
    switch raw {
    case "busy", "working", "running", "queued": return "working"
    case "idle", "done":                         return "idle"
    case "failed":                               return "error"
    case "":                                     return "unknown"
    case let other:                              return other   // "blocked" arrives verbatim
    }
}

// A background worker's status from the daemon. The `state` field is NOT reliable for "blocked": a
// worker waiting on an AskUserQuestion can report state "running" with only `needs` set (measured
// 2026-07-11 — the card showed working and no notification fired). `needs` is the real signal that a
// human decision is pending, so a non-empty `needs` is blocked regardless of state.
func statusFromDaemon(_ job: DaemonJob) -> String {
    if let needs = job.needs, !needs.isEmpty { return "blocked" }
    return statusFromAgentState(job.state)
}

// `state` (the job's lifecycle) wins over `status` (the process's activity): a background worker that
// has just finished its turn reports status=idle + state=done, and both land on idle anyway; a live
// one reports status=busy + state=working.
func statusFromClaudeAgent(_ e: ClaudeAgentEntry) -> String {
    statusFromAgentState(e.rawState ?? e.rawStatus ?? "")
}

// The session's status, from the sources that watch it directly, in priority order: the cc-daemon
// control socket (it watches its worker), then the process's own registry file (it writes `waiting`
// the moment it puts a prompt on screen), then `claude agents` (a 5s-cached snapshot with no word
// for blocked). The first source with an opinion decides; "unknown" means none had one.
func mergedStatus(live: [String]) -> String {
    live.first { $0 != "unknown" && !$0.isEmpty } ?? "unknown"
}

// What a session's process environment tells us that no file does (2026-07-10). `ps -wwEp <pid>`
// prints the env of any process of this uid — including ones Shepherd never spawned — so a session
// that never ran the status hook still gives up the two facts the hook exists to snapshot: where it
// lives (zellij session + pane) and who spawned it (the SHEPHERD_PARENT_SESSION_ID convention —
// Shepherd's own, hence the prefix: a CLAUDE_ name would read as official and could collide with
// a future Claude Code variable. Renamed from CLAUDE_PARENT_SESSION_ID 2026-07-11, no fallback:
// the old writers — herdr-era skills — are gone and no live process carried the old name).
//
// A BACKGROUND worker is excluded from the zellij fields on purpose. Its env is NOT the shell's that
// ran `claude --bg`: the daemon hands the job to a pre-warmed spare, so the worker carries the
// DAEMON's env — which itself came from whichever pane first started the daemon (measured
// 2026-07-10: a parent-session id set in the spawning shell never reaches the worker, while a
// stale ZELLIJ_PANE_ID does). Those zellij vars name a pane the worker doesn't live in; it has no
// terminal at all, and `claude attach` is its way in. A directly-exec'd claude (the `pane run`
// convention) does inherit its parent id, which is what lets a hook-less child session nest.
struct EnvFacts: Equatable {
    var zellijSession: String?
    var zellijPaneId: String?
    var parentSessionId: String?
    // TERM_PROGRAM ("vscode" / "ghostty" / …): which terminal UI hosts the session. zellij passes
    // the host terminal's value through, so this stays meaningful inside panes (measured 2026-07-11).
    var termProgram: String?
    // __CFBundleIdentifier: the .app bundle the process ultimately launched under — macOS sets it
    // for every bundle-launched process tree. For a VSCode-family terminal this is the exact id
    // `open -b` wants, so fork support (Cursor / Windsurf) needs no lookup table. NOT read from
    // VSCODE_GIT_ASKPASS_MAIN: that path contains spaces ("Visual Studio Code.app") and truncates
    // in `ps -wwEp`'s space-separated output.
    var bundleId: String?
}

func envFacts(_ env: [String: String], isBackground: Bool) -> EnvFacts {
    func nonEmpty(_ key: String) -> String? {
        guard let v = env[key], !v.isEmpty else { return nil }
        return v
    }
    // A background worker carries the DAEMON's env, not its spawner's (see above) — the terminal
    // facts would name a terminal the worker doesn't live in, so they are dropped alongside zellij's.
    return EnvFacts(zellijSession: isBackground ? nil : nonEmpty("ZELLIJ_SESSION_NAME"),
                    zellijPaneId: isBackground ? nil : nonEmpty("ZELLIJ_PANE_ID"),
                    parentSessionId: nonEmpty("SHEPHERD_PARENT_SESSION_ID"),
                    termProgram: isBackground ? nil : nonEmpty("TERM_PROGRAM"),
                    bundleId: isBackground ? nil : nonEmpty("__CFBundleIdentifier"))
}

// Is a source that watches the session RIGHT NOW reporting an open prompt? The daemon socket sees its
// worker directly, and every claude process writes `waiting` into its own registry file the moment it
// puts a prompt on screen. Either one vetoes the transcript-based blocked→idle recovery: the
// transcript is a lagging record (a background worker doesn't write the blocking turn until the turn
// ends), so it can show an OLD question as answered while a new one is on screen unanswered.
func liveBlocked(job: DaemonJob?, registry: SessionRegistryEntry?) -> Bool {
    if let job = job, statusFromDaemon(job) == "blocked" { return true }
    if let registry = registry, statusFromRegistry(registry) == "blocked" { return true }
    return false
}

// A session `claude agents` knows about but no status file does — the hook-less
// interactive sessions and the finished background records (G1 / G8). There's no pane, so the row is
// display-and-stop only. `updatedAt` is the transcript's mtime, which lets the existing 24h filter
// age old records out on its own (R4); it also seeds the elapsed clock, since these rows have no
// status file to read a real event time from. `git` carries the cwd's repo facts (the fetch site
// resolves them; this stays a pure function) so the record joins its repo's group — without a
// repoKey each record lands as its own solo section (and, until 2026-07-09, several solo sections
// collided on one placement key and painted the same card into every slot — see repoGroupKey).
// `daemon` is the same session as its live cc-daemon worker reports it over the control socket, when
// there is one. It outranks the CLI on both fields it can speak to:
//   - `state`: the socket watches the worker directly, where `claude agents` answers from a 5s cache
//     and can disagree with the worker's real state.
//   - `detail`: the only source that says what the agent is doing *right now*. The AI title names the
//     conversation, not the current turn, so detail leads the activity line.
// `env` is the row's own process environment (envFacts), which is how a hook-less session still gets
// a home to jump to and a parent to nest under — the two things the status hook otherwise supplies.
func claudeAgentRow(_ e: ClaudeAgentEntry, updatedAt: Date?, git g: GitFacts? = nil,
                    daemon: DaemonJob? = nil, env: EnvFacts = EnvFacts(),
                    underZellij: Bool? = nil, entrypoint: String? = nil) -> AgentRow {
    let dirName = (e.cwd as NSString).lastPathComponent
    let parentName = ((e.cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let backend = resolveBackend(zellijSession: env.zellijSession, termProgram: env.termProgram,
                                 underZellij: underZellij, entrypoint: entrypoint)
    return AgentRow(sessionId: e.sessionId, model: nil, contextPct: nil,
                    status: daemon.map(statusFromDaemon) ?? statusFromClaudeAgent(e),
                    label: e.name ?? dirName, cwd: e.cwd, dirName: dirName,
                    dirPath: parentName.isEmpty ? dirName : "\(parentName)/\(dirName)",
                    branch: g?.branch, changedFiles: g?.changed,
                    issueNo: g?.branch.flatMap { firstMatchInt("issue(\\d+)", in: $0) },
                    prNo: g?.prNo, prUrl: g?.prUrl, ciState: g?.ciState,
                    repoKey: g?.repoKey, repoName: g?.repoName, isWorktree: g?.isWorktree ?? false,
                    activity: daemon?.detail ?? e.aiTitle, links: [],
                    statusSince: updatedAt ?? e.startedAt ?? Date(),
                    backend: backend,
                    // A VSCode row's zellij vars are the leak this resolution just rejected — a
                    // pane the session doesn't live in. Keeping them would make the row `sendable`
                    // and route sends/captures at a stranger's pane, so they go with the verdict.
                    zellijSession: backend == .zellij ? env.zellijSession : nil,
                    zellijPaneId: backend == .zellij ? env.zellijPaneId : nil, stale: false,
                    parentSessionId: env.parentSessionId, subagents: [], zellijSendable: false,
                    updatedAt: updatedAt, lastMessage: nil, startedAt: e.startedAt,
                    isBackground: e.isBackground, pid: e.pid, needs: daemon?.needs,
                    editorBundleId: backend == .vscode ? env.bundleId : nil,
                    termProgram: env.termProgram, entrypoint: entrypoint)
}

// MARK: - Agent-tool subagents (teammates)

// One Agent-tool subagent as its own per-agent files describe it: agent-<id>.meta.json carries the
// identity Claude Code wrote at spawn (name / description, and worktreePath+worktreeBranch when the
// agent was spawned with worktree isolation), agent-<id>.jsonl is its live turn-by-turn transcript
// (written record-by-record while it runs — measured 2026-07-10, +7KB in 10s on a live agent).
struct SubagentRecord {
    let agentId: String            // from the file name, agent-<id>.meta.json
    let type: String               // meta agentType, "agent" when absent
    var name: String? = nil        // the caller-given teammate name
    var description: String? = nil // the Agent tool's short task description
    var worktreePath: String? = nil    // worktree isolation only
    var worktreeBranch: String? = nil
    var model: String? = nil       // meta `model` — the spawn-time alias ("haiku"), present only when
                                   // the caller overrode the model. The chip's source until the
                                   // agent's first assistant reply lands in its jsonl (which then
                                   // wins: it carries the resolved model id)
    var working: Bool = false      // jsonl tail is mid-turn (the turn hasn't ended)
    var activity: String? = nil    // "what it's doing now" from its own jsonl: the last tool call
                                   // while working, else its last message — its analogue of the
                                   // parent's daemon `detail`, and (unlike the caller-given name) in
                                   // the agent's own words, so it reads in the session's language
    var startedAt: Date? = nil     // meta.json mtime — written once at spawn
    var updatedAt: Date? = nil     // jsonl mtime — freshness of the live transcript

    // The transcript-resolution key for this agent: every transcript helper builds
    // <projects>/<sanitized-cwd>/<sessionId>.jsonl, so a "sessionId" of
    // <parent>/subagents/agent-<id> resolves to the agent's own jsonl. subagentChildRow uses it as
    // the card's session id, which also keeps the per-session caches keyed and GC'd correctly.
    func transcriptKey(parent: String) -> String { "\(parent)/subagents/agent-\(agentId)" }
}

// A working subagent's own card, nested under its parent (2026-07-10). Display-only by nature: the
// agent runs inside the parent claude process, so there is no pid, no terminal and no attach route
// (`claude agents` never lists subagents — verified). Finished agents get no card at all: with the
// jsonl-tail state, a teammate revived by a later SendMessage turns working again and the card
// simply reappears. `git` is the facts of the agent's own cwd (its worktree, when isolated); when
// they're missing the parent's grouping keys keep the card in the parent's board section.
func subagentChildRow(parent: AgentRow, rec: SubagentRecord, git g: GitFacts?,
                      model: ModelInfo? = nil, advisor: ModelInfo? = nil, contextPct: Double? = nil,
                      activity: String? = nil, links: [AgentLink] = [],
                      now: Date = Date()) -> AgentRow {
    let cwd = rec.worktreePath ?? parent.cwd
    let dirName = (cwd as NSString).lastPathComponent
    let parentName = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let branch = g?.branch ?? rec.worktreeBranch
    return AgentRow(sessionId: rec.transcriptKey(parent: parent.sessionId),
                    model: model, advisor: advisor, contextPct: contextPct,
                    status: "working",
                    // Plain name — the "this is a subagent" mark is a sparkles symbol drawn by the
                    // UI (card title / family peek), not baked into the label (2026-07-11).
                    label: rec.name ?? rec.description ?? rec.type,
                    cwd: cwd, dirName: dirName,
                    dirPath: parentName.isEmpty ? dirName : "\(parentName)/\(dirName)",
                    branch: branch, changedFiles: g?.changed,
                    issueNo: branch.flatMap { firstMatchInt("issue(\\d+)", in: $0) },
                    prNo: g?.prNo, prUrl: g?.prUrl, ciState: g?.ciState,
                    repoKey: g?.repoKey ?? parent.repoKey,
                    // repoName intentionally prefers the parent: gitFacts names a worktree after its
                    // own toplevel dir (".claude/worktrees/agent-<id>" → "agent-<id>"), and a freshly
                    // started child sorts first in its section, which would retitle the header to that.
                    repoName: parent.repoName ?? g?.repoName,
                    isWorktree: g?.isWorktree ?? (rec.worktreePath != nil),
                    activity: activity, links: links,
                    statusSince: rec.startedAt ?? now,
                    backend: .other, zellijSession: nil, zellijPaneId: nil, stale: false,
                    parentSessionId: parent.sessionId, subagents: [], zellijSendable: false,
                    updatedAt: rec.updatedAt, lastMessage: nil, startedAt: rec.startedAt,
                    isSubagent: true)
}

// MARK: - cc-daemon control socket

// One live background worker as cc-daemon reports it over its control socket (`{"proto":1,"op":"list"}`).
// The socket answers in under a millisecond, against 0.29s for the `claude agents --json --all`
// subprocess, and carries two fields the CLI never returns:
//   detail — what the worker is doing right now ("marking UI clarification — awaiting direction")
//   needs  — what a blocked worker wants to be told ("confirm desired marking style … or provide direction")
// Only live workers appear here; finished records live in ~/.claude/jobs and reach us via the CLI.
//
// The reply also carries a `pid`, which is NOT captured here: it is the `bg-pty-host` wrapper, not the
// claude process the status file records, so signalling it would hit the wrong process. A row's pid
// comes from the status file.
struct DaemonJob: Equatable {
    let short: String        // the id `claude stop` / `op:"kill"` take (the UUID's first segment)
    let sessionId: String    // full UUID — the join key with status files and transcripts
    let state: String        // running / blocked / done / queued / failed
    let detail: String?
    let needs: String?
    let name: String?        // the worker's AI-generated work title
}

func parseDaemonJobs(_ arr: [[String: Any]]) -> [DaemonJob] {
    arr.compactMap { o in
        guard let short = o["short"] as? String, !short.isEmpty,
              let sid = o["sessionId"] as? String, !sid.isEmpty else { return nil }
        // The daemon writes "" rather than omitting a field it has nothing for.
        func text(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return DaemonJob(short: short, sessionId: sid,
                         state: o["state"] as? String ?? "", detail: text("detail"),
                         needs: text("needs"), name: text("name"))
    }
}

// cc-daemon's control socket sits beside the per-worker rendezvous sockets it records in the roster
// (`/tmp/cc-daemon-<uid>/<hash>/rv/<short>.sock` → `…/<hash>/control.sock`). Deriving the path from
// the roster instead of globbing /tmp keeps us on the daemon belonging to THIS ~/.claude — a different
// CLAUDE_CONFIG_DIR gets its own hash and its own daemon — and doubles as the "is a daemon even
// running" check: no workers, no socket worth talking to. (Measured: polling the socket does NOT keep
// the daemon alive — it still idle-exits 5s after its last worker, because only `attach` takes a lease.)
func controlSocketPath(roster: [String: Any]) -> String? {
    guard let workers = roster["workers"] as? [String: Any] else { return nil }
    for (_, w) in workers {
        guard let sock = (w as? [String: Any])?["rendezvousSock"] as? String, !sock.isEmpty else { continue }
        let dir = ((sock as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        guard !dir.isEmpty, dir != "/" else { continue }
        return (dir as NSString).appendingPathComponent("control.sock")
    }
    return nil
}

// The one section every repo-less row shares (groupByRepo), and its placement key.
let otherSectionKey = "other"

// The placement key for a repo group, shared by the column layout, drag pinning, collapse state and
// the column-header menu. Repo identity first, then the header, else the single "other" section —
// which must key on a constant, not on its first row, or its pin and fold state would move every
// time a row joins or leaves it. Sections MUST NOT share a literal key: columnsView / layoutColumns
// index sections by this key, so a collision makes one section win the dictionary and get painted
// into every colliding slot (2026-07-09: one card rendered three times).
func repoGroupKey(_ s: RepoSection) -> String {
    if let k = s.rows.first?.repoKey { return k }
    if let h = s.header { return h }
    return otherSectionKey
}

// How to shut a session down when the user hits "close" — one branch per kind of session, because
// each kind dies a different death (all measured 2026-07-09 on claude 2.1.205):
//  - a cc-daemon background agent (the "party-game card that won't die" — a `/remote-control` fork the
//    daemon keeps resuming from its roster) ignores SIGTERM to its leaf pid, because the daemon just
//    respawns it. `claude stop <id>` removes it from the roster, and the leaf dies with it. On an
//    already-stopped record stop stays exit-0, so this is safely idempotent;
//  - a bare-terminal / zellij interactive session is the mirror image: `claude stop` doesn't know it
//    ("No job matching …", exit 1 — it only manages background jobs), so SIGTERM is what actually ends
//    it. We still run stop first: it costs nothing, and it keeps the close path correct even when the
//    row's kind is unknown (the `claude agents` probe is allowed to fail — §6.2 graceful degradation).
// `.unavailable` = nothing actionable (a row with no session id).
enum CloseMethod: Equatable {
    case stopBackgroundAgent(String)          // short id → `claude stop <id>` + remove the status file
    case stopSession(id: String, pid: Int32?) // short id → `claude stop` (no-op) → SIGTERM(pid)
    case unavailable
}

func closeMethod(for row: AgentRow) -> CloseMethod {
    // A subagent card has nothing external to stop: no pid, no daemon record, and its synthetic
    // session id is not a UUID `claude stop` would recognize.
    guard !row.sessionId.isEmpty, !row.isSubagent else { return .unavailable }
    let id = shortSessionId(row.sessionId)
    return row.isBackground ? .stopBackgroundAgent(id) : .stopSession(id: id, pid: row.pid)
}

// A background agent whose process is already gone: `claude stop` still reports success but changes
// nothing, so the only way off the agent-view list is `claude rm <id>`. That also deletes the
// session's worktree, which is why it's a separate, confirmed menu item rather than part of close.
// (Measured: rm keeps the conversation transcript, and is not idempotent — a second rm exits 1.)
func removableRecord(_ row: AgentRow) -> String? {
    guard row.isBackground, row.pid == nil, !row.sessionId.isEmpty else { return nil }
    return shortSessionId(row.sessionId)
}

// A live background worker sitting idle/done is a *parked* process: nobody is looking at it, yet it
// holds real memory (worker + pty-host ≈ 600MB, measured 2026-07-09) and keeps the cc-daemon and its
// spare pool alive with it. That's exactly the forgotten waste this board exists to surface — and
// what visually separates a live BG card from the archive lane's cost-free records — so the card
// says so: a plain 🅿 chip while freshly parked, escalating to the parked duration plus a stop nudge
// once it has sat ≥30min. A working background agent is busy, not parked; a pid-less background row
// is a finished record with nothing running to point at.
func parkedChip(_ row: AgentRow, now: Date = Date()) -> (label: String, color: HUDColor)? {
    guard row.isBackground, row.pid != nil, row.status == "idle" else { return nil }
    let parked = now.timeIntervalSince(row.statusSince)
    // Text only — the chip's leading parkingsign symbol is added by the UI (tinyChip(symbol:)).
    return parked >= 1800
        ? (L("駐機 \(formatDuration(parked)) — 停止し忘れ?", "parked \(formatDuration(parked)) — forgot to stop?"), Cat.amber)
        : (L("駐機中", "parked"), Cat.yellow)
}

// Split a repo section's rows into the sessions you can still touch and the finished background
// records (`removableRecord`) that only `claude attach` / `claude rm` can act on (2026-07-09).
// The board draws `live` as its usual tree and folds `records` into one archive lane below it, so a
// dead record never sits next to a live done/idle card pretending to be reachable.
func partitionRecords(_ rows: [AgentRow]) -> (live: [AgentRow], records: [AgentRow]) {
    var live: [AgentRow] = []
    var records: [AgentRow] = []
    for row in rows {
        if removableRecord(row) != nil { records.append(row) } else { live.append(row) }
    }
    return (live, records)
}

// The cc-daemon / agent-view id for a session is the first segment of its UUID (e.g.
// "99678571-c5b8-…" → "99678571"), which is what `claude stop` expects.
func shortSessionId(_ sessionId: String) -> String {
    String(sessionId.split(separator: "-").first ?? Substring(sessionId))
}

// The finished (done/idle), clean sessions in `rows` that we can actually shut down — the payload
// of the column "close done/idle" action. De-duped by session id. Rows with uncommitted changes are
// left alone and only counted (dirtySkipped) so the caller can say so; a bare session with no
// closeMethod is skipped entirely.
func closableFinished(_ rows: [AgentRow]) -> (closable: [AgentRow], dirtySkipped: Int) {
    let finished: Set<String> = ["idle"]
    var seen = Set<String>()
    var closable: [AgentRow] = []
    var dirtySkipped = 0
    for row in rows where finished.contains(row.status) {
        if closeMethod(for: row) == .unavailable { continue }
        if !seen.insert(row.sessionId).inserted { continue }
        if (row.changedFiles ?? 0) == 0 { closable.append(row) } else { dirtySkipped += 1 }
    }
    return (closable, dirtySkipped)
}

struct AgentLink {
    let label: String   // "PR" / "Artifact"
    let url: String
    var favicon: String? = nil   // Artifact tool input `favicon` (emoji), paired by tool_use_id (A1)
    var title: String? = nil     // Artifact tool input `description`, for the badge label (A1)
}

// Where a session actually lives, which decides what row actions are available:
//  - zellij: jump (attach the session, focus its pane) + send-text / capture / drop
//  - vscode: a VSCode-family integrated terminal (VSCode / Cursor / Windsurf — identified by
//    TERM_PROGRAM, opened via its __CFBundleIdentifier). Jumpable (`open -b <bundle> <cwd>`), but
//    no external key injection exists, so there is no inline reply — the click lands keyboard
//    focus in the editor and the user answers there (see AgentRow.replyable)
//  - other: a background worker (opens with `claude attach`), or a Claude started straight in a
//    terminal, which Shepherd can only display and stop
enum Backend { case zellij, vscode, other }

// Resolve a row's Backend from its env facts (2026-07-11, all measured). TERM_PROGRAM travels:
// zellij passes the HOST terminal's value through unscrubbed (a zellij pane under Ghostty reads
// "ghostty"), and a VSCode window cold-started from a zellij pane leaks ZELLIJ_* into every
// integrated terminal it opens. So "vscode" + zellij vars can mean either "VSCode with leaked
// zellij env" (jump must NOT walk zellij panes) or "zellij running inside a VSCode terminal"
// (zellij vars are real). Env alone cannot tell them apart; `underZellij` — is the claude process
// a descendant of a zellij server (zellijDescendant) — breaks the tie. nil = ancestry unknown
// (ps failed): prefer .vscode, the case actually observed in the wild.
//
// `entrypoint` (the registry's, measured 2026-07-12) outranks every env fact: a Claude Code
// extension-panel session ("claude-vscode") is spawned directly by the extension — no integrated
// terminal, so TERM_PROGRAM stays whatever shell cold-started VS Code and any zellij vars are that
// shell's leak. Env would classify it as a stranger's pane; the entrypoint says where it really is.
func resolveBackend(zellijSession: String?, termProgram: String?, underZellij: Bool? = nil,
                    entrypoint: String? = nil) -> Backend {
    if entrypoint == "claude-vscode" { return .vscode }
    if termProgram == "vscode" {
        if zellijSession != nil, underZellij == true { return .zellij }
        return .vscode
    }
    return zellijSession != nil ? .zellij : .other
}

// Does `pid`'s ancestor chain contain a zellij process? zellij panes are children of the zellij
// server (itself a child of launchd), so a claude that truly lives in a pane reaches "zellij"
// before the root; one in a VSCode terminal reaches Code Helper / Electron and never sees zellij.
// `table` is a full-process snapshot (pid → ppid + comm), one `ps -axo` per refresh (processTable).
// The visited set guards against a cyclic/inconsistent snapshot.
func zellijDescendant(pid: Int32, table: [Int32: (ppid: Int32, comm: String)]) -> Bool {
    var cur = pid
    var visited: Set<Int32> = []
    while let entry = table[cur], !visited.contains(cur) {
        visited.insert(cur)
        if entry.comm.contains("zellij") { return true }
        cur = entry.ppid
    }
    return false
}

// Short display name for the VSCode-family editor hosting a session. Only com.microsoft.VSCode is
// measured (2026-07-11); the fork ids follow each product's published bundle id and are unverified.
// The jump itself never needs this table — `open -b` takes the bundle id verbatim.
func editorDisplayName(_ bundleId: String?) -> String {
    switch bundleId {
    case "com.todesktop.230313mzl4w4u92": return "Cursor"
    case "com.exafunction.windsurf": return "Windsurf"
    case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
    case "com.vscodium", "com.vscodium.VSCodium": return "VSCodium"
    default: return "VS Code"
    }
}

// Display name for a TERM_PROGRAM value. Only the terminals actually met on this machine get a
// prettier name; anything unknown passes through verbatim so a new terminal names itself instead
// of vanishing.
func terminalDisplayName(_ termProgram: String?) -> String? {
    switch termProgram {
    case nil: return nil
    case "ghostty": return "Ghostty"
    case "iTerm.app": return "iTerm"
    case "Apple_Terminal": return "Terminal"
    case let other?: return other
    }
}

// What a session runs ON, as chip text: the multiplexer ("zellij"), the hosting editor ("VS Code" /
// "Cursor"), the bare terminal app ("Ghostty"), or the headless mode it was launched in ("claude -p"
// — the registry's entrypoint, the one fact env can't supply: a headless run still inherits its
// shell's TERM_PROGRAM, so entrypoint outranks the terminal). "claude-vscode" (the extension panel)
// falls through instead: its home is the editor, which the backend switch already names. nil when
// there is nothing to say: a background worker (the BG chip already covers it, and its env is the
// daemon's anyway) or a subagent (it runs inside its parent's process).
// Card label for the collapsed artifact badge (2026-07-15): a sole artifact opens directly
// (keeps the ↗); two or more become "newest-title（他+N）" and the click opens a picker.
func artifactBadgeText(title: String?, favicon: String?, count: Int) -> String {
    let t = title.map { String($0.prefix(14)) } ?? "Artifact"
    let base = favicon.map { "\($0) \(t)" } ?? t
    guard count >= 2 else { return base + " ↗" }
    return base + L("（他+\(count - 1)）", " (+\(count - 1))")
}

// SF Symbol for the title row's leading where-it-runs glyph (2026-07-15). Editor/terminal
// silhouettes are the one instrument that works icon-only — recognizable without a word; the
// name and details ride the hover hint. nil runtime (bg worker / subagent) shows nothing.
func runtimeGlyph(backend: Backend, runtime: String?) -> String? {
    guard runtime != nil else { return nil }
    switch backend {
    case .vscode: return "chevron.left.forwardslash.chevron.right"
    case .zellij: return "square.split.2x1"
    case .other:  return runtime == "claude -p" ? "terminal" : "apple.terminal"
    }
}

func runtimeLabel(backend: Backend, termProgram: String?, editorBundleId: String?,
                  entrypoint: String?, isBackground: Bool, isSubagent: Bool) -> String? {
    if isBackground || isSubagent { return nil }
    if let ep = entrypoint, !ep.isEmpty, ep != "cli", ep != "claude-vscode" {
        return ep == "sdk-cli" ? "claude -p" : ep
    }
    switch backend {
    case .zellij: return "zellij"
    case .vscode: return editorDisplayName(editorBundleId)
    case .other: return terminalDisplayName(termProgram)
    }
}


// The last user prompt, cleaned for display: nil when empty or a background-agent system
// notification (`<task-notification>…`) that slipped past the hook's own filter (files written
// before that filter existed still carry one). Used as the "what it's doing" line for sessions
// with no OSC title.
func promptTitle(_ raw: String?) -> String? {
    guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
          !s.hasPrefix("<task-notification>") else { return nil }
    return s
}

// A repo group in the panel: the header carries the repo name (nil for plain
// directories that aren't a git repo).
struct RepoSection {
    let header: String?
    let rows: [AgentRow]
}

// Group rows by repo, keeping a repo's worktrees adjacent. Rows with no repo (a plain directory —
// a scratch dir, /tmp, a finished background record whose cwd was never a checkout) share ONE
// headerless "other" section rather than each claiming a column of its own (2026-07-10: three test
// records painted three identical "その他" columns, each with its own archive lane). Sections are
// ordered by their most-urgent status; ties break on label so refreshes don't reshuffle.
func groupByRepo(_ rows: [AgentRow]) -> [RepoSection] {
    var order: [String] = []
    var buckets: [String: [AgentRow]] = [:]
    for r in rows {
        let key = r.repoKey ?? otherSectionKey
        if buckets[key] == nil { order.append(key) }
        buckets[key, default: []].append(r)
    }
    func rank(_ a: AgentRow, _ b: AgentRow) -> Bool {
        let ao = style(for: a.status).order, bo = style(for: b.status).order
        if ao != bo { return ao < bo }
        if a.statusSince != b.statusSince { return a.statusSince > b.statusSince } // newest change first
        return a.label < b.label
    }
    var sections = order.map { key -> RepoSection in
        let rs = buckets[key]!.sorted(by: rank)
        // Header: name the column after the MAIN checkout, not whichever row ranks first — gitFacts
        // names a worktree row after its worktree directory (`repo-main-branch`), so a busy child
        // session in a worktree would rename the whole column (2026-07-11). A row can also carry the
        // repo's key with NO name at all — a child session in a non-repo cwd joins the column through
        // the adopted repoKey (AgentFetch) — so a nameless row must not blank the header either
        // (2026-07-11, the VSCode probe sessions). With no named main checkout on the board, fall
        // back to the shared common-dir key (`…/repo/.git` → "repo").
        let header: String?
        if let main = rs.first(where: { !$0.isWorktree && $0.repoName != nil }) {
            header = main.repoName
        } else if let repoKey = rs.first?.repoKey {
            let name = (repoKey as NSString).lastPathComponent
            header = name == ".git"
                ? ((repoKey as NSString).deletingLastPathComponent as NSString).lastPathComponent
                : name
        } else {
            header = nil
        }
        return RepoSection(header: header, rows: rs)
    }
    sections.sort {
        let ao = $0.rows.map { style(for: $0.status).order }.min() ?? 99
        let bo = $1.rows.map { style(for: $0.status).order }.min() ?? 99
        if ao != bo { return ao < bo }
        let ar = $0.rows.map { $0.statusSince }.max() ?? Date.distantPast
        let br = $1.rows.map { $0.statusSince }.max() ?? Date.distantPast
        if ar != br { return ar > br }   // most recently changed group first
        return ($0.rows.first?.label ?? "") < ($1.rows.first?.label ?? "")
    }
    return sections
}

// MARK: - Stream Deck screens (2026-07-11)

// The deck is a two-screen drill-down: the top screen lists repo columns (one key per
// RepoSection), pressing one shows that column's sessions. Key 0 is fixed: the Shepherd
// logo on the top screen, the back key on a column screen.
enum DeckPage: Equatable {
    case columns
    case sessions(repoKey: String)   // repoGroupKey of the column being viewed
}

enum DeckKey: Equatable {
    case logo                        // brand / manual refresh (top screen, key 0)
    case back                        // return to the column list (column screen, key 0)
    case column(repoKey: String)
    case session(sessionId: String)
    case blank
}

// 15 keys on both supported decks (MK.2 / Original V2). Lives here, not on the IOKit driver
// class, so the Linux build (which excludes StreamDeck.swift) keeps the layout logic.
let deckKeyCount = 15

// The board a page shows: always exactly `keyCount` entries. Overflowing items are dropped —
// a 15-key deck shows the 14 most urgent columns/sessions (groupByRepo already sorts by urgency).
func deckKeyLayout(sections: [RepoSection], page: DeckPage, keyCount: Int = deckKeyCount) -> [DeckKey] {
    var keys: [DeckKey]
    switch page {
    case .sessions(let repoKey) where sections.contains(where: { repoGroupKey($0) == repoKey }):
        let rows = sections.first { repoGroupKey($0) == repoKey }!.rows
        keys = [.back] + rows.prefix(keyCount - 1).map { .session(sessionId: $0.sessionId) }
    default:   // .columns, or a sessions page whose column vanished
        keys = [.logo] + sections.prefix(keyCount - 1).map { .column(repoKey: repoGroupKey($0)) }
    }
    keys.append(contentsOf: Array(repeating: .blank, count: max(0, keyCount - keys.count)))
    return keys
}

// Keep the current screen only while its column still exists (a refresh can dissolve it).
func resolvedDeckPage(sections: [RepoSection], page: DeckPage) -> DeckPage {
    if case .sessions(let repoKey) = page,
       !sections.contains(where: { repoGroupKey($0) == repoKey }) { return .columns }
    return page
}

// Fold same-conversation forks into the family tree (2026-07-09). Claude Code's session picker
// (/resume) and /branch · /rewind · --fork-session copy a conversation's history into a NEW
// session id and keep BOTH alive — so a forked session lands as its own card with the same AI
// title as its origin (the "two identical party-game cards" report). There's no fork flag in the
// status file, so we key on the one definitive signal: a fork shares its origin's FIRST user
// message verbatim, hence the same `forkKey` (first-message timestamp). Rows sharing (cwd, forkKey)
// are one conversation; the earliest-started one is the root, the rest are re-parented onto it and
// flagged isFork so treeOrder nests them (at the top of its children) with a distinct ⑂ mark.
func linkForks(_ rows: [AgentRow]) -> [AgentRow] {
    var groups: [String: [Int]] = [:]
    for (i, r) in rows.enumerated() {
        guard let key = r.forkKey, !key.isEmpty, !r.cwd.isEmpty else { continue }
        groups["\(r.cwd)\u{1}\(key)", default: []].append(i)
    }
    var out = rows
    for idxs in groups.values where idxs.count > 1 {
        // Root = earliest start (the original conversation); the copies made later are the forks.
        // Ties (missing started_at) break on session id so the choice is deterministic across polls.
        let rootIdx = idxs.min { a, b in
            let sa = rows[a].startedAt ?? .distantFuture, sb = rows[b].startedAt ?? .distantFuture
            return sa != sb ? sa < sb : rows[a].sessionId < rows[b].sessionId
        }!
        let rootId = rows[rootIdx].sessionId
        for i in idxs where i != rootIdx {
            out[i].parentSessionId = rootId
            out[i].isFork = true
        }
    }
    return out
}

// Given one repo section's rows (already status-sorted), produce a pre-order list with an
// indent depth for each: a child Claude session (parent_session_id points at another row in
// this section) is slotted right under its parent instead of at its own sorted position, so a
// working child doesn't float away from an idle parent. Roots keep their incoming order. A fork
// child (linkForks) sorts to the TOP of its parent's children, ahead of real child sessions.
// Recursion is capped at depth 3 (deeper descendants render flat at depth 3) and cycle-guarded.
func treeOrder(_ rows: [AgentRow]) -> [(row: AgentRow, depth: Int)] {
    let inSection = Set(rows.map { $0.sessionId })
    func parent(_ r: AgentRow) -> String? {
        guard let p = r.parentSessionId, p != r.sessionId, inSection.contains(p) else { return nil }
        return p
    }
    var childrenOf: [String: [AgentRow]] = [:]
    for r in rows { if let p = parent(r) { childrenOf[p, default: []].append(r) } }
    // Forks first, then real children — a stable partition preserves each group's incoming order.
    for k in childrenOf.keys {
        let kids = childrenOf[k]!
        childrenOf[k] = kids.filter { $0.isFork } + kids.filter { !$0.isFork }
    }
    var out: [(row: AgentRow, depth: Int)] = []
    var visited: Set<String> = []
    func emit(_ r: AgentRow, _ depth: Int) {
        if visited.contains(r.sessionId) { return }   // cycle / already placed
        visited.insert(r.sessionId)
        out.append((r, depth))
        if depth >= 3 { return }
        for c in childrenOf[r.sessionId] ?? [] { emit(c, depth + 1) }
    }
    for r in rows where parent(r) == nil { emit(r, 0) }
    for r in rows where !visited.contains(r.sessionId) { emit(r, 0) }   // orphaned by a cycle
    return out
}

// HUD サイズモード（2026-07-08）。auto は従来の内容追従。小/中/大は「N列ぶんの幅 × 固定高さ」の
// 固定サイズ（中身は縦スクロールのみ — 幅は列数に量子化するので横あふれは構造的に起きない）。
// fullDisplay は載っているディスプレイの可視領域（メニューバー・Dock除く）全面に固定。
enum HUDSizeMode: String, CaseIterable {
    case auto, small, medium, large, fullDisplay
}

// 固定プリセットの列数と高さ。auto（内容追従）と fullDisplay（画面実寸）はプリセットを持たない。
func hudPreset(_ mode: HUDSizeMode) -> (columns: Int, height: CGFloat)? {
    switch mode {
    case .small:  return (1, 520)
    case .medium: return (2, 640)
    case .large:  return (3, 760)
    case .auto, .fullDisplay: return nil
    }
}

// N列ぶんのパネル幅: 左右パディング + 列 + 列間ギャップ。
func hudPanelWidth(columns: Int, columnWidth: CGFloat, gap: CGFloat, sidePadding: CGFloat) -> CGFloat {
    sidePadding * 2 + CGFloat(columns) * columnWidth + CGFloat(columns - 1) * gap
}

// パネル幅に横あふれなしで収まる列数（fullDisplay 用）。最低1列。
func hudFitColumns(panelWidth: CGFloat, columnWidth: CGFloat, gap: CGFloat, sidePadding: CGFloat) -> Int {
    max(1, Int((panelWidth - sidePadding * 2 + gap) / (columnWidth + gap)))
}

struct StatusStyle {
    let dot: HUDColor
    let word: String
    let order: Int
}

// Human-friendly elapsed time (clarity over precision). For agents already running when
// Shepherd launched, this counts from launch — see statusSince.
func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return L("\(s)秒", "\(s)s") }
    let m = s / 60
    if m < 60 { return L("\(m)分", "\(m)m") }
    let h = m / 60, mm = m % 60
    return mm == 0 ? L("\(h)時間", "\(h)h") : L("\(h)時間\(mm)分", "\(h)h\(mm)m")
}

func style(for status: String) -> StatusStyle {
    switch status {
    case "error":      return StatusStyle(dot: Cat.red, word: L("エラー", "error"), order: 0)
    case "blocked":    return StatusStyle(dot: Cat.peach, word: L("応答待ち", "needs input"), order: 0)
    case "working":    return StatusStyle(dot: Cat.green, word: L("作業中", "working"), order: 1)
    case "idle":       return StatusStyle(dot: Cat.overlay, word: L("待機", "idle"), order: 3)
    default:           return StatusStyle(dot: Cat.overlay, word: L("不明", "unknown"), order: 4)
    }
}
