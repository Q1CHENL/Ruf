import AppKit
import RufCore
import SwiftUI

private final class SettingsWindow: NSWindow {
    private var ignoresCommandWUntilCommandIsReleased = false

    override func becomeKey() {
        super.becomeKey()
        ignoresCommandWUntilCommandIsReleased = NSEvent.modifierFlags
            .contains(.command)
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) {
            ignoresCommandWUntilCommandIsReleased = false
        }

        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        if ignoresCommandWUntilCommandIsReleased,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SettingsWindowController {
    private let windowController: NSWindowController

    init(
        preferences: AppPreferences,
        softwareUpdateAvailability: SoftwareUpdateAvailability,
        onPreferencesChanged: @escaping () -> Void,
        onShowAbout: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenAccessibilitySettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        let hostingController = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                softwareUpdateAvailability: softwareUpdateAvailability,
                onPreferencesChanged: onPreferencesChanged,
                onShowAbout: onShowAbout,
                onCheckForUpdates: onCheckForUpdates,
                onOpenAccessibilitySettings: onOpenAccessibilitySettings,
                onQuit: onQuit
            )
        )
        let window = SettingsWindow(contentViewController: hostingController)
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

        let sourceApplication = NSWorkspace.shared.frontmostApplication
        if !window.isVisible {
            window.center()
        }

        window.orderFrontRegardless()

        // The switcher is a nonactivating panel, so showing its Settings target
        // begins while another app is still active. An activation request is
        // asynchronous and may leave this window visible without keyboard
        // focus; make it key only after the workspace confirms Ruf is active.
        Task { @MainActor [weak window] in
            guard await ApplicationActivation.activate(
                .current,
                from: sourceApplication,
                options: [.activateAllWindows]
            ), NSApp.isActive, let window, window.isVisible else {
                return
            }

            window.makeKeyAndOrderFront(nil)
        }
    }
}
