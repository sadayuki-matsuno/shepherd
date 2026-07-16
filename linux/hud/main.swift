// Walking-skeleton Linux HUD: the portable core (SessionsRegistry / Transcript /
// Models) feeding a gtk4-layer-shell OVERLAY window — proof that real session
// data reaches a Wayland overlay, not a look-alike of the macOS board.
// Built by dev/linux/hud-build.sh, machine-verified by dev/linux/hud-verify.sh.
import Foundation
import CGtkLayerShell

// Same fixture seams as Sources/main.swift (which is macOS-only and not linked here).
if let d = ProcessInfo.processInfo.environment["SHEPHERD_SESSIONS_DIR"] { claudeSessionsDir = d }
if let d = ProcessInfo.processInfo.environment["SHEPHERD_PROJECTS_DIR"] { claudeProjectsDir = d }

// The activate handler and the refresh timer are @convention(c) closures, which
// cannot capture — the row container is shared through a global instead.
var sessionsBox: UnsafeMutablePointer<GtkWidget>? = nil

func cssRGB(_ c: HUDColor) -> String {
    "rgb(\(Int(c.red * 255 + 0.5)), \(Int(c.green * 255 + 0.5)), \(Int(c.blue * 255 + 0.5)))"
}

// One row per registry session: status-coloured square + title + model/context.
// The square is a CSS-filled box, not a text glyph — font antialiasing would
// dilute the exact status colour hud-verify.sh greps for in the screenshot.
func rebuildRows() {
    guard let boxWidget = sessionsBox else { return }
    let box = UnsafeMutableRawPointer(boxWidget).assumingMemoryBound(to: GtkBox.self)
    while let child = gtk_widget_get_first_child(boxWidget) {
        gtk_box_remove(box, child)
    }
    for e in readSessionsRegistry().sorted(by: { $0.pid < $1.pid }) {
        let status = statusFromRegistry(e)
        guard let rowWidget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8) else { continue }
        let row = UnsafeMutableRawPointer(rowWidget).assumingMemoryBound(to: GtkBox.self)

        if let swatch = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) {
            gtk_widget_set_size_request(swatch, 16, 16)
            gtk_widget_set_valign(swatch, GTK_ALIGN_CENTER)
            gtk_widget_add_css_class(swatch, "st-\(status)")
            gtk_box_append(row, swatch)
        }

        let title = readTranscriptAITitle(cwd: e.cwd, sessionId: e.sessionId)
            ?? e.name ?? e.sessionId
        var text = title
        let ctx = readTranscriptContext(cwd: e.cwd, sessionId: e.sessionId)
        if let model = ctx.model { text += "  \(model.name)" }
        if let pct = ctx.pct { text += " \(Int(pct * 100))%" }
        if let label = gtk_label_new(text) {
            gtk_widget_set_halign(label, GTK_ALIGN_START)
            gtk_box_append(row, label)
        }

        gtk_box_append(box, rowWidget)
    }
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
    gtk_window_set_default_size(window, 380, 240)

    // Colours come from the core's palette/status mapping (Models.swift), so a
    // status reaching the screen proves the data path, not a hand-copied hex.
    var css = "window { background-color: \(cssRGB(Cat.base)); } label { color: \(cssRGB(Cat.text)); }\n"
    for status in ["error", "blocked", "working", "idle", "unknown"] {
        css += ".st-\(status) { background-color: \(cssRGB(style(for: status).dot)); }\n"
    }
    if let provider = gtk_css_provider_new() {
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(),
            OpaquePointer(provider),
            guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }

    if let boxWidget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6) {
        gtk_widget_set_margin_top(boxWidget, 10)
        gtk_widget_set_margin_bottom(boxWidget, 10)
        gtk_widget_set_margin_start(boxWidget, 10)
        gtk_widget_set_margin_end(boxWidget, 10)
        sessionsBox = boxWidget
        gtk_window_set_child(window, boxWidget)
    }

    rebuildRows()
    let tick: @convention(c) (gpointer?) -> gboolean = { _ in
        rebuildRows()
        return 1  // G_SOURCE_CONTINUE
    }
    g_timeout_add_seconds(3, tick, nil)

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
