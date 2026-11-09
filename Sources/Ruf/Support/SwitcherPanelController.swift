import AppKit
import RufCore
import SwiftUI

@MainActor
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SwitcherPanelController {
    private let model: SwitcherModel
    private let panel: SwitcherPanel
    private let glassView: NSGlassEffectView
    private let applicationResourceUsageCallout:
        SwitcherResourceCalloutPanelController
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
        let glassView = NSGlassEffectView()
        let panel = SwitcherPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.model = model
        self.glassView = glassView
        self.panel = panel
        applicationResourceUsageCallout =
            SwitcherResourceCalloutPanelController(model: model)

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

    var isVisible: Bool {
        panel.isVisible
    }

    func prepare() {
        resize(for: model.navigation)
        glassView.layoutSubtreeIfNeeded()
    }

    /// Shows the model's current grid centred on `screen`, which should be
    /// the screen whose visible height bounded the grid's rows.
    func show(on screen: NSScreen?) {
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        let navigation = model.navigation
        let itemCount = navigation.itemCount

        // Resizing forces the hosting view to lay the grid out, so the first
        // SwiftUI evaluation of a new target list lands here rather than in
        // the ordering call below.
        let resizeSpan = PerformanceLog.begin("panel.resize")
        let size = resize(for: navigation)
        PerformanceLog.end(resizeSpan, "items=\(itemCount)")

        let originSpan = PerformanceLog.begin("panel.origin")
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
        applicationResourceUsageCallout.hide()
        panel.orderOut(nil)
        previouslyActiveApplication = nil
    }

    func cancel() {
        let application = previouslyActiveApplication
        hide()
        application?.activate(options: [.activateAllWindows])
    }

    @discardableResult
    func updateApplicationResourceUsageCallout() -> Bool {
        guard panel.isVisible,
              model.showsApplicationResourceUsage,
              let selectedIndex = model.selectedIndex,
              let screen = panel.screen
                ?? NSScreen.screens.first(where: {
                    $0.frame.contains(
                        CGPoint(x: panel.frame.midX, y: panel.frame.midY)
                    )
                }),
              let placement = SwitcherResourceCalloutPlacement.resolve(
                  selectedIndex: selectedIndex,
                  navigation: model.navigation,
                  panelFrame: panel.frame,
                  visibleFrame: screen.visibleFrame
              ) else {
            applicationResourceUsageCallout.hide()
            return false
        }

        return applicationResourceUsageCallout.show(placement, parent: panel)
    }

    @discardableResult
    private func resize(for navigation: GridNavigation) -> CGSize {
        let metricsSpan = PerformanceLog.begin("panel.metrics")
        let size = SwitcherMetrics.panelSize(for: navigation)
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
