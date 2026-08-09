import AppKit

@MainActor
private final class WindowMovementOutlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowMovementOutlineController {
    private let panel: WindowMovementOutlinePanel
    private let outlineView: NSView

    init() {
        let panel = WindowMovementOutlinePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let outlineView = NSView()
        self.panel = panel
        self.outlineView = outlineView

        outlineView.wantsLayer = true
        outlineView.layer?.borderWidth = 3
        outlineView.layer?.cornerRadius = 12
        outlineView.layer?.cornerCurve = .continuous

        panel.contentView = outlineView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
    }

    func show(accessibilityFrame: CGRect) {
        updateAppearance()
        update(accessibilityFrame: accessibilityFrame)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func update(accessibilityFrame: CGRect) {
        panel.setFrame(
            appKitFrame(from: accessibilityFrame),
            display: true
        )
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func updateAppearance() {
        let accentColor = NSColor.controlAccentColor
        outlineView.layer?.backgroundColor = accentColor
            .withAlphaComponent(0.12)
            .cgColor
        outlineView.layer?.borderColor = accentColor
            .withAlphaComponent(0.9)
            .cgColor
    }

    private func appKitFrame(from accessibilityFrame: CGRect) -> CGRect {
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: accessibilityFrame.minX,
            y: primaryDisplayHeight - accessibilityFrame.maxY,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }
}
