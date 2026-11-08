import AppKit

/// AppKit owns launch so SwiftUI cannot automatically create a window.
@main
@MainActor
enum GPUMonitorApp {
    static func main() {
        UserDefaults.standard.register(defaults: ["statusBarOnly": true])
        let app = NSApplication.shared
        let delegate = MonitorAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
