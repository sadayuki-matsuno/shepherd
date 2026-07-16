import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives in a separate module on Linux
#endif

// MARK: - Update check (GitHub releases)
//
// Shepherd knows its own version from the bundle (CFBundleShortVersionString) and compares it
// against the repo's latest GitHub release once a day (see maybeCheckForUpdate). Everything here
// is additive: any network, HTTP or parse failure just means "no update badge" — the HUD never
// degrades over this. The public releases/latest endpoint needs no auth and already excludes
// drafts and prereleases (the parse re-checks anyway).

struct LatestRelease {
    let tag: String   // e.g. "v0.0.4"
    let url: String   // release page opened on click
}

let shepherdReleasesURL = "https://github.com/sadayuki-matsuno/shepherd/releases"

// Numeric dotted-version compare ("v" prefix tolerated, missing components read as 0). True only
// when BOTH sides parse cleanly and latest > current — garbage never claims an update.
func isUpdateAvailable(latest: String, current: String) -> Bool {
    func parts(_ s: String) -> [Int]? {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v = String(v.dropFirst()) }
        guard !v.isEmpty else { return nil }
        var out: [Int] = []
        for c in v.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(c), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }
    guard let l = parts(latest), let c = parts(current) else { return false }
    for i in 0..<max(l.count, c.count) {
        let a = i < l.count ? l[i] : 0
        let b = i < c.count ? c[i] : 0
        if a != b { return a > b }
    }
    return false
}

func parseLatestRelease(_ data: Data) -> LatestRelease? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = json["tag_name"] as? String, !tag.isEmpty else { return nil }
    if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { return nil }
    let url = (json["html_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? shepherdReleasesURL
    return LatestRelease(tag: tag, url: url)
}

// Synchronous GET of the latest release. Call off the main thread.
func fetchLatestRelease() -> LatestRelease? {
    // Demo/capture seam (same spirit as SHEPHERD_SESSIONS_DIR): skip the network and pretend
    // this tag is the latest release.
    if let fake = ProcessInfo.processInfo.environment["SHEPHERD_LATEST_TAG"], !fake.isEmpty {
        return LatestRelease(tag: fake, url: shepherdReleasesURL)
    }
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/sadayuki-matsuno/shepherd/releases/latest")!)
    req.timeoutInterval = 10
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let sem = DispatchSemaphore(value: 0)
    var body: Data?
    var status = -1
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        body = data
        status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 12)
    guard status == 200, let body = body else { return nil }
    return parseLatestRelease(body)
}
