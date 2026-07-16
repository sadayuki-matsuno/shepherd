// Shepherd — a floating always-on-top HUD for Claude Code
//
// Watches every Claude Code session on this machine — zellij panes, bare terminals and cc-daemon
// background workers alike — and shows their status, repo/branch, changed-file count, issue/PR
// numbers in a small panel that stays on top of every Space. Click a card to open that session
// (zellij attach, or `claude attach` for a background worker); right-click for its actions
// (reply, remote-control, capture, stop).
//
// Build: ./build.sh   (installs /Applications/Shepherd.app)
import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices
import Security



// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var panel: NSPanel!
    var stack: NSStackView!
    // 縦スクロール土台（HUDサイズ 2026-07-08）。stack は常にこの scrollView の documentView 内に住み、
    // auto モードではパネル自体が内容にフィットするのでスクロールは実質発生しない。
    var scrollView: NSScrollView!
    // HUD サイズモード: auto=内容追従（従来）/ 小・中・大=固定サイズ（縦スクロールのみ）/
    // fullDisplay=載っているディスプレイの可視領域全面。⚙メニュー「HUDサイズ」で切り替え・永続化。
    var hudSizeMode: HUDSizeMode = HUDSizeMode(rawValue: defaults.string(forKey: "hudSizeMode") ?? "") ?? .auto
    var timer: Timer?                  // 30s fallback refresh (FSEvents drives the fast path)
    var gcTimer: Timer?               // 5-min status-file GC (dead-pid cleanup)
    var fsStream: FSEventStreamRef?   // watches the status dir + transcripts
    let fsQueue = DispatchQueue(label: "shepherd.fsevents")
    var fsDebounce: DispatchWorkItem? // coalesces FSEvents bursts into one refresh
    var isRefreshing = false
    // A refresh requested while one is in flight is queued, not dropped — dropping it meant a
    // state change landing during a slow refresh waited for the 30s fallback timer.
    var refreshPending = false
    // The Ghostty windows we opened per jump target (herdr, each zellij session) are tracked by
    // AppleScript id in defaults so a restart reuses the existing window instead of opening a
    // duplicate — see jumpGhostty (windowKey). Ghostty windows have no stable title marker, so the
    // id is the only reliable handle; jumpGhostty's try/on-error doubles as the liveness check.
    var lastRows: [AgentRow]?
    let contentWidth: CGFloat = 320
    // Inline "answer a blocked agent" popover, plus the per-agent "reply sent, waiting"
    // state shown on the row card (not in the popover — the popover closes on send).
    var replyPopover: NSPopover?
    var replyEscMonitor: Any?
    var replyWaitingSession: String?   // after a send, the session we're waiting to unblock
    var replyWaitingSince: Date?
    var replyWaitingTimedOut = false

    // Sessions with a stop/rm in flight (`claude rm` can sit on daemon confirmation for seconds).
    // A member's card renders disabled with a centered spinner until the operation resolves; keyed
    // by session id so the state survives the card rebuilds a mid-flight refresh causes.
    // Main-thread only (mutated in the actions' main.async completions).
    var deletingSessions: Set<String> = []


    // Update check (2026-07-14): once a day, the bundle version is compared against the latest
    // GitHub release; when newer, the brand bar wears an "update vX.Y.Z" badge that opens the
    // release page (updating itself stays a user action — brew upgrade). See maybeCheckForUpdate().
    var availableUpdate: LatestRelease?
    var updateCheckedAt = Date.distantPast
    var updateChecking = false

    // Plan-usage dashboard (top of the HUD). On by default; refreshed at most every 60s (the
    // endpoint is rate limited, and the windows move slowly). See fetchClaudeUsage().
    var showUsageDashboard = defaults.object(forKey: "showUsageDashboard") == nil ? true : defaults.bool(forKey: "showUsageDashboard")
    var lastUsage: UsageSnapshot?
    var usageFetchedAt = Date.distantPast
    var usageFetching = false
    // Last fetch's failure, kept SEPARATE from lastUsage: an error must not wipe the gauges
    // (stale-while-error — the old numbers stay up, dimmed, with a "更新失敗" stamp).
    var usageError: String?
    // Extra-usage credits are being consumed RIGHT NOW (creditBurnActive over consecutive usage
    // snapshots — see ClaudeUsage.swift for why this is account-level, not per-session). Drives the
    // amber coin on every working card + the header chip. SHEPHERD_FAKE_CREDIT_BURN=1 pins it on
    // for screenshots (same spirit as SHEPHERD_LATEST_TAG).
    var creditBurn = ProcessInfo.processInfo.environment["SHEPHERD_FAKE_CREDIT_BURN"] != nil
    var creditPrevUsedMinor: Double?

    // Layout: repos are always laid out as fixed-width masonry columns (v5fix3 #3 — the old
    // single-column row mode is gone). Columns are individually collapsible (state persisted per repo).
    var collapsedRepos: Set<String> = Set(defaults.stringArray(forKey: "collapsedRepos") ?? [])
    // Show a blocked agent's pending question as a one-line "? …" preview on its card. Kept behind a
    // flag (default true) so the default can flip per user feedback without code churn (addendum).
    // done/idle no longer show a last-utterance line. Reply (⌘-click / menu) works regardless.
    var showBlockedQuestion = defaults.object(forKey: "showBlockedQuestion") == nil ? true : defaults.bool(forKey: "showBlockedQuestion")
    var stackWidthConstraint: NSLayoutConstraint!
    // Column mode geometry (B1/B3). Columns are a fixed width so collapsing a group's cards never
    // changes the slot width. Column count is overridable: `defaults write … masonryColumns 4`.
    let columnWidth: CGFloat = 268
    var masonryColumns: Int { max(1, defaults.object(forKey: "masonryColumns") == nil ? 3 : defaults.integer(forKey: "masonryColumns")) }
    // Manual repo-group placement (v6 #2, replaces the old round-robin `pinnedOrder`). Each entry
    // maps a repoKey to a fixed column; a column's manual members render top-to-bottom in this
    // array's order, above the auto-filled groups. Set by dragging a group's header to a column/
    // position; groups absent here are auto-packed into the shortest column. Persisted in defaults
    // as ["<col>:<key>", …] (the leading integer up to the first ':' is the column; key may itself
    // contain ':').
    var manualLayout: [(key: String, col: Int)] = (defaults.stringArray(forKey: "manualLayout") ?? []).compactMap { entry in
        guard let sep = entry.firstIndex(of: ":"), let col = Int(entry[..<sep]) else { return nil }
        let key = String(entry[entry.index(after: sep)...])
        return key.isEmpty ? nil : (key, col)
    }
    func saveManualLayout() { defaults.set(manualLayout.map { "\($0.col):\($0.key)" }, forKey: "manualLayout") }

    // Board filter (B5). Extensible: today just a 24h-recency toggle; the enum leaves room for
    // status / repo filters later. Default: only sessions whose last event is within 24h.
    enum TimeFilter: String { case last24h, all }
    var timeFilter: TimeFilter = TimeFilter(rawValue: defaults.string(forKey: "timeFilter") ?? "last24h") ?? .last24h

    // Sessions we've already shown at least once — a session not in this set is new and slides in
    // on its first appearance (B4). Populated at the end of each rebuild.
    var knownSessions: Set<String> = []
    // Last status we rendered per session, so a state change can animate its card color in place (B4).
    var renderedStatus: [String: String] = [:]

    // Minimized: shrink the whole HUD to just the usage dashboard + the header summary (status
    // pills), hiding all agent rows/columns. Toggled from the header.
    var minimized = defaults.bool(forKey: "minimized")

    // ＋ new-session repo picker (search + list) and worktree-launch state.
    var repoPickerPopover: NSPopover?
    var repoPickerEscMonitor: Any?
    var repoPickerClickMonitor: Any?   // dismiss the picker on a click outside it
    var repoPickerAll: [(title: String, path: String)] = []
    var repoPickerFiltered: [(title: String, path: String)] = []
    weak var repoPickerTable: NSTableView?
    weak var repoPickerSearch: NSTextField?
    var worktreeCreating = false
    var sessionError: String?
    var remoteEnabledSessions: Set<String> = []   // sessions we've run /remote-control on
    weak var hintLabel: NSTextField?           // self-drawn hover hint (NSToolTip doesn't fire)
    var hintSticky = false                      // a click-triggered flash holds the hint line
    var hintFlashWork: DispatchWorkItem?        // clears the flash after a few seconds
    // File drag & drop.
    weak var dragTarget: RowView?
    var lastDragAt = Date.distantPast          // pause rebuild during an active drag
    var dropPopover: NSPopover?
    var dropEscMonitor: Any?
    var dropSentSession: String?               // shows "📎 送信済み" on that row briefly

    // Stream Deck (optional). Enabled via the ⚙ menu; state persisted in `deckEnabled`.
    // All blocking HID I/O runs on deckQueue so a slow/stuck device never freezes the UI.
    // Every property below is main-thread-confined; the device ref is captured into
    // deckQueue closures, never read off the queue.
    let deckQueue = DispatchQueue(label: "shepherd.deck")
    var deck: StreamDeck?
    var deckOpening = false
    var deckStatus: String?            // deck condition, always shown in the ⚙ menu
    var deckWarnUntil: Date?           // while set & future, deckStatus also shows as a header
                                       // warning pill. Otherwise "not connected" is silent in the
                                       // header (the Elgato app owns the device by default — a
                                       // permanent red badge was just noise). See A7.
    var deckPage: DeckPage = .columns  // which screen the deck shows (top = column list)
    var deckSections: [RepoSection] = []   // last board data, for blink re-renders
    var deckRows: [AgentRow] = []      // last flattened board (openRow lookup + blink)
    var deckKeys: [DeckKey] = []       // what each physical key currently is / does
    var deckFlashOn = false
    var blinkTimer: Timer?
    var _deckBlank: Data?      // image cache, touched only on deckQueue
    var _deckLogo: Data?       // static faces, rasterized on the main thread (markIcon is a
    var _deckBack: Data?       // lazy NSImage) before deckQueue reads them — see prepareStaticDeckImages
    lazy var appIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: url)
        }
        return NSImage(named: NSImage.applicationIconName)
    }()

    // Background-less brand mark for the in-UI logo (toolbar + empty state). The .icns app icon is a
    // dark squircle with grid margins, which show up as a white/haze halo when scaled down to 20px on
    // the dark HUD (修正1). This flat, transparent mark drops the squircle so the logo dissolves into
    // the HUD. Falls back to the .icns if the mark asset is missing.
    lazy var markIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "mark", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = false
            return img
        }
        return appIcon
    }()


    // Stored state used from the AppDelegate+*.swift extension files —
    // stored properties must live in the class body, not in an extension.
    // Family fold state (C7): parent session ids whose child cards are collapsed. Default expanded.
    var collapsedFamilies: Set<String> = Set(defaults.stringArray(forKey: "collapsedFamilies") ?? [])
    // Archive lane fold state (2026-07-09): repo keys whose finished background records
    // (partitionRecords) are unfolded. Default folded, so only the expanded keys are stored.
    var expandedRecordLanes: Set<String> = Set(defaults.stringArray(forKey: "expandedRecordLanes") ?? [])
    var familyPeekPopover: NSPopover?
    var familyPeekCloseWork: DispatchWorkItem?
    // Hover tooltip popover (2026-07-15): anchored at the hovered control — the bottom hint line
    // proved invisible in practice for per-element details (glyph hover). Transient; closed on
    // hover-exit and defensively at every rebuild.
    var hoverTipPopover: NSPopover?
    let repoPanelPad: CGFloat = 7
    // ？ヘルプ（アイコン・UI凡例）ポップオーバー。表示中は rebuild をスキップ（他のポップオーバーと同じ扱い）。
    var helpPopover: NSPopover?
    var helpEscMonitor: Any?
    var helpClickMonitor: Any?
}

// Fixture seams for staged captures / self-checks (same vars the tests override): point the two
// data-source directories somewhere else and the board renders whatever lives there instead of
// the real sessions. Pair with `-claudePath` / `-ghPath` launch arguments (NSUserDefaults argument
// domain — nothing persists) to stub the subprocess sources too. Used by dev/demo-board.sh.
if let d = ProcessInfo.processInfo.environment["SHEPHERD_SESSIONS_DIR"] { claudeSessionsDir = d }
if let d = ProcessInfo.processInfo.environment["SHEPHERD_PROJECTS_DIR"] { claudeProjectsDir = d }

// Single instance guard
if let bundleId = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count > 1 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
