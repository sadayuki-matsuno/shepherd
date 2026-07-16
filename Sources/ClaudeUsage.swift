import Foundation
import Security

// MARK: - Claude plan usage / rate limits (the same data `/usage` shows)
//
// Source: GET https://api.anthropic.com/api/oauth/usage with Claude Code's own OAuth token
// (Keychain service "Claude Code-credentials"; falls back to ~/.claude/.credentials.json). The
// endpoint requires the `anthropic-beta: oauth-2025-04-20` header and a claude-code User-Agent.
// The `limits` array is the authoritative shape: one entry per window (session / weekly_all /
// weekly_scoped per model), each with `percent`, `resets_at`, `severity` (plus `is_active`,
// which marks the currently-binding window — parsed once for a dot indicator, removed as
// clutter 2026-07-16). `spend` is the usage-credit
// block: `used` always comes back (even $0.00 on accounts that never bought credits), but
// `balance` / `cap` are null until extra usage is enabled — render "—" for those, don't hide
// the whole block. The plan tier chip ("MAX 20X") comes from a second endpoint,
// /api/oauth/profile → organization.rate_limit_tier, cached for a day.

struct UsageWindow {
    let key: String        // "session" / "weekly" / model display name (e.g. "Fable", "Opus")
    let label: String      // localized short label for the gauge
    let percent: Double    // 0–100 used
    let resetsAt: Date?
    let severity: String   // "normal" / "warning" / "critical" (drives color)
}

// The `spend` block: usage credits that cover overflow past the plan limits. Live shapes
// (2026-07-16, extra usage ON): `used` and `limit` (monthly cap) are money objects, `balance`
// stays null (it only fills for prepaid credit), and `cap` is a NESTED {money, credits} object
// — so the shown remainder is computed limit − used, not read from the API.
struct CreditInfo {
    let enabled: Bool
    let usedText: String?      // "$56.59" — present even when credits were never bought ($0.00)
    let limitText: String?     // "$200.00" — the monthly extra-usage cap
    let balanceText: String?   // prepaid balance; null on monthly-billed extra usage
    let remainingText: String? // limit − used, when both parse in the same currency
    let percent: Double?       // 0–100 of the limit used
    let severity: String
    let usedMinor: Double?     // `used` in minor units — numeric, so snapshots can be compared
}

// Is the account consuming extra-usage credits right now? Transcripts and the registry carry NO
// per-session credit field (measured 2026-07-16: a session running on credits writes
// records byte-identical to plan usage, and only the one that HIT the limit gets a 429 marker) —
// so "on credits" is an account-level fact, shown on the dashboard's credit zone. Two signals:
//   • spend.used grew since the previous snapshot — money moved, the direct proof, sufficient
//     on its own
//   • some limit window is exhausted (≥100%) while extra usage is enabled AND a session is
//     actually working — the state in which that work bills to credits (covers the first fetch,
//     where there's no delta yet). The anyWorking gate keeps a capped-but-idle board from
//     breathing "burning" all night: an exhausted window persists until reset, spending doesn't.
func creditBurnActive(prevUsedMinor: Double?, credit: CreditInfo?, windows: [UsageWindow],
                      anyWorking: Bool) -> Bool {
    guard let credit, credit.enabled else { return false }
    if let prev = prevUsedMinor, let used = credit.usedMinor, used > prev { return true }
    return anyWorking && windows.contains { $0.percent >= 100 }
}

struct UsageSnapshot {
    let windows: [UsageWindow]
    let credit: CreditInfo?
    let at: Date
    let error: String?                // non-nil when the fetch failed (shown muted)
    var planTier: String? = nil       // "MAX 20X" — from /api/oauth/profile, filled by the fetcher
}

// Read Claude Code's OAuth access token. The `security` subprocess goes FIRST: the CLI tool is
// already on the keychain item's ACL (Claude Code writes through it), so it answers without the
// per-binary consent prompt that direct SecItemCopyMatching triggers after every Shepherd
// rebuild/update — and that prompt BLOCKS the calling thread indefinitely, freezing the
// dashboard on "取得中…" (observed 2026-07-16). runCommand's 10s timeout bounds the subprocess
// path even where `security` itself would prompt. Fallbacks: direct keychain (may prompt once
// per binary), then the plaintext credentials file some setups use.
func claudeOAuthAccessToken() -> String? {
    func token(from blob: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any], let t = oauth["accessToken"] as? String { return t }
        return obj["accessToken"] as? String
    }
    if let out = runCommand(["/usr/bin/security", "find-generic-password",
                             "-s", "Claude Code-credentials", "-w"]),
       let t = token(from: Data(out.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) { return t }
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

// A money object ({amount_minor, currency, exponent}) → its parts, or nil on null/garbage.
func moneyParts(_ obj: Any?) -> (minor: Double, exponent: Int, currency: String)? {
    guard let m = obj as? [String: Any], let minor = (m["amount_minor"] as? NSNumber)?.doubleValue
    else { return nil }
    return (minor, (m["exponent"] as? NSNumber)?.intValue ?? 2, m["currency"] as? String ?? "USD")
}

func moneyString(minor: Double, exponent: Int, currency: String) -> String {
    let number = String(format: "%.\(exponent)f", minor / pow(10, Double(exponent)))
    return currency == "USD" ? "$" + number : "\(currency) \(number)"
}

// "$5.40" / "EUR 12.00" straight from a money object. nil on null/garbage.
func moneyText(_ obj: Any?) -> String? {
    moneyParts(obj).map { moneyString(minor: $0.minor, exponent: $0.exponent, currency: $0.currency) }
}

// organization.rate_limit_tier → chip text: "default_claude_max_20x" → "MAX 20X".
// Unknown tiers pass through uppercased so a future plan name still shows something sensible.
func planTierDisplay(_ raw: String?) -> String? {
    guard var s = raw, !s.isEmpty else { return nil }
    if s.hasPrefix("default_claude_") { s = String(s.dropFirst("default_claude_".count)) }
    if s.isEmpty || s == "default" { return nil }
    return s.replacingOccurrences(of: "_", with: " ").uppercased()
}

// "32秒前" / "3分前" / "2時間前" — the dashboard's fetched-at stamp.
func agoText(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return L("\(s)秒前", "\(s)s ago") }
    if s < 3600 { return L("\(s / 60)分前", "\(s / 60)m ago") }
    return L("\(s / 3600)時間前", "\(s / 3600)h ago")
}

// Pure parse of the usage endpoint's JSON body (network-free; unit-tested).
func parseUsage(_ json: [String: Any]) -> UsageSnapshot {
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

    var credit: CreditInfo?
    if let spend = json["spend"] as? [String: Any] {
        let used = moneyParts(spend["used"])
        let limit = moneyParts(spend["limit"])
        var remaining: String?
        if let used, let limit, used.currency == limit.currency, used.exponent == limit.exponent {
            remaining = moneyString(minor: max(0, limit.minor - used.minor),
                                    exponent: used.exponent, currency: used.currency)
        }
        credit = CreditInfo(
            enabled: (spend["enabled"] as? Bool) ?? false,
            usedText: used.map { moneyString(minor: $0.minor, exponent: $0.exponent, currency: $0.currency) },
            limitText: limit.map { moneyString(minor: $0.minor, exponent: $0.exponent, currency: $0.currency) },
            balanceText: moneyText(spend["balance"]),
            remainingText: remaining,
            percent: (spend["percent"] as? NSNumber)?.doubleValue,
            severity: spend["severity"] as? String ?? "normal",
            usedMinor: used?.minor)
    }
    return UsageSnapshot(windows: windows, credit: credit, at: Date(), error: nil)
}

// Synchronous GET of an oauth endpoint. Call off the main thread.
private func oauthGET(_ path: String, token: String) -> (status: Int, json: [String: Any]?, netErr: String?) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
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
    let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    return (status, json, netErr)
}

// The plan tier barely changes — fetch /api/oauth/profile at most once a day (failures cached
// too, so a broken endpoint doesn't add an HTTP call to every usage refresh). forceable via
// planTierCache = nil (the dashboard's ↻). Guarded by factsLock like every shared cache: the
// fetch runs on a background hop while the ↻ writes nil from the main thread.
var planTierCache: (tier: String?, at: Date)?
func claudePlanTier(token: String) -> String? {
    factsLock.lock()
    if let c = planTierCache, Date().timeIntervalSince(c.at) < 24 * 3600 {
        let tier = c.tier
        factsLock.unlock()
        return tier
    }
    factsLock.unlock()
    let (status, json, _) = oauthGET("/api/oauth/profile", token: token)
    let tier: String? = status == 200
        ? planTierDisplay((json?["organization"] as? [String: Any])?["rate_limit_tier"] as? String)
        : nil
    factsLock.lock()
    planTierCache = (tier, Date())
    factsLock.unlock()
    return tier
}

// Fetch + parse the usage endpoint. Returns nil only when there's no token at all; on HTTP/parse
// errors it returns a snapshot carrying `error` so the UI can hint.
func fetchClaudeUsage() -> UsageSnapshot? {
    guard let token = claudeOAuthAccessToken() else { return nil }
    let (status, json, netErr) = oauthGET("/api/oauth/usage", token: token)
    if let netErr = netErr { return UsageSnapshot(windows: [], credit: nil, at: Date(), error: netErr) }
    guard status == 200, let json = json else {
        let hint = status == 401 ? L("要再認証（claude を起動）", "re-auth needed (run claude)")
                 : status == 429 ? L("API制限中", "rate limited")
                 : "HTTP \(status)"
        return UsageSnapshot(windows: [], credit: nil, at: Date(), error: hint)
    }
    var snap = parseUsage(json)
    snap.planTier = claudePlanTier(token: token)
    return snap
}
