import Foundation

// MARK: - Configuration
// Override via: defaults write com.sadayuki-matsuno.shepherd <key> <value>
//   ghPath       — path to the gh binary ("" to disable PR lookup)
//   terminalApp  — terminal application name (default: Ghostty, falls back to Terminal)

func firstExisting(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

let defaults = UserDefaults.standard

let ghBin: String? = {
    if let p = defaults.string(forKey: "ghPath") { return p.isEmpty ? nil : p }
    return firstExisting(["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
}()

let gitBin = "/usr/bin/git"

// Claude Code CLI. Used to stop a background agent (`claude stop <id>`) — the respawn-proof way to
// close a session the cc-daemon manages (a `/remote-control` fork keeps getting resumed from the
// daemon roster, so SIGTERM to the leaf pid is futile). GUI apps get a stripped PATH, so resolve
// the absolute path like herdr/gh do.
let claudeBin: String? = {
    if let p = defaults.string(forKey: "claudePath") { return p.isEmpty ? nil : p }
    return firstExisting(["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          (NSHomeDirectory() as NSString).appendingPathComponent(".claude/local/claude")])
}()

let ghqBin: String? = {
    if let p = defaults.string(forKey: "ghqPath") { return p.isEmpty ? nil : p }
    return firstExisting(["/opt/homebrew/bin/ghq", "/usr/local/bin/ghq"])
}()

// Absolute zellij path (GUI apps get a stripped PATH, so resolve it like herdr/gh do). Used to
// check a session is still attachable and to build the `zellij attach` jump command.
let zellijBin: String? = {
    if let p = defaults.string(forKey: "zellijPath") { return p.isEmpty ? nil : p }
    return firstExisting(["/opt/homebrew/bin/zellij", "/usr/local/bin/zellij", "/usr/bin/zellij"])
}()

let terminalApp: String = defaults.string(forKey: "terminalApp")
    ?? (FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") ? "Ghostty" : "Terminal")

let isJapanese = Locale.preferredLanguages.first?.hasPrefix("ja") ?? false
func L(_ ja: String, _ en: String) -> String { isJapanese ? ja : en }
