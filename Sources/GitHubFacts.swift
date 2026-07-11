import Foundation

// PR facts are fetched stale-while-revalidate: prInfo NEVER runs gh synchronously (a cache-miss
// refresh used to stall ~1s × 2 calls × repo count — the 9s refreshes that made state changes
// look stuck). A miss/expired entry returns whatever we have NOW and kicks one background gh
// round-trip per cwd; when that lands and actually changed something, onPRFactsChanged asks the
// app to repaint.
let prLock = NSLock()                       // guards prCache + prFetching (refresh queue ⇄ prFetchQueue)
var prFetching: Set<String> = []            // cwds with an in-flight gh fetch (dedup)
var onPRFactsChanged: (() -> Void)?         // set once at launch; may be called from prFetchQueue
let prFetchQueue = DispatchQueue(label: "shepherd.prfetch", attributes: .concurrent)

// The actual gh round-trip (test seam — tests stub this out; qv statusDir).
var prFetch: (String) -> (num: Int?, ci: CIState?, url: String?) = { cwd in
    guard let gh = ghBin else { return (nil, nil, nil) }
    var num: Int? = nil, url: String? = nil
    if let s = runCommand([gh, "pr", "view", "--json", "number,url"], cwd: cwd),
       let d = s.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        num = obj["number"] as? Int
        url = obj["url"] as? String
    }
    var ci: CIState? = nil
    if num != nil,
       // `gh pr checks` exits non-zero on fail/pending but still prints the buckets.
       let s = runCommand([gh, "pr", "checks", "--json", "bucket", "-q", ".[].bucket"], cwd: cwd, ignoreExit: true) {
        let buckets = Set(s.split(separator: "\n").map { String($0) })
        if !buckets.isEmpty {
            ci = buckets.contains("fail") ? .fail : (buckets.contains("pending") ? .pending : .pass)
        }
    }
    return (num, ci, url)
}

func prInfo(cwd: String) -> (num: Int?, ci: CIState?, url: String?) {
    prLock.lock()
    let c = prCache[cwd]
    let fresh = c.map { Date().timeIntervalSince($0.at) < 60 } ?? false
    let shouldFetch = !fresh && !prFetching.contains(cwd)
    if shouldFetch { prFetching.insert(cwd) }
    prLock.unlock()
    if shouldFetch {
        prFetchQueue.async {
            let (num, ci, url) = prFetch(cwd)
            prLock.lock()
            let old = prCache[cwd]
            prCache[cwd] = (num, ci, url, Date())
            prFetching.remove(cwd)
            prLock.unlock()
            if old?.num != num || old?.ci != ci || old?.url != url { onPRFactsChanged?() }
        }
    }
    return (c?.num, c?.ci, c?.url)
}

func firstMatchInt(_ pattern: String, in text: String) -> Int? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text)
    else { return nil }
    return Int(text[r])
}

// Last capture-group-1 match of `pattern` in `text` (used to grab the most recent URL).
func lastMatchString(_ pattern: String, in text: String) -> String? {
    allMatchStrings(pattern, in: text).last
}

// Every capture-group-1 match, in appearance order (top→bottom of the scrollback).
func allMatchStrings(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ms = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
    return ms.compactMap { m in
        guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}>\"'（）"))
    }
}

struct GitFacts {
    var branch: String?
    var changed: Int?
    var repoKey: String?
    var repoName: String?
    var isWorktree: Bool
    var prNo: Int?
    var prUrl: String?
    var ciState: CIState?
}

// Branch / dirty-count / repo identity / PR facts for a cwd. The git-derived half is cached 15s per
// cwd (two git spawns × row count per refresh otherwise); PR facts are overlaid fresh on every call so
// a background gh revalidate shows up on the very next repaint instead of waiting out the git TTL.
func gitFacts(cwd: String) -> GitFacts {
    factsLock.lock()
    let cached = gitFactsCache[cwd]
    factsLock.unlock()
    if let c = cached, Date().timeIntervalSince(c.at) < 15 {
        var f = c.facts
        let pr = prInfo(cwd: cwd)
        f.prNo = pr.num; f.prUrl = pr.url; f.ciState = pr.ci
        return f
    }
    var f = gitFactsUncached(cwd: cwd)
    factsLock.lock()
    gitFactsCache[cwd] = (f, Date())
    factsLock.unlock()
    let pr = prInfo(cwd: cwd)
    f.prNo = pr.num; f.prUrl = pr.url; f.ciState = pr.ci
    return f
}

// A git subprocess costs ~80ms of process startup, so the NUMBER of calls is the cost: rev-parse prints
// the values it was asked for one per line, in order, so one call answers both the branch and the repo
// identity (measured: two calls, 167ms, for a clean checkout).
//
// Two ordering rules, both measured on git 2.x: `--path-format` must precede the non-option `HEAD`, and
// `--show-toplevel` is fatal in a bare repo, taking the whole call down with it. So a bare repo, a repo
// with no commits, and a non-git directory all come back empty — none of them is ever a session's cwd.
private func gitFactsUncached(cwd: String) -> GitFacts {
    var f = GitFacts(branch: nil, changed: nil, repoKey: nil, repoName: nil,
                     isWorktree: false, prNo: nil, prUrl: nil, ciState: nil)
    guard !cwd.isEmpty,
          let out = runCommand([gitBin, "-C", cwd, "rev-parse", "--path-format=absolute",
                                "--show-toplevel", "--git-common-dir", "--git-dir", "--abbrev-ref", "HEAD"])
    else { return f }
    let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard lines.count >= 4 else { return f }

    f.branch = lines[3]
    if !lines[0].isEmpty {
        f.repoName = (lines[0] as NSString).lastPathComponent
        // --git-common-dir is shared across a repo's worktrees (so it groups them like
        // herdr's repo_key); it differs from --git-dir only for a linked worktree, which
        // is how we tell a worktree from the main checkout.
        f.repoKey = lines[1].isEmpty ? lines[0] : lines[1]
        f.isWorktree = lines[1] != lines[2]
    }
    if let st = runCommand([gitBin, "-C", cwd, "status", "--porcelain"]) {
        f.changed = st.split(separator: "\n").count
    }
    return f
}
