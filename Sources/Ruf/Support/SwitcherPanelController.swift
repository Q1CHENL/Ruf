import AppKit
import SwiftUI

@MainActor
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SwitcherPanelController {
    private let panel: SwitcherPanel
    private let glassView: NSGlassEffectView
    private var previouslyActiveApplication: NSRunningApplication?

    init(
        model: SwitcherModel,
        onChoose: @escaping (Int) -> Void
    ) {
        let hostingView = NSHostingView(
            rootView: SwitcherView(
                model: model,
                onChoose: onChoose
            )
        )
        glassView = NSGlassEffectView()
        panel = SwitcherPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        glassView.style = .regular
        // The glass material's own rounded SDF draws an adaptive optical rim
        // at each corner. Keep the material square and let one continuous
        // clipping layer own the pane's visible shape instead.
        glassView.cornerRadius = 0
        glassView.contentView = hostingView
        glassView.autoresizingMask = [.width, .height]
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = SwitcherMetrics.cornerRadius
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.masksToBounds = true

        panel.contentView = glassView
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
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
    }

    func prepare(itemCount: Int) {
        resize(itemCount: itemCount)
        glassView.layoutSubtreeIfNeeded()
    }

    func show(itemCount: Int) {
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication

        // Resizing forces the hosting view to lay the grid out, so the first
        // SwiftUI evaluation of a new target list lands here rather than in
        // the ordering call below.
        let resizeSpan = PerformanceLog.begin("panel.resize")
        let size = resize(itemCount: itemCount)
        PerformanceLog.end(resizeSpan, "items=\(itemCount)")

        let originSpan = PerformanceLog.begin("panel.origin")
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(
                CGPoint(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.midY - size.height / 2
                )
            )
        }
        PerformanceLog.end(originSpan)

        let orderFrontSpan = PerformanceLog.begin("panel.orderFront")
        panel.makeKeyAndOrderFront(nil)
        PerformanceLog.end(orderFrontSpan, "items=\(itemCount)")

        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else {
                return
            }

            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        panel.orderOut(nil)
        previouslyActiveApplication = nil
    }

    func cancel() {
        let application = previouslyActiveApplication
        hide()
        application?.activate(options: [.activateAllWindows])
    }

    @discardableResult
    private func resize(itemCount: Int) -> CGSize {
        let metricsSpan = PerformanceLog.begin("panel.metrics")
        let size = SwitcherMetrics.panelSize(itemCount: itemCount)
        PerformanceLog.end(metricsSpan)

        let contentSizeSpan = PerformanceLog.begin("panel.setContentSize")
        panel.setContentSize(size)
        PerformanceLog.end(contentSizeSpan)

        let glassFrameSpan = PerformanceLog.begin("panel.glassFrame")
        glassView.frame = CGRect(origin: .zero, size: size)
        PerformanceLog.end(glassFrameSpan)

        return size
    }
}
