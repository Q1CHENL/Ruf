import AppKit
import RufCore

/// Where Ruf presents its own windows: on the display the user is working
/// on rather than on whichever display last showed them.
@MainActor
enum PresentationScreen {
    /// The screen showing `application`'s frontmost window, or the screen
    /// under the pointer when that application shows no window.
    static func resolve(for application: NSRunningApplication?) -> NSScreen? {
        let screens = NSScreen.screens
        if let application,
           let windowFrame = WindowServerDescriptionReader.frontmostWindowFrame(
               ownedBy: application.processIdentifier
           ) {
            // WindowServer frames share the displays' top-left-origin space.
            let displays = screens.map(
                GlobalScreenCoordinates.displayGeometry(of:)
            )
            if let display = WindowMovementPlanner.sourceDisplay(
                for: windowFrame,
                displays: displays
            ), let index = displays.firstIndex(of: display) {
                return screens[index]
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? screens.first
    }
}
