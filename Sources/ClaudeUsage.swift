import Foundation
import Security

// MARK: - Claude plan usage / rate limits (the same data `/usage` shows)
//
// Source: GET https://api.anthropic.com/api/oauth/usage with Claude Code's own OAuth token
// (Keychain service "Claude Code-credentials"; falls back to ~/.claude/.credentials.json). The
// endpoint requires the `anthropic-beta: oauth-2025-04-20` header and a claude-code User-Agent.
// The `limits` array is the authoritative shape: one entry per window (session / weekly_all /
// weekly_scoped per model), each with `percent`, `resets_at`, `severity`. `utilization` is 0–100.

struct UsageWindow {
    let key: String        // "session" / "weekly" / model display name (e.g. "Fable", "Opus")
    let label: String      // localized short label for the gauge
    let percent: Double    // 0–100 used
    let resetsAt: Date?
    let severity: String   // "normal" / "warning" / "critical" (drives color)
}

struct UsageSnapshot {
    let windows: [UsageWindow]
    let extraCreditUsedPct: Double?   // added-usage credits ($ cap), when enabled
    let at: Date
    let error: String?                // non-nil when the fetch failed (shown muted)
}

// Read Claude Code's OAuth access token. Keychain first (macOS), then the credentials file.
func claudeOAuthAccessToken() -> String? {
    func token(from blob: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any], let t = oauth["accessToken"] as? String { return t }
        return obj["accessToken"] as? String
    }
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: AnyObject?
    if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
       let data = out as? Data, let t = token(from: data) { return t }
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
    if let data = FileManager.default.contents(atPath: path), let t = token(from: data) { return t }
    return nil
}

func parseUsageISODate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// Synchronous GET of the usage endpoint. Call off the main thread. Returns nil only when there's
// no token at all; on HTTP/parse errors it returns a snapshot carrying `error` so the UI can hint.
func fetchClaudeUsage() -> UsageSnapshot? {
    guard let token = claudeOAuthAccessToken() else { return nil }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.httpMethod = "GET"
    req.timeoutInterval = 20
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-code/2.1.201", forHTTPHeaderField: "User-Agent")

    let sem = DispatchSemaphore(value: 0)
    var body: Data?; var status = -1; var netErr: String?
    URLSession.shared.dataTask(with: req) { data, resp, err in
        body = data; status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if let err = err { netErr = err.localizedDescription }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 22)

    if let netErr = netErr { return UsageSnapshot(windows: [], extraCreditUsedPct: nil, at: Date(), error: netErr) }
    guard status == 200, let body = body,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        let hint = status == 401 ? L("要再認証（claude を起動）", "re-auth needed (run claude)")
                 : status == 429 ? L("API制限中", "rate limited")
                 : "HTTP \(status)"
        return UsageSnapshot(windows: [], extraCreditUsedPct: nil, at: Date(), error: hint)
    }

    var windows: [UsageWindow] = []
    // Prefer the `limits` array (session / weekly_all / weekly_scoped per model).
    if let limits = json["limits"] as? [[String: Any]] {
        for l in limits {
            let kind = l["kind"] as? String ?? ""
            let group = l["group"] as? String ?? ""
            let percent = (l["percent"] as? NSNumber)?.doubleValue ?? 0
            let severity = l["severity"] as? String ?? "normal"
            let reset = parseUsageISODate(l["resets_at"] as? String)
            if kind == "session" || group == "session" {
                windows.append(UsageWindow(key: "session", label: L("5時間", "5h"), percent: percent, resetsAt: reset, severity: severity))
            } else if kind == "weekly_all" {
                windows.append(UsageWindow(key: "weekly", label: L("週間", "weekly"), percent: percent, resetsAt: reset, severity: severity))
            } else if group == "weekly", let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String {
                windows.append(UsageWindow(key: model, label: L("週·\(model)", "wk·\(model)"), percent: percent, resetsAt: reset, severity: severity))
            }
        }
    }
    // Fallback to the flat fields if `limits` was absent/empty.
    if windows.isEmpty {
        func flat(_ k: String, _ key: String, _ label: String) {
            guard let w = json[k] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return }
            windows.append(UsageWindow(key: key, label: label, percent: u, resetsAt: parseUsageISODate(w["resets_at"] as? String), severity: "normal"))
        }
        flat("five_hour", "session", L("5時間", "5h"))
        flat("seven_day", "weekly", L("週間", "weekly"))
    }

    var extraPct: Double?
    if let extra = json["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
        extraPct = (extra["utilization"] as? NSNumber)?.doubleValue
    }
    return UsageSnapshot(windows: windows, extraCreditUsedPct: extraPct, at: Date(), error: nil)
}
