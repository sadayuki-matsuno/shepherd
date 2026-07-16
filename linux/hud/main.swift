// Linux HUD v2: the real aggregation layer (fetchAgents) feeding a
// gtk4-layer-shell OVERLAY board — repo columns, status rails, blocked
// banners — the first step of porting the actual macOS board (§08④).
// Built by dev/linux/hud-build.sh, machine-verified by dev/linux/hud-verify.sh.
import Foundation
import CGtkLayerShell

// Same fixture seams as Sources/main.swift (which is macOS-only and not linked here).
if let d = ProcessInfo.processInfo.environment["SHEPHERD_SESSIONS_DIR"] { claudeSessionsDir = d }
if let d = ProcessInfo.processInfo.environment["SHEPHERD_PROJECTS_DIR"] { claudeProjectsDir = d }

// GTK handlers are @convention(c) closures, which cannot capture — shared
// state lives in globals instead.
var columnsBox: UnsafeMutablePointer<GtkWidget>? = nil
var rebuildQueued = false

// fetchAgents spawns subprocesses and reads files; running it on the GTK main
// thread would freeze the board exactly like the macOS "no synchronous
// subprocess in the rebuild path" landmine. So: fetch on a worker queue, hand
// the result to the main loop via g_idle_add. One fetch in flight at a time;
// requests arriving meanwhile coalesce into one follow-up round (the macOS
// refreshPending rule). fetchInFlight/refreshAgain are main-thread-only;
// pendingSections is the locked worker→main handoff.
let pendingLock = NSLock()
var pendingSections: [RepoSection]? = nil
var fetchInFlight = false
var refreshAgain = false

func cssRGB(_ c: HUDColor) -> String {
    "rgb(\(Int(c.red * 255 + 0.5)), \(Int(c.green * 255 + 0.5)), \(Int(c.blue * 255 + 0.5)))"
}

func asBox(_ w: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkBox> {
    UnsafeMutableRawPointer(w).assumingMemoryBound(to: GtkBox.self)
}

func addLabel(_ text: String, to box: UnsafeMutablePointer<GtkWidget>, cssClass: String? = nil) {
    // Truncate in Swift instead of Pango ellipsizing — one fewer C API to bind
    // for a board whose exact typography is not the point yet.
    guard let label = gtk_label_new(String(text.prefix(48))) else { return }
    gtk_widget_set_halign(label, GTK_ALIGN_START)
    if let cssClass = cssClass { gtk_widget_add_css_class(label, cssClass) }
    gtk_box_append(asBox(box), label)
}

func cardView(_ r: AgentRow, depth: Int) -> UnsafeMutablePointer<GtkWidget>? {
    guard let card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2) else { return nil }
    gtk_widget_add_css_class(card, "card")
    gtk_widget_add_css_class(card, "rail-\(r.status)")   // 3px status rail (border-left)
    if r.status == "idle" { gtk_widget_add_css_class(card, "dim") }
    gtk_widget_set_margin_start(card, gint(depth) * 12)  // child-session indent (treeOrder)

    if r.status == "blocked" {
        // Peach banner, like the macOS card's line 1. The question preview is the
        // transcript's open AskUserQuestion/ExitPlanMode, else the daemon's `needs`.
        if let banner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0) {
            gtk_widget_add_css_class(banner, "banner")
            let question = blockedPromptFromTranscript(cwd: r.cwd, sessionId: r.sessionId) ?? r.needs
            let preview = question.flatMap { $0.split(separator: "\n").first.map(String.init) }
            addLabel("? " + L("応答待ち", "needs input") + (preview.map { " — \($0)" } ?? ""), to: banner)
            gtk_box_append(asBox(card), banner)
        }
    }

    addLabel(r.activity ?? r.label, to: card)

    var meta: [String] = []
    if let model = r.model { meta.append(model.name) }
    if let pct = r.contextPct { meta.append("\(Int(pct * 100))%") }
    meta.append(formatDuration(Date().timeIntervalSince(r.statusSince)))
    if let changed = r.changedFiles, changed > 0 { meta.append("±\(changed)") }
    addLabel(meta.joined(separator: "  "), to: card, cssClass: "meta")

    return card
}

// Main thread: entry point for every refresh trigger (startup, debounced
// file-monitor event, fallback timer).
func rebuildBoard() {
    if fetchInFlight { refreshAgain = true; return }
    fetchInFlight = true
    DispatchQueue.global(qos: .userInitiated).async {
        // Column placement follows the macOS rule (layoutColumns): sections
        // alphabetical by header, headerless "other" last.
        var sections = groupByRepo(fetchAgents())
        sections.sort { ($0.header ?? "\u{10FFFF}") < ($1.header ?? "\u{10FFFF}") }
        pendingLock.lock()
        pendingSections = sections
        pendingLock.unlock()
        let apply: @convention(c) (gpointer?) -> gboolean = { _ in
            pendingLock.lock()
            let sections = pendingSections
            pendingSections = nil
            pendingLock.unlock()
            if let sections = sections { applyBoard(sections) }
            fetchInFlight = false
            if refreshAgain { refreshAgain = false; rebuildBoard() }
            return 0  // G_SOURCE_REMOVE
        }
        g_idle_add(apply, nil)   // thread-safe: queues onto the GTK main loop
    }
}

// Main thread: swap the widgets in from an already-fetched snapshot.
func applyBoard(_ sections: [RepoSection]) {
    guard let container = columnsBox else { return }
    while let child = gtk_widget_get_first_child(container) {
        gtk_box_remove(asBox(container), child)
    }
    for section in sections {
        guard let col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6) else { continue }
        gtk_widget_set_size_request(col, 280, -1)
        gtk_widget_set_valign(col, GTK_ALIGN_START)
        addLabel("\(section.header ?? L("その他", "other")) (\(section.rows.count))",
                 to: col, cssClass: "header")
        for (row, depth) in treeOrder(section.rows) {
            if let card = cardView(row, depth: depth) { gtk_box_append(asBox(col), card) }
        }
        gtk_box_append(asBox(container), col)
    }
}

// FSEvents-equivalent: rebuild 0.2s after a registry-dir event, like the macOS
// debounce. Coalescing is a single pending flag — events arriving while one
// rebuild is queued ride the same timeout.
func scheduleDebouncedRebuild() {
    if rebuildQueued { return }
    rebuildQueued = true
    let fire: @convention(c) (gpointer?) -> gboolean = { _ in
        rebuildQueued = false
        rebuildBoard()
        return 0  // G_SOURCE_REMOVE
    }
    g_timeout_add(200, fire, nil)
}

let activateHandler: @convention(c) (UnsafeMutablePointer<GtkApplication>?, gpointer?) -> Void = { app, _ in
    guard let widget = gtk_application_window_new(app) else { return }
    let window = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)

    // Same overlay contract the PoC proved: OVERLAY layer ≈ .floating,
    // KEYBOARD_MODE_NONE ≈ .nonactivatingPanel, top-right anchor + margin.
    gtk_layer_init_for_window(window)
    gtk_layer_set_layer(window, GTK_LAYER_SHELL_LAYER_OVERLAY)
    gtk_layer_set_keyboard_mode(window, GTK_LAYER_SHELL_KEYBOARD_MODE_NONE)
    gtk_layer_set_anchor(window, GTK_LAYER_SHELL_EDGE_TOP, 1)
    gtk_layer_set_anchor(window, GTK_LAYER_SHELL_EDGE_RIGHT, 1)
    gtk_layer_set_margin(window, GTK_LAYER_SHELL_EDGE_TOP, 24)
    gtk_layer_set_margin(window, GTK_LAYER_SHELL_EDGE_RIGHT, 24)

    // Colours come from the core's palette/status mapping (Models.swift), so a
    // status reaching the screen proves the data path, not a hand-copied hex.
    var css = """
    window { background-color: \(cssRGB(Cat.base)); }
    label { color: \(cssRGB(Cat.text)); font-size: 12px; }
    .header { color: \(cssRGB(Cat.subtext)); }
    .meta { color: \(cssRGB(Cat.subtext)); font-size: 10px; }
    .card { background-color: \(cssRGB(Cat.surface)); padding: 6px;
            border-left: 3px solid \(cssRGB(Cat.surface)); }
    .dim { opacity: 0.5; }
    .banner { background-color: \(cssRGB(Cat.peach)); padding: 2px 6px; }
    .banner label { color: \(cssRGB(Cat.crust)); }

    """
    for status in ["error", "blocked", "working", "idle", "unknown"] {
        css += ".rail-\(status) { border-left-color: \(cssRGB(style(for: status).dot)); }\n"
    }
    if let provider = gtk_css_provider_new() {
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(),
            OpaquePointer(provider),
            guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }

    if let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10) {
        gtk_widget_set_margin_top(box, 10)
        gtk_widget_set_margin_bottom(box, 10)
        gtk_widget_set_margin_start(box, 10)
        gtk_widget_set_margin_end(box, 10)
        columnsBox = box
        gtk_window_set_child(window, box)
    }

    rebuildBoard()

    // Two-stage refresh like the macOS pipeline: registry-dir file monitor
    // (event → 0.2s debounce) + a 30s fallback timer. No polling loop.
    if let gfile = g_file_new_for_path(claudeSessionsDir) {
        let monitor = g_file_monitor_directory(gfile, G_FILE_MONITOR_NONE, nil, nil)
        let changed: @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UInt32, UnsafeMutableRawPointer?
        ) -> Void = { _, _, _, _, _ in
            scheduleDebouncedRebuild()
        }
        // The monitor ref is deliberately never unreffed — it must live as long
        // as the process.
        g_signal_connect_data(
            UnsafeMutableRawPointer(monitor),
            "changed",
            unsafeBitCast(changed, to: GCallback.self),
            nil, nil, GConnectFlags(rawValue: 0)
        )
    }
    let fallback: @convention(c) (gpointer?) -> gboolean = { _ in
        rebuildBoard()
        return 1  // G_SOURCE_CONTINUE
    }
    g_timeout_add_seconds(30, fallback, nil)

    gtk_window_present(window)
}

// NON_UNIQUE: no D-Bus in the verify container (same as the PoC).
guard let app = gtk_application_new("dev.shepherd.LinuxHud", G_APPLICATION_NON_UNIQUE) else {
    fatalError("gtk_application_new failed")
}
g_signal_connect_data(
    UnsafeMutableRawPointer(app),
    "activate",
    unsafeBitCast(activateHandler, to: GCallback.self),
    nil,
    nil,
    GConnectFlags(rawValue: 0)
)
_ = g_application_run(UnsafeMutableRawPointer(app).assumingMemoryBound(to: GApplication.self), 0, nil)
