// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "poc-layershell",
    targets: [
        // gtk4-layer-shell-0.pc has "Requires: gtk4", so one pkgConfig entry
        // pulls in the full GTK4 include/link flags transitively.
        .systemLibrary(
            name: "CGtkLayerShell",
            pkgConfig: "gtk4-layer-shell-0",
            providers: [
                .apt(["libgtk-4-dev", "libgtk4-layer-shell-dev"])
            ]
        ),
        .executableTarget(
            name: "poc",
            dependencies: ["CGtkLayerShell"]
        ),
    ]
)
