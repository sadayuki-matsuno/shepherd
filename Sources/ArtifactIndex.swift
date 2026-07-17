import Foundation

// MARK: - Artifact shelf index (2026-07-17)
//
// A persistent, account-wide index of the user's Claude Artifacts, merged from two sources:
//   源A — the account enumeration API: GET api.anthropic.com/api/frame/frames?limit=50
//         (Artifacts are "frames" internally; found in the claude CLI's Artifact-list tool).
//         Canonical for title / updatedAt / softDeleted, covers other machines and claude.ai,
//         but its window is the ~50 most recently updated artifacts — never "all of them".
//   源B — incremental transcript scans of ~/.claude/projects/**/*.jsonl for tool-paired
//         "Published … at <url>" acknowledgements (artifactPublishesFromSlice). Catches what
//         fell out of the API window, and carries the context the API lacks: which repo /
//         session published it (favicon, cwd).
// Records merge on the slug (the URL's trailing UUID) and are append-only: an artifact observed
// once never vanishes from the index — the API's softDeleted merely dims it. Both sources are
// additive: either one failing leaves the shelf running on the other.
//
// The frames endpoint is a PRIVATE API — same discipline as oauth/usage: parse defensively,
// return nil on any surprise (the shelf degrades to the transcript source), never let a shape
// change break the board.

struct ArtifactRecord: Codable, Equatable {
    let slug: String          // merge key (URL's trailing UUID, lowercased)
    var url: String           // https://claude.ai/code/artifact/<slug>
    var title: String?        // API title wins; else the publish tool_use's description
    var favicon: String?      // the artifact's emoji face — transcript wins, API fills gaps
    var repoName: String?     // transcript source: repo attribution resolved from the line's cwd
    var updatedAt: Date?      // API wins; transcript source uses the tool_result line's timestamp
    var softDeleted: Bool = false   // API only; true renders dimmed (never hidden)
    var lastSeenInAPI: Date?  // nil = outside the API window, or transcript-only so far
}

// The URL's trailing UUID — the slug the frames API keys on. nil for non-artifact URLs.
func artifactSlug(from url: String) -> String? {
    let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    return lastMatchString("(\(uuid))$", in: url)?.lowercased()
}

// One entry of the frames API response, parsed defensively. Live shape (probe 2026-07-17):
// slug / title / favicon / label / description / rel / updatedAt (ISO) / created_at /
// view_count / audience — softDeleted is absent on live rows (present only when true).
struct FrameEntry: Equatable {
    let slug: String
    let title: String?
    let favicon: String?      // the artifact's emoji face — the API carries it too
    let rel: String?          // "mine" is what the CLI keeps
    let updatedAt: Date?
    let softDeleted: Bool
}

func parseFrames(_ obj: Any?) -> [FrameEntry]? {
    // Accept both a bare array and a {frames:[…]} / {data:[…]} wrapper.
    let arr: [[String: Any]]
    if let a = obj as? [[String: Any]] { arr = a }
    else if let d = obj as? [String: Any], let a = (d["frames"] ?? d["data"]) as? [[String: Any]] { arr = a }
    else { return nil }
    return arr.compactMap { o in
        guard let slug = ((o["slug"] ?? o["id"] ?? o["uuid"]) as? String)?.lowercased(), !slug.isEmpty
        else { return nil }
        var updated: Date?
        if let s = (o["updatedAt"] ?? o["updated_at"]) as? String { updated = parseUsageISODate(s) }
        else if let n = (o["updatedAt"] ?? o["updated_at"]) as? NSNumber {
            let v = n.doubleValue
            updated = Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)   // epoch ms vs s
        }
        return FrameEntry(slug: slug,
                          title: (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          favicon: (o["favicon"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          rel: o["rel"] as? String,
                          updatedAt: updated,
                          softDeleted: (o["softDeleted"] as? Bool) ?? (o["soft_deleted"] as? Bool) ?? false)
    }
}

// Merge rules (design §3): title / updatedAt / softDeleted are the API's to decide; favicon /
// repoName are the transcript's. Both pure, unit-tested.
func mergedRecord(_ rec: ArtifactRecord?, frame: FrameEntry, at: Date = Date()) -> ArtifactRecord {
    var r = rec ?? ArtifactRecord(slug: frame.slug, url: "https://claude.ai/code/artifact/\(frame.slug)")
    if let t = frame.title { r.title = t }
    if r.favicon == nil { r.favicon = frame.favicon }   // transcript's favicon wins; API fills gaps
    if let u = frame.updatedAt { r.updatedAt = u }
    r.softDeleted = frame.softDeleted
    r.lastSeenInAPI = at
    return r
}

func mergedRecord(_ rec: ArtifactRecord?, publish: ArtifactPublish, repoName: String?) -> ArtifactRecord? {
    guard let slug = artifactSlug(from: publish.url) else { return nil }
    var r = rec ?? ArtifactRecord(slug: slug, url: publish.url)
    if let f = publish.favicon { r.favicon = f }
    if let n = repoName { r.repoName = n }
    if r.title == nil { r.title = publish.title }
    // updatedAt: the API's word is canonical; a transcript publish only moves it while the record
    // has never been seen in the API window (and only forward).
    if r.lastSeenInAPI == nil, let ts = publish.timestamp.flatMap(parseUsageISODate) {
        if r.updatedAt.map({ ts > $0 }) ?? true { r.updatedAt = ts }
    }
    return r
}

// Repo attribution from a publishing session's cwd, without git: a Shepherd-convention worktree
// lives under <repo>/.claude/worktrees/<name>, so the component before "/.claude/worktrees" is the
// repo; otherwise the last path component. The scanner upgrades this via `git --git-common-dir`
// when the directory still exists (deleted worktrees fall back here).
func repoNameFromPath(_ cwd: String) -> String? {
    guard !cwd.isEmpty else { return nil }
    if let range = cwd.range(of: "/.claude/worktrees/") {
        return (String(cwd[..<range.lowerBound]) as NSString).lastPathComponent
    }
    let name = (cwd as NSString).lastPathComponent
    return name.isEmpty ? nil : name
}

// The inline artifact bar's list order: apply the repo filter (nil = all, "" = unattributed),
// then the search query (title / repo / slug prefix); pinned slugs first, then newest-updated
// first. Pure, unit-tested.
func shelfListOrder(_ records: [ArtifactRecord], pins: [String], query: String,
                    repoFilter: String? = nil) -> [ArtifactRecord] {
    var filtered = records
    if let repo = repoFilter {
        filtered = filtered.filter { repo.isEmpty ? $0.repoName == nil : $0.repoName == repo }
    }
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
        filtered = filtered.filter {
            ($0.title ?? "").lowercased().contains(q)
                || ($0.repoName ?? "").lowercased().contains(q)
                || $0.slug.hasPrefix(q)
        }
    }
    let pinSet = Set(pins)
    return filtered.sorted { a, b in
        let ap = pinSet.contains(a.slug), bp = pinSet.contains(b.slug)
        if ap != bp { return ap }
        let au = a.updatedAt ?? .distantPast, bu = b.updatedAt ?? .distantPast
        if au != bu { return au > bu }
        return a.slug < b.slug
    }
}

// "2026/07/16" / "—" — the shelf row's updated stamp (yyyy/MM/dd, 2026-07-17 user preference).
func shelfDateText(_ d: Date?) -> String {
    guard let d = d else { return "—" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy/MM/dd"
    return fmt.string(from: d)
}

// The X-Frame-* header set the CLI sends with every frame-API call (its RLe() helper, read from
// the claude binary 2026-07-17). Without them the endpoint answers 404.
let frameAPIHeaders = ["X-Frame-CP": "go", "X-Frame-Surface": "code", "X-Frame-Platform": "cli"]

// Synchronous GET against the frames endpoint with the CLI's own header set. Call off main.
func frameGET(_ path: String, token: String, extraHeaders: [String: String] = frameAPIHeaders)
    -> (status: Int, body: Data?, netErr: String?) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
    req.timeoutInterval = 20
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
    let sem = DispatchSemaphore(value: 0)
    var body: Data?; var status = -1; var netErr: String?
    URLSession.shared.dataTask(with: req) { data, resp, err in
        body = data; status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if let err = err { netErr = err.localizedDescription }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 22)
    return (status, body, netErr)
}

// Fetch the account's artifact frames. nil frames + error string on any failure — the caller
// keeps whatever index it has (stale-while-error, same contract as fetchClaudeUsage).
func fetchArtifactFrames() -> (frames: [FrameEntry]?, error: String?) {
    guard let token = claudeOAuthAccessToken() else {
        return (nil, L("トークンが読めない", "no oauth token"))
    }
    let (status, body, netErr) = frameGET("/api/frame/frames?limit=50", token: token)
    if let netErr = netErr { return (nil, netErr) }
    guard status == 200 else {
        return (nil, status == 401 ? L("要再認証（claude を起動）", "re-auth needed (run claude)") : "HTTP \(status)")
    }
    let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    guard let frames = parseFrames(obj) else { return (nil, L("形式が不明", "unexpected shape")) }
    // The CLI keeps rel == "mine"; a missing rel field passes through (additive).
    return (frames.filter { $0.rel == nil || $0.rel == "mine" }, nil)
}

// MARK: - The index store

private struct ArtifactScanState: Codable, Equatable {
    var size: UInt64
    var mtime: Date
    var offset: UInt64   // next byte to read; always at a line boundary (partial tail lines are
                         // not consumed, so a record cut mid-write is re-read next scan)
    // Artifact tool_use inputs still awaiting their tool_result — a publish can span two scans
    // (tool_use in one, result in the next), and without the carry the pair never forms.
    var carry: [String: ArtifactToolUseMeta]? = nil
}

private struct ArtifactIndexFile: Codable {
    var version: Int
    var records: [ArtifactRecord]
    var scans: [String: ArtifactScanState]
}

final class ArtifactIndex {
    static let shared = ArtifactIndex()

    // Persisted next to the app's other state. Fixture runs (SHEPHERD_PROJECTS_DIR — demo board,
    // SHEPHERD_DUMP self-checks) redirect to a scratch file so they never pollute the real index;
    // SHEPHERD_ARTIFACT_INDEX overrides explicitly (tests).
    static var indexPath: String = {
        let env = ProcessInfo.processInfo.environment
        if let p = env["SHEPHERD_ARTIFACT_INDEX"] { return p }
        if env["SHEPHERD_PROJECTS_DIR"] != nil {
            return NSTemporaryDirectory() + "shepherd-fixture-artifact-index.json"
        }
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return base + "/Shepherd/artifact-index.json"
    }()

    private let lock = NSLock()
    private var loaded = false
    private var records: [String: ArtifactRecord] = [:]
    private var scans: [String: ArtifactScanState] = [:]
    private var repoNameCache: [String: String?] = [:]   // cwd → resolved repo name (per process)
    // First-scan progress for the shelf's "走査中… N/M" line. nil = no scan running.
    private(set) var scanProgress: (done: Int, total: Int)?

    func snapshot() -> [ArtifactRecord] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return Array(records.values)
    }

    // Count without the dict copy — the collapsed ARTIFACTS bar shows only this, and it runs on
    // every rebuild (main thread).
    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return records.count
    }

    func progress() -> (done: Int, total: Int)? {
        lock.lock(); defer { lock.unlock() }
        return scanProgress
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: Self.indexPath) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(ArtifactIndexFile.self, from: data) else { return }
        records = Dictionary(file.records.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        scans = file.scans
    }

    // Snapshot under the lock, write outside it (never hold the lock across file IO).
    private func save() {
        lock.lock()
        let file = ArtifactIndexFile(version: 1, records: Array(records.values), scans: scans)
        lock.unlock()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(file) else { return }
        let dir = (Self.indexPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.indexPath), options: .atomic)
    }

    // 源A: overlay the API's frames. Returns true when anything changed (the caller repaints).
    @discardableResult
    func mergeFrames(_ frames: [FrameEntry], at: Date = Date()) -> Bool {
        lock.lock()
        loadLocked()
        var changed = false
        for f in frames {
            let old = records[f.slug]
            let merged = mergedRecord(old, frame: f, at: at)
            records[f.slug] = merged
            // Ignore the lastSeenInAPI stamp when deciding "changed" — it moves on EVERY fetch,
            // and counting it would rewrite the index file every 15 minutes for nothing. Its
            // consumers only care nil vs non-nil, so a stale persisted stamp is harmless.
            var comparable = merged
            comparable.lastSeenInAPI = old?.lastSeenInAPI
            if old != comparable { changed = true }
        }
        lock.unlock()
        if changed { save() }
        return changed
    }

    // 源B: incremental scan of every transcript under `projectsDir`. Per-file (size, mtime, offset)
    // states make re-scans read only appended bytes; the first run reads everything, so callers run
    // this on a low-priority background queue, never in the refresh pipeline. Safe to call
    // repeatedly — unchanged files cost one stat each.
    func scanTranscripts(projectsDir: String) {
        let fm = FileManager.default
        var files: [String] = []
        for dir in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
            let dirPath = (projectsDir as NSString).appendingPathComponent(dir)
            for item in (try? fm.contentsOfDirectory(atPath: dirPath)) ?? [] {
                let p = (dirPath as NSString).appendingPathComponent(item)
                if item.hasSuffix(".jsonl") {
                    files.append(p)
                } else {
                    // <session-id>/subagents/agent-*.jsonl — a subagent can publish Artifacts too.
                    let sub = (p as NSString).appendingPathComponent("subagents")
                    for s in (try? fm.contentsOfDirectory(atPath: sub)) ?? [] where s.hasSuffix(".jsonl") {
                        files.append((sub as NSString).appendingPathComponent(s))
                    }
                }
            }
        }
        lock.lock()
        loadLocked()
        scanProgress = (0, files.count)
        lock.unlock()
        var changed = false
        for (i, path) in files.enumerated() {
            if scanFile(path) { changed = true }
            lock.lock(); scanProgress = (i + 1, files.count); lock.unlock()
        }
        lock.lock(); scanProgress = nil; lock.unlock()
        if changed { save() }
    }

    private func scanFile(_ path: String) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return false }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        lock.lock()
        let state = scans[path]
        lock.unlock()
        if let s = state, s.size == size, s.mtime == mtime { return false }
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        var start = state?.offset ?? 0
        if start > size { start = 0 }   // truncated/rotated
        guard (try? fh.seek(toOffset: start)) != nil, let data = try? fh.readToEnd() else { return false }
        // Consume only COMPLETE lines: a writer caught mid-record leaves a partial tail, and
        // advancing past it would skip that record forever. Stopping the offset at the last
        // newline keeps every offset line-aligned (no UTF-8 mid-character seeks either — the
        // known tail-decode trap) and re-reads the partial line on the next mtime change.
        var consumed = data.count
        if data.last != 0x0A {
            if let lastNL = data.lastIndex(of: 0x0A) { consumed = lastNL + 1 } else { consumed = 0 }
        }
        let text = String(decoding: data.prefix(consumed), as: UTF8.self)
        var changed = false
        var carry = state?.carry ?? [:]
        let publishes = artifactPublishesFromSlice(text, carry: &carry)
        for p in publishes {
            let repo = p.cwd.flatMap { resolveRepoName(cwd: $0) }
            lock.lock()
            let slug = artifactSlug(from: p.url)
            if let slug = slug, let merged = mergedRecord(records[slug], publish: p, repoName: repo),
               records[slug] != merged {
                records[slug] = merged
                changed = true
            }
            lock.unlock()
        }
        lock.lock()
        scans[path] = ArtifactScanState(size: size, mtime: mtime, offset: start + UInt64(consumed),
                                        carry: carry.isEmpty ? nil : carry)
        lock.unlock()
        return changed
    }

    // Repo name for a publish's cwd: `git --git-common-dir` when the directory still exists
    // (subprocess — only ever called from the background scan), else the path heuristic.
    // Cached per cwd for the process lifetime.
    private func resolveRepoName(cwd: String) -> String? {
        lock.lock()
        let cached = repoNameCache[cwd]
        lock.unlock()
        if let c = cached { return c }
        var name: String?
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue,
           let out = runCommand([gitBin, "-C", cwd, "rev-parse", "--git-common-dir"]) {
            var common = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !common.hasPrefix("/") { common = (cwd as NSString).appendingPathComponent(common) }
            let last = (common as NSString).lastPathComponent
            let repoDir = last == ".git" ? (common as NSString).deletingLastPathComponent : common
            let n = (repoDir as NSString).lastPathComponent
            if !n.isEmpty { name = n }
        }
        if name == nil { name = repoNameFromPath(cwd) }
        lock.lock()
        repoNameCache[cwd] = name
        lock.unlock()
        return name
    }
}

// MARK: - P0 probe
//
// `SHEPHERD_ARTIFACT_PROBE=1 Shepherd` — measure the frames endpoint through the app's own token
// path (the `security` subprocess is on the keychain item's ACL; the token never leaves the
// process) and print status + response shape to stderr, then exit. Two calls: the full claude-code
// header set, then a bare Authorization-only request — the diff tells whether `anthropic-beta` /
// the UA are required. Headless, GUI never built.
func artifactProbeAndExit() -> Never {
    func w(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    guard let token = claudeOAuthAccessToken() else { w("PROBE: no oauth token"); exit(1) }
    // The X-Frame-* set is what the CLI sends (frameAPIHeaders); the bare call shows whether
    // they're required (without them: 404, measured 2026-07-17).
    let (s1, b1, e1) = frameGET("/api/frame/frames?limit=3", token: token)
    w("PROBE x-frame-headers status=\(s1) neterr=\(e1 ?? "-")")
    w(String(String(decoding: b1 ?? Data(), as: UTF8.self).prefix(3000)))
    let (s2, b2, _) = frameGET("/api/frame/frames?limit=3", token: token, extraHeaders: [:])
    w("PROBE bare-auth status=\(s2)")
    w(String(String(decoding: b2 ?? Data(), as: UTF8.self).prefix(400)))
    if s1 == 200, let d = b1, let obj = try? JSONSerialization.jsonObject(with: d),
       let frames = parseFrames(obj) {
        w("PROBE parsed \(frames.count) frames")
        for f in frames { w("  \(f.slug.prefix(8)) rel=\(f.rel ?? "-") softDeleted=\(f.softDeleted) updated=\(f.updatedAt.map(String.init(describing:)) ?? "-") title=\(f.title ?? "-")") }
    }
    exit(s1 == 200 ? 0 : 1)
}
