import AppKit
import RufCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let windowController: NSWindowController

    init(
        preferences: AppPreferences,
        onSwitcherModeChanged: @escaping () -> Void
    ) {
        let hostingController = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                onSwitcherModeChanged: onSwitcherModeChanged
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Ruf Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.standardWindowButton(.closeButton)?.keyEquivalent = "w"
        window.standardWindowButton(.closeButton)?.keyEquivalentModifierMask = .command

        windowController = NSWindowController(window: window)
    }

    func show() {
        guard let window = windowController.window else {
            return
        }

        if !window.isVisible {
            window.center()
        }

        NSApp.activate()
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
