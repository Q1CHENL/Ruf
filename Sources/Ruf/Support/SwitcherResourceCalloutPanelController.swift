import AppKit
import RufCore
import SwiftUI

@MainActor
private final class SwitcherResourceCalloutPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SwitcherResourceCalloutPanelController {
    let panel: NSPanel

    private let hostingView: NSHostingView<ApplicationResourceUsageCalloutView>

    init(model: SwitcherModel) {
        let initialView = ApplicationResourceUsageCalloutView(model: model)
        hostingView = NSHostingView(rootView: initialView)
        panel = SwitcherResourceCalloutPanel(
            contentRect: CGRect(
                origin: .zero,
                size: SwitcherResourceCalloutMetrics.size
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        hostingView.frame = CGRect(
            origin: .zero,
            size: SwitcherResourceCalloutMetrics.size
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
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
        panel.animationBehavior = .none
    }

    @discardableResult
    func show(
        _ placement: SwitcherResourceCalloutPlacement,
        parent: NSWindow
    ) -> Bool {
        panel.setFrame(placement.frame, display: false)
        if panel.parent == nil {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        return panel.isVisible
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

private struct ApplicationResourceUsageCalloutView: View {
    let model: SwitcherModel

    var body: some View {
        HStack(spacing: 12) {
            metric(
                systemImage: "cpu",
                value: ApplicationResourceUsageFormatter.cpuString(
                    model.applicationResourceUsage.cpuPercentage
                )
            )
            metric(
                systemImage: "memorychip",
                value: ApplicationResourceUsageFormatter.memoryString(
                    model.applicationResourceUsage.memoryBytes
                )
            )
            metric(
                systemImage: "clock",
                value: ApplicationResourceUsageFormatter
                    .runningDurationString(
                        model.applicationResourceUsage.runningDuration
                    )
            )
        }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.primary)
            .frame(
                width: SwitcherResourceCalloutMetrics.size.width,
                height: SwitcherResourceCalloutMetrics.size.height
            )
            .background {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                Color.primary.opacity(0.14),
                                lineWidth: 0.5
                            )
                    }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.applicationResourceUsageText)
    }

    private func metric(
        systemImage: String,
        value: String
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}
