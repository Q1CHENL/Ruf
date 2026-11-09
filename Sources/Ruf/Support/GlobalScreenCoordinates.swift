import AppKit
import RufCore

/// AppKit measures global coordinates from the primary display's bottom-left
/// corner; Accessibility and WindowServer measure them from its top-left
/// corner. Display and window-movement policy work in the top-left space.
enum GlobalScreenCoordinates {
    /// Converts `rect` between the two spaces. The conversion is its own
    /// inverse.
    static func flipped(_ rect: CGRect) -> CGRect {
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The screen's frame and visible frame in the top-left space.
    static func displayGeometry(of screen: NSScreen) -> DisplayGeometry {
        DisplayGeometry(
            frame: flipped(screen.frame),
            visibleFrame: flipped(screen.visibleFrame)
        )
    }
}
