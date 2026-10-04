import AppKit

/// macOS app lifecycle: dock presence, icon, and bring-to-front on dock click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppDockIcon.installIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApp.windows where window.canBecomeKey && !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

@MainActor
enum AppDockIcon {
    static func installIfNeeded() {
        guard NSApp.applicationIconImage == nil else { return }
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}
