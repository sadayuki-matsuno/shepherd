import Foundation

var claudeProjectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")

// Claude Code encodes a project's cwd into its transcript directory name by replacing every
// non-alphanumeric character with "-" (e.g. /Users/x/.ghq/… → -Users-x--ghq-…).
func sanitizeCwd(_ cwd: String) -> String {
    String(cwd.map { ($0.isLetter || $0.isNumber) ? $0 : "-" })
}

// Last-modified time of a session's transcript jsonl. Used as a statusSince fallback for herdr
// sessions started before the status-hook existed: they have no status file (so no updated_at), but
// their transcript's mtime is the last real event, so the elapsed clock survives a Shepherd restart
// instead of resetting to "now" (v6fix3). nil when the transcript is absent.
func transcriptMtime(cwd: String, sessionId: String) -> Date? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

// Read the model + context-window usage from the tail of an agent's transcript. Only the
// last ~64KB is read; we scan lines from the end for the latest assistant message.
//
// Every tail read seeks back a fixed number of BYTES, which routinely lands inside a multi-byte
// character. `String(data:encoding:.utf8)` returns nil for the WHOLE slice when that happens, not just
// for the split character — so tail slices are decoded leniently. The first line of a slice is a
// fragment either way, and every reader below skips lines that don't parse as JSON.
func readTranscriptContext(cwd: String, sessionId: String) -> (model: ModelInfo?, pct: Double?, advisor: ModelInfo?) {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return (nil, nil, nil) }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil) }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 65_536, (try? fh.seek(toOffset: size - 65_536)) == nil { return (nil, nil, nil) }
    else if size <= 65_536 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return (nil, nil, nil) }
    let text = String(decoding: data, as: UTF8.self)
    // A subagent's own transcript (sessionId = "<parent>/subagents/agent-<id>") is ALL sidechain
    // lines — every assistant record in agent-<id>.jsonl carries isSidechain:true (measured
    // 2026-07-11) — so the main-chain filter below would discard the whole file and the agent's
    // card would never get a model chip or context gauge.
    let ownSidechain = sessionId.contains("/subagents/")
    for line in text.split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              // Sidechain lines are Agent-tool subagent turns — their usage is the SUBAGENT's own
              // (small) context, not the main session's, so a card would show a bogus % whenever a
              // subagent spoke last. Skip them; only the main chain counts.
              ownSidechain || (obj["isSidechain"] as? Bool) != true,
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { continue }
        let total = (usage["input_tokens"] as? Int ?? 0)
                  + (usage["cache_read_input_tokens"] as? Int ?? 0)
                  + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        let window = contextWindow(model: msg["model"] as? String, observedTotal: total)
        let pct = total > 0 ? min(1.0, Double(total) / Double(window)) : nil
        let model = (msg["model"] as? String).flatMap(modelInfo)
        // Advisor-paired sessions stamp every assistant line with a top-level "advisorModel"
        // (2026-07-15 measured, incl. subagent transcripts — the session setting propagates).
        // Its presence means "advisor configured", not "advisor was consulted".
        let advisor = (obj["advisorModel"] as? String).flatMap(modelInfo)
        return (model, pct, advisor)
    }
    return (nil, nil, nil)
}

// Accept only a well-formed http(s) URL (trims trailing punctuation / full-width junk),
// so a truncated or malformed capture never reaches NSWorkspace.open.
func validHTTPURL(_ s: String) -> URL? {
    let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}>\"'。、（）　 \t"))
    guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(),
          scheme == "http" || scheme == "https", u.host?.isEmpty == false else { return nil }
    return u
}

// Pull PR / Artifact links out of one block of text the agent wrote. Prefers the explicit HERD_PR /
// HERD_ARTIFACT markers /herd-issues children emit; falls back to a bare PR / Artifact URL.
// Deduped by URL, in appearance order.
func linksFromText(_ text: String) -> [AgentLink] {
    var links: [AgentLink] = []
    func add(_ label: String, _ raw: String?) { addAll(label, raw.map { [$0] } ?? []) }
    func addAll(_ label: String, _ raws: [String]) {
        for raw in raws {
            guard let u = validHTTPURL(raw) else { continue }
            let url = u.absoluteString
            if !links.contains(where: { $0.url == url }) { links.append(AgentLink(label: label, url: url)) }
        }
    }
    // Stop the capture at whitespace OR a half/full-width paren: agents often print an
    // annotation glued right after the URL with no space (e.g. `…093e96（favicon 🐏 固定）`),
    // and a greedy \S+ would swallow it into the URL and break the link. Also stop at a JSON
    // string terminator (" \ ) so a URL embedded in a transcript's JSON isn't over-captured.
    let urlBody = "[^\\s（）()\"\\\\]+"
    add("PR", lastMatchString("HERD_PR:\\s*(\(urlBody))", in: text))
    addAll("Artifact", allMatchStrings("HERD_ARTIFACT:\\s*(\(urlBody))", in: text))
    if links.isEmpty {
        // A Claude artifact URL always ends in a UUID (…/artifact[s]/<8-4-4-4-12 hex>), so
        // anchor on that structure rather than "everything until a space" — this cuts exactly
        // at the UUID no matter what (annotation, query string, punctuation) follows.
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        addAll("Artifact", allMatchStrings("(https://claude\\.ai/[\\w/-]*?\(uuid))", in: text))
        add("PR", lastMatchString("(https://github\\.com/\\S+/pull/\\d+)", in: text))
    }
    return links
}

// Flatten a tool_result block's `content` (a string, or an array of {type:text,text:…} blocks)
// into one searchable string.
func toolResultText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let arr = content as? [[String: Any]] {
        return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    return ""
}

// Deliverable URLs from ONE transcript slice, parsed as line-delimited JSON so we only look at
// text the agent itself produced — never at URLs it was merely shown. Two sources qualify:
//   • assistant message text blocks (the agent's own output — where it pastes a PR/Artifact URL)
//   • Artifact-tool results, which arrive as a user-role tool_result reading "Published … at
//     <url>" (also HERD_PR/HERD_ARTIFACT markers from /herd-issues children).
// Everything else — user prompts, file attachments, tool INPUTS, and read/fetch tool_results that
// merely echo a URL the agent was asked to read — is skipped. This is the §2 fix: the old raw
// regex over the whole slice flagged a parent's Artifact URL as the *child's* deliverable just
// because the child was made to read it.
func linksFromTranscriptSlice(_ text: String) -> [AgentLink] {
    var links: [AgentLink] = []
    // Artifact tool_use inputs, keyed by tool_use_id: the favicon (emoji) + description we pair with
    // the "Published … at <url>" tool_result the tool emits (A1). Verified in real transcripts: the
    // tool_use (with input.favicon / input.description) always precedes its tool_result in file order.
    var artifactMeta: [String: (favicon: String?, title: String?)] = [:]
    func absorb(_ s: String) {
        guard !s.isEmpty else { return }
        for link in linksFromText(s) where !links.contains(where: { $0.url == link.url }) { links.append(link) }
    }
    // Upsert an Artifact link with its favicon/title. Redeploys reuse the same URL (same file_path),
    // so a later publish's favicon/title overrides the earlier one for that URL.
    func absorbArtifact(url: String, favicon: String?, title: String?) {
        guard let u = validHTTPURL(url) else { return }
        let abs = u.absoluteString
        if let i = links.firstIndex(where: { $0.url == abs }) {
            links[i] = AgentLink(label: "Artifact", url: abs, favicon: favicon ?? links[i].favicon, title: title ?? links[i].title)
        } else {
            links.append(AgentLink(label: "Artifact", url: abs, favicon: favicon, title: title))
        }
    }
    for line in text.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String,
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { continue }
        if type == "assistant" {
            for block in content {
                let bt = block["type"] as? String
                if bt == "text" {
                    if let t = block["text"] as? String {
                        // Fenced ``` blocks are QUOTED material (fixtures, docs, examples), not the
                        // agent reporting its own deliverable — an agent explaining this extractor
                        // quoted a fixture marker and put a fake 404 link on its own card
                        // (2026-07-08). Splitting on ``` leaves prose at even indices; odd indices
                        // (inside a fence, incl. after an unclosed opener) are dropped.
                        let prose = t.components(separatedBy: "```").enumerated()
                            .filter { $0.offset % 2 == 0 }.map { $0.element }.joined(separator: "\n")
                        absorb(prose)
                    }
                } else if bt == "tool_use", (block["name"] as? String) == "Artifact",
                          let id = block["id"] as? String, let input = block["input"] as? [String: Any] {
                    let fav = (input["favicon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let desc = (input["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    artifactMeta[id] = (fav?.isEmpty == false ? fav : nil, desc?.isEmpty == false ? desc : nil)
                }
            }
        } else if type == "user" {
            for block in content where (block["type"] as? String) == "tool_result" {
                let s = toolResultText(block["content"])
                let id = block["tool_use_id"] as? String
                // NOTE: HERD_PR / HERD_ARTIFACT markers in a tool_result are deliberately NOT
                // trusted. A tool_result is text the agent merely READ, and a file that happens to
                // carry the markers (Shepherd's own test fixtures, docs) would put a 404 Artifact
                // link on the card. Markers count only in the agent's own assistant text.
                // The Artifact tool's own acknowledgement is "Published <path> at <url>" — but the
                // shape alone isn't proof: Shepherd's own test fixtures contain that literal line,
                // and sed/Read-ing them put a fake link on the card (2026-07-08). So it counts ONLY
                // when the result pairs (via tool_use_id) with an Artifact tool_use seen in this
                // slice. A pairing missed across a delta-scan boundary costs just favicon/title:
                // the agent announces the URL in prose too, which the assistant-text path absorbs.
                guard let id = id, let meta = artifactMeta[id] else { continue }
                for url in allMatchStrings("Published .*? at (https?://\\S+)", in: s) {
                    absorbArtifact(url: url, favicon: meta.favicon, title: meta.title)
                }
            }
        }
    }
    return links
}

// Deliverable links straight from a session's transcript jsonl — the path that works for
// zellij / bare-terminal rows (no herdr pane) and as a fallback for herdr rows whose links
// have scrolled out of the screen read window. Reads only bytes appended since the last call
// (offset cached per session); the very first read of a session scans up to the trailing
// transcriptScanTail so a finished session's whole recent history of deliverables is caught in
// one pass, and every read after that is just the newly-appended delta. New links merge into the
// accumulated cache, so a link found once survives even after it scrolls out of the window.
let transcriptScanTail: UInt64 = 4 * 1024 * 1024
func extractLinksFromTranscript(cwd: String, sessionId: String) -> [AgentLink] {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return [] }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    factsLock.lock()
    let cached = transcriptLinksCache[sessionId]
    factsLock.unlock()
    guard let fh = FileHandle(forReadingAtPath: path) else { return cached?.links ?? [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    // Start from wherever we stopped last time; but never before the trailing tail window, and
    // clamp to 0 if the file was truncated/rotated (offset now past EOF).
    var start = cached?.offset ?? 0
    if start > size { start = 0 }
    if size > transcriptScanTail { start = max(start, size - transcriptScanTail) }
    if start >= size { return cached?.links ?? [] }   // nothing new
    guard (try? fh.seek(toOffset: start)) != nil,
          let data = try? fh.readToEnd() else {
        return cached?.links ?? []
    }
    let text = String(decoding: data, as: UTF8.self)
    var merged = cached?.links ?? []
    for link in linksFromTranscriptSlice(text) {
        if let i = merged.firstIndex(where: { $0.url == link.url }) {
            // A later slice may carry the favicon/title (A1) for a URL first seen bare — enrich it.
            if merged[i].favicon == nil, link.favicon != nil { merged[i].favicon = link.favicon }
            if link.title != nil { merged[i].title = link.title }
        } else {
            merged.append(link)
        }
    }
    factsLock.lock()
    transcriptLinksCache[sessionId] = (merged, size)
    factsLock.unlock()
    return merged
}

// Fork fingerprint: the timestamp of a session's FIRST user message, read from the transcript
// HEAD. A --fork-session / /branch / /rewind copies the origin's history verbatim into a new
// session id, so a fork and its origin carry the byte-identical first-message timestamp — the one
// definitive, file-based proof (there is no fork flag in the status file) that two session ids are
// the same conversation. The first user message sits near the top (right after the ai-title line),
// so 256KB of head covers even a large first paste. Immutable once written → cached forever.
func firstUserMessageStamp(cwd: String, sessionId: String) -> String? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    // Lossy decode: a 256KB head can cut a multi-byte char at the boundary — the first user line is
    // far earlier than that, so a replacement char at the tail of the chunk is harmless.
    guard let data = try? fh.read(upToCount: 262_144), !data.isEmpty else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == "user",
              let ts = (obj["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces), !ts.isEmpty
        else { continue }
        return ts
    }
    return nil
}

// Fork fingerprint, cached for the process lifetime (the first message never changes; "" caches a
// transcript-less session so it isn't re-read every poll).
func transcriptForkKey(cwd: String, sessionId: String) -> String? {
    guard !sessionId.isEmpty else { return nil }
    factsLock.lock()
    let c = forkKeyCache[sessionId]
    factsLock.unlock()
    if let c = c { return c.isEmpty ? nil : c }
    let stamp = firstUserMessageStamp(cwd: cwd, sessionId: sessionId) ?? ""
    factsLock.lock()
    forkKeyCache[sessionId] = stamp
    factsLock.unlock()
    return stamp.isEmpty ? nil : stamp
}

// A display-worthy user prompt: trimmed, single-line, and not one of Claude Code's machine
// messages (task notifications, slash-command wrappers, injected reminders — all `<…>`-tagged).
func cleanUserPrompt(_ raw: String?) -> String? {
    guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
          !s.hasPrefix("<"), !s.hasPrefix("Caveat:") else { return nil }
    s = s.replacingOccurrences(of: "\n", with: " ")
    return String(s.prefix(120))
}

// Fallback "what is this session" line for a row whose hook last_prompt is empty (matrix §3 P2):
// the most recent genuine user instruction from the transcript tail, else the sessions-index
// firstPrompt. Cached per session ("" = confirmed nothing) so it isn't re-scanned every poll.
func activityFallback(cwd: String, sessionId: String) -> String? {
    factsLock.lock()
    let c = activityFallbackCache[sessionId]
    factsLock.unlock()
    if let c = c { return c.isEmpty ? nil : c }
    let resolved = lastUserPromptFromTranscript(cwd: cwd, sessionId: sessionId)
                ?? cleanUserPrompt(firstPromptFromSessionsIndex(cwd: cwd, sessionId: sessionId))
    factsLock.lock()
    activityFallbackCache[sessionId] = resolved ?? ""
    factsLock.unlock()
    return resolved
}

// Scan a transcript's tail backward for the last real user prompt — a plain-text user message,
// skipping tool_result turns and Claude Code's own machine messages.
func lastUserPromptFromTranscript(cwd: String, sessionId: String) -> String? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return nil }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == "user",
              let msg = obj["message"] as? [String: Any] else { continue }
        var prompt: String? = nil
        if let s = msg["content"] as? String { prompt = s }
        else if let blocks = msg["content"] as? [[String: Any]] {
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { continue }  // a tool turn, not a prompt
            let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { prompt = texts.joined(separator: " ") }
        }
        if let cleaned = cleanUserPrompt(prompt) { return cleaned }
    }
    return nil
}

// The AI-generated session title Claude Code streams to the terminal via OSC — the exact string
// zellij shows as the pane title. Claude Code also appends it to the transcript as
// {"type":"ai-title","aiTitle":"…"} on every title update, so the last such line in the tail IS
// the current pane title. Rewritten roughly every prompt, it sits well within the trailing 256KB
// (measured 5–28KB from EOF across real sessions).
func readTranscriptAITitle(cwd: String, sessionId: String) -> String? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return nil }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"ai-title\""),
              let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == "ai-title" else { continue }
        let title = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = title, !title.isEmpty { return title }
    }
    return nil
}

// AI title, cached ~20s per session (same cadence as transcriptCtx — the title changes at most
// once per prompt). nil results are cached too, so hookless / pre-ai-title sessions aren't
// re-scanned every poll within the window.
func transcriptAITitle(cwd: String, sessionId: String) -> String? {
    guard !sessionId.isEmpty else { return nil }
    factsLock.lock()
    let c = aiTitleCache[sessionId]
    factsLock.unlock()
    if let c = c, Date().timeIntervalSince(c.at) < 20 { return c.title }
    let title = readTranscriptAITitle(cwd: cwd, sessionId: sessionId)
    factsLock.lock()
    aiTitleCache[sessionId] = (title, Date())
    factsLock.unlock()
    return title
}

// The latest assistant message text from a transcript tail — used to preview what a blocked zellij
// session is asking (the herdr "read the pane" path isn't available there, B2). Best-effort: the
// question is usually in or just before the last assistant turn; the user can jump to see the rest.
func lastAssistantTextFromTranscript(cwd: String, sessionId: String) -> String? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return nil }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let msg = obj["message"] as? [String: Any],
              let blocks = msg["content"] as? [[String: Any]] else { continue }
        let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return joined }
    }
    return nil
}

// Render a pending AskUserQuestion / ExitPlanMode tool_use input as the text the user is being
// asked. Pure formatting, split out for tests; unknown tool names return nil so the caller can
// fall back. The input is the SOURCE of the on-screen prompt, so unlike the retired herdr screen
// scrape (`agent read` + cleanPrompt heuristics) there is no TUI chrome to strip.
func formatBlockedPrompt(name: String, input: [String: Any]) -> String? {
    switch name {
    case "AskUserQuestion":
        guard let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }
        var out: [String] = []
        for q in questions {
            guard let text = q["question"] as? String, !text.isEmpty else { continue }
            if !out.isEmpty { out.append("") }
            out.append(text)
            for (i, o) in ((q["options"] as? [[String: Any]]) ?? []).enumerated() {
                guard let label = o["label"] as? String else { continue }
                let desc = (o["description"] as? String).map { " — \($0)" } ?? ""
                out.append("  \(i + 1). \(label)\(desc)")
            }
            if (q["multiSelect"] as? Bool) == true { out.append("  " + L("（複数選択可）", "(multi-select)")) }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    case "ExitPlanMode":
        let plan = (input["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ([L("計画の承認待ち:", "waiting for plan approval:")] + (plan.isEmpty ? [] : [plan]))
            .joined(separator: "\n\n")
    default:
        return nil
    }
}

// The question a blocked session is waiting on, from the transcript (P3, 2026-07-10). A genuinely
// pending prompt is the NEWEST main-chain assistant record, and its tool_use input carries the
// question + options verbatim. Only that newest record is consulted: if it isn't an
// AskUserQuestion / ExitPlanMode (say, a tool call stuck at a permission prompt), this returns nil
// and the caller previews the last assistant text instead — conservative, never shows a stale
// question from an earlier turn.
func blockedPromptFromTranscript(cwd: String, sessionId: String) -> String? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return nil }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["isSidechain"] as? Bool) != true,
              (obj["type"] as? String) == "assistant",
              let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        for b in blocks where (b["type"] as? String) == "tool_use" {
            if let name = b["name"] as? String, let input = b["input"] as? [String: Any],
               let formatted = formatBlockedPrompt(name: name, input: input) {
                return formatted
            }
        }
        return nil   // newest assistant record isn't a question prompt — nothing pending to show
    }
    return nil
}

// The transcript's own verdict on an AskUserQuestion / ExitPlanMode prompt: `.none` (no question),
// `.pending` (a question with nothing after it — Claude is waiting), or `.resolved` (a user turn
// follows the newest question — its tool_result / answer, or a Ctrl+C "[Request interrupted…]", both
// user-role). Both edges are load-bearing:
//   • `.resolved` clears a stale `blocked` the user dismissed with Ctrl+C — no hook fires on cancel,
//     so a hook `blocked` would otherwise stick and the card never leaves "blocked" (2026-07-09).
//   • `.pending` is the ONLY blocked signal for a VS Code extension session: it records the open
//     prompt in its transcript but never writes a registry `status` (the extension runs claude in
//     SDK stream-json mode, where the permission/question handshake rides the SDK stream, not the
//     registry — measured 2026-07-12). Only AskUserQuestion / ExitPlanMode count, so a plain tool_use
//     stuck at a permission decision (indistinguishable from one mid-execution) is never `.pending`.
// Conservative by design: `.resolved` needs positive evidence (a real pending prompt is never
// cleared) and `.pending` needs a question tool_use (a working session never reads as blocked).
enum TranscriptBlockState { case none, pending, resolved }

// Cached on the transcript's size + mtime — the verdict can only change when the file grows, and this
// is called for every candidate row on every refresh (FSEvents fire a refresh on each tool use), so a
// stat beats re-reading 256KB each time.
func blockedState(cwd: String, sessionId: String) -> TranscriptBlockState {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return .none }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    let fileMtime = attrs?[.modificationDate] as? Date ?? .distantPast
    factsLock.lock()
    let cached = blockedStateCache[sessionId]
    factsLock.unlock()
    if let c = cached, c.size == fileSize, c.mtime == fileMtime { return c.state }

    let verdict = blockedStateUncached(path: path)
    factsLock.lock()
    blockedStateCache[sessionId] = (fileSize, fileMtime, verdict)
    factsLock.unlock()
    return verdict
}

// A `blocked` the transcript proves was answered or Ctrl+C-cancelled — clears a stale block.
func blockedResolved(cwd: String, sessionId: String) -> Bool {
    blockedState(cwd: cwd, sessionId: sessionId) == .resolved
}

// An open AskUserQuestion / ExitPlanMode — the positive block signal for a session no live source
// reports blocked for (a VS Code extension session, which writes no registry status).
func blockedPending(cwd: String, sessionId: String) -> Bool {
    blockedState(cwd: cwd, sessionId: sessionId) == .pending
}

// Is a status-less session's newest turn still in flight? A VS Code extension session reports no
// busy/idle at all — neither the registry nor `claude agents` carries the field, because the
// extension runs claude in SDK stream-json mode where the token-level activity (message_start /
// content_block_delta / result) rides the stdout pipe to the extension and is never written to disk
// (the transcript holds only turn-boundary records — measured 2026-07-12). So the coarsest on-disk
// signal is all there is: the turn is IN FLIGHT when the newest main-chain record is a user message
// (a prompt, or a tool_result Claude hasn't answered yet) or an assistant record that hasn't ended;
// it is FINISHED when the newest main-chain assistant record's stop_reason is "end_turn". stop_reason
// is the crisp edge for a MAIN session (unlike a teammate's — see subagentTail — the main chain
// stamps end_turn on every finished turn and tool_use mid-turn, verified across a live claude-vscode
// session), so a mid-turn thinking-only record no longer misreads as idle. nil = can't tell (no
// transcript, or no main-chain turn yet). Uncached: a working session's transcript changes every
// event, so a size/mtime cache would never hit, and only the few status-less rows ever call this.
//
// Note there's an inherent floor: while Claude streams a response, NOTHING is appended to the
// transcript (measured: a ~7s gap between the user record and the first assistant record), so the
// card can only re-evaluate at record boundaries, not token-by-token, and transcript mtime freshness
// is useless (it would read idle during those streaming gaps).
func transcriptTurnActive(cwd: String, sessionId: String) -> Bool? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return nil }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["isSidechain"] as? Bool) != true else { continue }
        switch obj["type"] as? String {
        case "assistant":
            // A synthetic API-error record (isApiErrorMessage) carries no stop_reason but IS a
            // finished turn — read it as idle so the caller's idle→error upgrade (transcriptErrored)
            // can fire. A status-less session has no registry "idle" to trigger that otherwise, so
            // without this an errored VS Code session would sit at "working" forever.
            if (obj["isApiErrorMessage"] as? Bool) == true { return false }
            return (obj["message"] as? [String: Any])?["stop_reason"] as? String != "end_turn"
        case "user":
            // A prompt or a tool_result Claude hasn't answered yet — working. (A Ctrl+C interrupt is
            // also user-role, so an interrupted-then-idle session reads as working until the next
            // record lands; accepted, same lagging-transcript ambiguity as the rest of this path.)
            return true
        default:
            continue   // meta rows (ai-title, last-prompt, queue-operation, …) — keep scanning
        }
    }
    return nil
}

// MARK: - Teammate idle notifications
//
// When an in-process teammate (agent teams) ends a turn, the LEAD session's transcript gets a user
// record whose content embeds a machine-readable event (measured on party-game, 2026-07-14):
//
//   <teammate-message teammate_id="catalog-crokinole" color="blue">
//   {"type":"idle_notification","from":"catalog-crokinole","timestamp":"…","idleReason":"available"}
//   </teammate-message>
//
// This is the only durable "this teammate is DONE" fact anywhere on disk: the teammate's own jsonl
// tail can't distinguish a finished report from a mid-turn narration line ("now I'll write the
// file…") followed by minutes of tool-call generation — both end in a text block with a null
// stop_reason. The lead itself has misread that tail and spawned a duplicate teammate, so the
// notification is what the harness actually trusts.
//
// Caveat: the record lands in the lead transcript with a delay (measured 15ms while the lead is
// idle, up to ~2min while it is mid-turn), so "idle" detection can lag by that much. The error is
// on the safe side — a finished teammate briefly keeps its working card, never the reverse.

// The latest idle_notification per teammate name found in a transcript slice. Pure, testable.
func teammateIdlesFromSlice(_ text: String) -> [String: Date] {
    var out: [String: Date] = [:]
    for line in text.split(separator: "\n") where line.contains("idle_notification") {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == "user",
              let msg = obj["message"] as? [String: Any] else { continue }
        var content = ""
        if let s = msg["content"] as? String { content = s }
        else if let blocks = msg["content"] as? [[String: Any]] {
            content = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        // The event JSON sits on its own line inside the <teammate-message> wrapper.
        for inner in content.split(separator: "\n") where inner.hasPrefix("{") {
            guard let id = inner.data(using: .utf8),
                  let n = (try? JSONSerialization.jsonObject(with: id)) as? [String: Any],
                  (n["type"] as? String) == "idle_notification",
                  let from = n["from"] as? String,
                  let at = parseUsageISODate(n["timestamp"] as? String) else { continue }
            if let prev = out[from], prev >= at { continue }
            out[from] = at
        }
    }
    return out
}

// Latest idle_notification per teammate name from the lead's transcript. Incremental like
// extractLinksFromTranscript: the first read scans up to the trailing transcriptScanTail, every
// read after that only the newly-appended bytes; results accumulate per session.
func teammateIdleTimes(cwd: String, sessionId: String) -> [String: Date] {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return [:] }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    factsLock.lock()
    let cached = teammateIdleCache[sessionId]
    factsLock.unlock()
    guard let fh = FileHandle(forReadingAtPath: path) else { return cached?.idleAt ?? [:] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    var start = cached?.offset ?? 0
    if start > size { start = 0 }   // truncated/rotated
    if size > transcriptScanTail { start = max(start, size - transcriptScanTail) }
    if start >= size { return cached?.idleAt ?? [:] }   // nothing new
    guard (try? fh.seek(toOffset: start)) != nil,
          let data = try? fh.readToEnd() else { return cached?.idleAt ?? [:] }
    var merged = cached?.idleAt ?? [:]
    for (from, at) in teammateIdlesFromSlice(String(decoding: data, as: UTF8.self)) {
        if let prev = merged[from], prev >= at { continue }
        merged[from] = at
    }
    factsLock.lock()
    teammateIdleCache[sessionId] = (merged, size)
    factsLock.unlock()
    return merged
}

// Is a teammate still working? The teammate's own jsonl tail plays no part here — a text tail can
// be a mid-turn narration and a tool_use tail can be a killed turn, so it proves nothing either
// way. Two facts decide: the idle_notification is authoritative when it is fresher than the
// teammate's jsonl (nothing happened since the harness said "idle"; a jsonl write after it means
// the teammate was re-activated by a new message), and 30 minutes of jsonl silence reads as idle —
// the backstop for a teammate killed without a notification (the longest live tool-call generation
// gap measured on party-game was ~8 min, so 30 min is comfortably past a live one).
//
// The 2s tolerance absorbs the flush order at turn end: the final jsonl records land milliseconds
// BEFORE the notification's event timestamp, but mtime granularity can round past it.
func teammateWorking(idleAt: Date?, jsonlMtime: Date?, now: Date = Date()) -> Bool {
    if let idleAt, let m = jsonlMtime, idleAt.addingTimeInterval(2) >= m { return false }
    if let m = jsonlMtime, now.timeIntervalSince(m) > 1800 { return false }
    return true
}

// The session's subagents, from Claude Code's own per-agent files rather than the status hook's
// SubagentStart/Stop bookkeeping (2026-07-10). Each spawned agent leaves two files under
// <projects>/<sanitized-cwd>/<session-id>/subagents/:
//   agent-<id>.meta.json — {"agentType":…,"name":…,"description":…,"worktreePath":…,
//                           "worktreeBranch":…,"toolUseId":…,"spawnDepth":…} (worktree keys only
//                           when spawned with isolation; measured 2026-07-10)
//   agent-<id>.jsonl     — its own turn-by-turn transcript, written live while it runs
// State comes from the last record of that jsonl: an agent that finished ends with an assistant
// message whose stop_reason is "end_turn"; one still working ends mid-turn (stop_reason "tool_use",
// a thinking block, a pending tool_result). Measured on a live pair, 2026-07-10.
// For in-process teammates that tail is ambiguous (see teammateWorking above), so their state is
// ruled by the lead transcript's idle_notification instead (party-game, 2026-07-14).
//
// Note the parent's own tool_result can't answer this: an async agent is answered IMMEDIATELY with
// {"status":"async_launched"} and keeps running for minutes.
func subagentsFromTranscript(cwd: String, sessionId: String) -> [SubagentRecord] {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return [] }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let subagents = ((dir as NSString).appendingPathComponent(sessionId) as NSString)
        .appendingPathComponent("subagents")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: subagents) else { return [] }
    let fm = FileManager.default
    func mtime(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
    // Lead-transcript idle notifications, fetched once per call and only when a teammate needs them.
    var idleTimes: [String: Date]?
    var out: [SubagentRecord] = []
    for name in names.sorted() where name.hasPrefix("agent-") && name.hasSuffix(".meta.json") {
        let metaPath = (subagents as NSString).appendingPathComponent(name)
        var meta: [String: Any] = [:]
        if let data = fm.contents(atPath: metaPath),
           let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { meta = m }
        func metaString(_ key: String) -> String? {
            (meta[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var rec = SubagentRecord(agentId: String(name.dropFirst("agent-".count)
                                                     .dropLast(".meta.json".count)),
                                 type: metaString("agentType") ?? "agent")
        rec.name = metaString("name")
        rec.description = metaString("description")
        rec.worktreePath = metaString("worktreePath")
        rec.worktreeBranch = metaString("worktreeBranch")
        rec.model = metaString("model")
        let jsonl = (subagents as NSString)
            .appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
        let tail = subagentTail(path: jsonl)
        // The 30-min silence backstop guards plain subagents too: one killed mid tool-call leaves
        // a tool_use tail forever, and a truncated read must not stick a card "working" for hours
        // (genome, 2026-07-16). teammateWorking with no notification is exactly that backstop.
        rec.working = !tail.finished && teammateWorking(idleAt: nil, jsonlMtime: mtime(jsonl))
        if (meta["taskKind"] as? String) == "in_process_teammate", let agentName = rec.name {
            if idleTimes == nil { idleTimes = teammateIdleTimes(cwd: cwd, sessionId: sessionId) }
            rec.working = teammateWorking(idleAt: idleTimes?[agentName], jsonlMtime: mtime(jsonl))
        }
        rec.activity = tail.activity
        rec.startedAt = mtime(metaPath)
        rec.updatedAt = mtime(jsonl)
        out.append(rec)
    }
    return out
}

// An agent's state + current activity, from a 256KB tail of its own jsonl (a missing or unreadable
// file reads as "still working", the safe side of a wrong guess — the card mirrors a green rail
// that says "look at me" rather than hiding). The window must comfortably exceed a single record:
// an Explore agent's closing report is one 17–25KB line (genome, 2026-07-16), and a window smaller
// than the final record starts mid-JSON, parses nothing, and reports "working" forever.
//
// finished: the agent's newest assistant record ends with a TEXT block — it wrote a reply and
// isn't mid-tool. `stop_reason` looked like the signal but isn't reliable: a plain subagent stamps
// "end_turn", an in-process teammate "stop_sequence", and a teammate that writes its final report
// and then just stops leaves it null entirely (measured 2026-07-10: those last two both stuck every
// teammate "working"). What holds across all of them: a turn still in flight ends with a `tool_use`
// block (a call awaiting its result) or a bare `thinking` block, and a finished one ends with text.
//
// activity: the agent's own account of what it's doing — the tool it's mid-call on while working
// ("⚙ Bash: ./test.sh"), or its closing words once done. This is what the caller-given name can't
// give: it's in the words the agent is actually using, so a Japanese task reads in Japanese.
func subagentTail(path: String) -> (finished: Bool, activity: String?) {
    guard let fh = FileHandle(forReadingAtPath: path) else { return (false, nil) }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return (false, nil) }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return (false, nil) }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        let finished = (blocks.last?["type"] as? String) == "text"
        // Working → the tool it's mid-call on; finished → its closing words. First non-empty wins.
        var activity: String?
        if !finished, let call = blocks.last(where: { ($0["type"] as? String) == "tool_use" }) {
            activity = subagentToolLabel(name: call["name"] as? String, input: call["input"] as? [String: Any])
        }
        if activity == nil {
            let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            activity = firstLine(text)
        }
        return (finished, activity)
    }
    return (false, nil)
}

// A one-line "⚙ <tool>: <what>" for a tool_use, naming the argument that says the most (the command,
// the file, the pattern). Unknown tools just show their name. nil only when there's no tool at all.
private func subagentToolLabel(name: String?, input: [String: Any]?) -> String? {
    guard let name = name else { return nil }
    let arg = ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"]
        .lazy.compactMap { input?[$0] as? String }.first { !$0.isEmpty }
    let detail = arg.map { firstLine($0) ?? $0 }
    return detail.map { "⚙ \(name): \($0)" } ?? "⚙ \(name)"
}

private func firstLine(_ s: String) -> String? {
    let line = s.split(whereSeparator: \.isNewline).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces)
    guard let line = line, !line.isEmpty else { return nil }
    return line.count > 100 ? String(line.prefix(100)) + "…" : line
}

// The transcript's own record of what the hook used to report: the session's permission mode and the
// user's last instruction. Claude Code appends a bare `permission-mode` / `last-prompt` line each
// time either changes, so the newest one in the tail is the current value.
func transcriptTailValue(cwd: String, sessionId: String, type: String, field: String) -> String? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return nil }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return nil }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == type, let v = obj[field] as? String, !v.isEmpty else { continue }
        return v
    }
    return nil
}

// Did this session's last turn die on an API error? Claude Code records one as a synthetic
// main-chain assistant message carrying `isApiErrorMessage: true` (model "<synthetic>", text
// "API Error: …" / "You've hit your session limit …") — the same event that fires the StopFailure
// hook Shepherd renders as `error`. Reading it here gives a hook-less session that state too.
//
// Only the NEWEST main-chain assistant record counts: an error the session went on to recover from
// is history, and the turns after it prove the recovery. Sidechain records are subagent turns — a
// subagent's API error is not the session's state.
func transcriptErrored(cwd: String, sessionId: String) -> Bool {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return false }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    let fileMtime = attrs?[.modificationDate] as? Date ?? .distantPast
    factsLock.lock()
    let cached = transcriptErrorCache[sessionId]
    factsLock.unlock()
    if let c = cached, c.size == fileSize, c.mtime == fileMtime { return c.errored }

    let verdict = transcriptErroredUncached(path: path)
    factsLock.lock()
    transcriptErrorCache[sessionId] = (fileSize, fileMtime, verdict)
    factsLock.unlock()
    return verdict
}

private func transcriptErroredUncached(path: String) -> Bool {
    guard let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return false }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return false }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["isSidechain"] as? Bool) != true,
              (obj["type"] as? String) == "assistant" else { continue }
        return (obj["isApiErrorMessage"] as? Bool) == true
    }
    return false
}

private func blockedStateUncached(path: String) -> TranscriptBlockState {
    guard let fh = FileHandle(forReadingAtPath: path) else { return .none }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    if size > 262_144, (try? fh.seek(toOffset: size - 262_144)) == nil { return .none }
    else if size <= 262_144 { try? fh.seek(toOffset: 0) }
    guard let data = try? fh.readToEnd() else { return .none }
    let text = String(decoding: data, as: UTF8.self)
    var lastQuestion = -1, lastUserAfter = -1, i = 0
    for line in text.split(separator: "\n") {
        defer { i += 1 }
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["isSidechain"] as? Bool) != true else { continue }
        switch obj["type"] as? String {
        case "assistant":
            if let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]],
               blocks.contains(where: { ($0["type"] as? String) == "tool_use"
                   && ["AskUserQuestion", "ExitPlanMode"].contains($0["name"] as? String ?? "") }) {
                lastQuestion = i
            }
        case "user":
            lastUserAfter = i
        default:
            break
        }
    }
    if lastQuestion < 0 { return .none }
    return lastUserAfter > lastQuestion ? .resolved : .pending
}

// firstPrompt from ~/.claude/projects/<sanitized>/sessions-index.json (entries[].firstPrompt),
// matched by session id — the last-resort label when the transcript has no readable prompt.
func firstPromptFromSessionsIndex(cwd: String, sessionId: String) -> String? {
    guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("sessions-index.json")
    guard let data = FileManager.default.contents(atPath: path),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let entries = obj["entries"] as? [[String: Any]] else { return nil }
    for e in entries where (e["sessionId"] as? String) == sessionId {
        if let p = e["firstPrompt"] as? String, !p.isEmpty { return p }
    }
    return nil
}

// Model + context %, cached ~20s (transcripts change slower than a poll). Shared by the herdr
// and status-only paths.
func transcriptCtx(cwd: String, sessionId: String) -> (model: ModelInfo?, pct: Double?, advisor: ModelInfo?) {
    guard !sessionId.isEmpty else { return (nil, nil, nil) }
    factsLock.lock()
    let c = contextCache[sessionId]
    factsLock.unlock()
    if let c = c, Date().timeIntervalSince(c.at) < 20 { return (c.model, c.pct, c.advisor) }
    let info = readTranscriptContext(cwd: cwd, sessionId: sessionId)
    factsLock.lock()
    contextCache[sessionId] = (info.model, info.pct, info.advisor, Date())
    factsLock.unlock()
    return info
}
