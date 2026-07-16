// Layer-shell feasibility PoC: one GTK4 window on the wlr-layer-shell
// OVERLAY layer, keyboard_mode NONE (never takes focus), anchored to the
// top-right corner, filled solid #FF00FF so a screenshot can verify it
// machine-readably (dev/linux/poc-verify.sh).
import CGtkLayerShell

let activateHandler: @convention(c) (UnsafeMutablePointer<GtkApplication>?, gpointer?) -> Void = { app, _ in
    guard let widget = gtk_application_window_new(app) else { return }
    // GTK_WINDOW() and friends are C macros, invisible to Swift; the GObject
    // instance pointer is the same address for every class in the hierarchy,
    // so rebinding the pointer type is the supported equivalent.
    let window = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)

    gtk_layer_init_for_window(window)
    gtk_layer_set_layer(window, GTK_LAYER_SHELL_LAYER_OVERLAY)
    gtk_layer_set_keyboard_mode(window, GTK_LAYER_SHELL_KEYBOARD_MODE_NONE)
    gtk_layer_set_anchor(window, GTK_LAYER_SHELL_EDGE_TOP, 1)
    gtk_layer_set_anchor(window, GTK_LAYER_SHELL_EDGE_RIGHT, 1)
    gtk_layer_set_margin(window, GTK_LAYER_SHELL_EDGE_TOP, 24)
    gtk_layer_set_margin(window, GTK_LAYER_SHELL_EDGE_RIGHT, 24)

    gtk_window_set_default_size(window, 320, 200)

    let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_name(box, "poc-box")
    gtk_window_set_child(window, box)

    guard let provider = gtk_css_provider_new() else { return }
    gtk_css_provider_load_from_string(provider, "window, #poc-box { background-color: #FF00FF; }")
    // GtkStyleProvider is a GObject interface (incomplete C struct), which
    // Swift imports as OpaquePointer in signatures.
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        OpaquePointer(provider),
        guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
    )

    gtk_window_present(window)
}

// NON_UNIQUE keeps GApplication off the D-Bus session bus, which does not
// exist in the headless container (registration failure would abort run()).
guard let app = gtk_application_new("dev.shepherd.LayerShellPoc", G_APPLICATION_NON_UNIQUE) else {
    fatalError("gtk_application_new failed")
}

// g_signal_connect() is also a macro; connect through g_signal_connect_data
// with the handler bit-cast to the generic GCallback function-pointer type.
g_signal_connect_data(
    UnsafeMutableRawPointer(app),
    "activate",
    unsafeBitCast(activateHandler, to: GCallback.self),
    nil,
    nil,
    GConnectFlags(rawValue: 0)
)

_ = g_application_run(UnsafeMutableRawPointer(app).assumingMemoryBound(to: GApplication.self), 0, nil)
