import AppKit
import Foundation
import Observation

/// Tracks whether any app window is visible on screen (not minimized, not hidden, not fully occluded).
@MainActor
@Observable
final class WindowVisibilityMonitor {
    private(set) var isVisibleOnDisplay = true

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        refresh()

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.refresh()
                    }
                }
            )
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func refresh() {
        let visible = Self.isAnyWindowVisibleOnDisplay()
        guard visible != isVisibleOnDisplay else { return }
        isVisibleOnDisplay = visible
    }

    private static func isAnyWindowVisibleOnDisplay() -> Bool {
        guard NSApp.isActive, !NSApp.isHidden else { return false }
        return NSApp.windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }
}
