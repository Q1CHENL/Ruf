import AppKit
import SwiftUI

@MainActor
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SwitcherPanelController {
    // The settled sample lands 0-39ms after the ordering call (16 presentations
    // measured), and the readback had converged by then in all but one of them.
    // That interval bounds when the WindowServer was observed to agree; it is
    // not a measurement of the lag itself, which is only ever seen through this
    // sampling. The allowance sits well past it without waiting long enough for
    // an ordinary dismissal to routinely overtake the check.
    private let windowServerSettleAllowance = DispatchTimeInterval
        .milliseconds(150)

    // A probe that the next dismissal cancels leaves no verdict, which would
    // make an empty recheck log mean both "nothing needed checking" and "the
    // check was cancelled" -- and a failure during a fast switch is exactly the
    // case that would go unrecorded. Every scheduled probe reports an outcome.
    private struct PendingPresentationProbe {
        let token: Int
        let itemCount: Int
        let expectedSize: CGSize
        let deadline: DispatchTime
    }

    private var pendingPresentationProbe: PendingPresentationProbe?

    private let panel: SwitcherPanel
    private let glassView: NSGlassEffectView
    private var previouslyActiveApplication: NSRunningApplication?
    // Distinguishes "this presentation is still the current one" from a panel
    // that a replayed action dismissed within the same frame.
    private var presentationToken = 0

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
        resolvePendingPresentationProbe()
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        presentationToken += 1

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

        PerformanceLog.whenEnabled {
            recordPanelState(
                "panel.configured",
                itemCount: itemCount,
                expectedSize: size,
                trustsWindowServer: false
            )
            recordPanelStateOnceSettled(
                itemCount: itemCount,
                expectedSize: size
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else {
                return
            }

            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        resolvePendingPresentationProbe()
        presentationToken += 1
        panel.orderOut(nil)
        previouslyActiveApplication = nil
    }

    func cancel() {
        let application = previouslyActiveApplication
        hide()
        application?.activate(options: [.activateAllWindows])
    }

    // A dispatch to the main queue is not a presentation barrier -- it can run
    // while AppKit is still processing the current frame. A one-shot
    // beforeWaiting observer samples when the current run-loop iteration reaches
    // its before-sleep phase. It is later than the inline configured sample, but
    // is not a WindowServer or compositor barrier.
    private func recordPanelStateOnceSettled(
        itemCount: Int,
        expectedSize: CGSize
    ) {
        let token = presentationToken
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            0
        ) { observer, _ in
            if let observer {
                CFRunLoopRemoveObserver(
                    CFRunLoopGetMain(),
                    observer,
                    .commonModes
                )
            }

            // The observer is created and fired by the main run loop, so this
            // is the main actor even though CoreFoundation cannot say so.
            MainActor.assumeIsolated {
                // A replayed action can commit and dismiss the switcher within
                // the same frame that presented it. That panel is legitimately
                // gone by the time the loop idles, and reporting it as a failed
                // presentation would be a false alarm on the one signal this
                // whole diagnostic exists to raise.
                guard token == self.presentationToken else {
                    PerformanceLog.record(
                        "panel.settled",
                        nanoseconds: 0,
                        "items=\(itemCount) dismissedBeforeSettling"
                    )
                    return
                }

                let windowServerAgrees = self.recordPanelState(
                    "panel.settled",
                    itemCount: itemCount,
                    expectedSize: expectedSize,
                    trustsWindowServer: false
                )

                // The failure being hunted is persistent -- every open, until
                // relaunch -- so a disagreement that clears on its own was the
                // WindowServer lagging, and only one that survives a second
                // look is the invisible panel.
                guard !windowServerAgrees else {
                    return
                }

                self.recordPanelStateAfterWindowServerLag(
                    itemCount: itemCount,
                    expectedSize: expectedSize,
                    token: token
                )
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // The panel draws none of its own pixels: it is transparent, shadowless,
    // and every visible thing in it comes from the glass view and the SwiftUI
    // content inside. A failure in that stack leaves a window AppKit still
    // reports as visible and ordered front while the user sees nothing, which
    // is indistinguishable from "the switcher never opened" from the outside.
    // These readings are what tells those two apart after the fact.
    @discardableResult
    private func recordPanelState(
        _ phase: StaticString,
        itemCount: Int,
        expectedSize: CGSize,
        trustsWindowServer: Bool
    ) -> Bool {
        let frame = panel.frame
        let isOnAScreen = panel.screen != nil
        let intersectsAScreen = NSScreen.screens.contains {
            $0.frame.intersects(frame)
        }
        let hasContentSize = frame.width > 1 && frame.height > 1
        let matchesExpectedSize = abs(frame.width - expectedSize.width) < 1
            && abs(frame.height - expectedSize.height) < 1
        let contentFrame = glassView.frame
        // Every pixel the user sees comes through the glass view, so a glass
        // frame that is zero or left at a previous size is the failure this
        // diagnostic is looking for, not a detail to record and pass over.
        let glassMatchesExpectedSize = abs(
            contentFrame.width - expectedSize.width
        ) < 1 && abs(contentFrame.height - expectedSize.height) < 1
        let hostingBounds = glassView.contentView?.bounds ?? .zero
        let windowServer = windowServerReadback(expectedSize: expectedSize)

        let detail = "items=\(itemCount) "
            + "visible=\(panel.isVisible) "
            + "key=\(panel.isKeyWindow) "
            + "alpha=\(panel.alphaValue) "
            + "occluded=\(!panel.occlusionState.contains(.visible)) "
            + "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) "
            + "\(Int(frame.width))x\(Int(frame.height)) "
            + "expected=\(Int(expectedSize.width))x\(Int(expectedSize.height)) "
            + "glass=\(Int(contentFrame.width))x\(Int(contentFrame.height)) "
            + "hosting=\(Int(hostingBounds.width))x\(Int(hostingBounds.height)) "
            + "onScreen=\(isOnAScreen) "
            + "intersectsScreen=\(intersectsAScreen) "
            + "screens=\(NSScreen.screens.count) "
            + windowServer.detail

        // A reading that fails any of these is the invisible-panel state, and
        // saying so in the record means a recurrence does not need the user to
        // have noticed the exact moment it happened. occlusionState is recorded
        // but deliberately absent: it is asynchronous, and reads as occluded on
        // a perfectly healthy present that the run loop has not caught up with.
        // The WindowServer is a separate process, so neither the ordering call
        // returning nor the run loop going idle means it has caught up: the run
        // loop was once seen idling within 1ms of the request while the window
        // was still reported at its pre-resize size. Its
        // answer therefore only counts once it has been given time to settle,
        // which `trustsWindowServer` marks -- the recheck phase, not before.
        let isPresentedProperly = panel.isVisible
            && panel.alphaValue > 0.01
            && hasContentSize
            && matchesExpectedSize
            && glassMatchesExpectedSize
            && isOnAScreen
            && intersectsAScreen
            && hostingBounds.width > 1
            && hostingBounds.height > 1
            && (!trustsWindowServer || windowServer.isPresented)

        PerformanceLog.record(
            phase,
            nanoseconds: 0,
            isPresentedProperly ? detail : "SUSPECT " + detail
        )
        return windowServer.isPresented
    }

    // AppKit's answer about a window it was just told to order front is largely
    // the value that was written to it a moment ago. The WindowServer keeps its
    // own record, so reading the panel back by its window number asks an
    // independent source whether the system agrees the window is on screen,
    // where, and at what alpha. It still stops short of proving pixels -- only a
    // screen capture does that -- but it is no longer a restatement of local
    // state.
    private func windowServerReadback(
        expectedSize: CGSize
    ) -> (detail: String, isPresented: Bool) {
        let windowNumber = panel.windowNumber
        guard windowNumber > 0 else {
            return ("ws=noWindowNumber", false)
        }

        let identifiers = [CGWindowID(windowNumber)]
            .map { UnsafeRawPointer(bitPattern: UInt($0)) }
            .withUnsafeBufferPointer {
                CFArrayCreate(
                    nil,
                    UnsafeMutablePointer(mutating: $0.baseAddress),
                    $0.count,
                    nil
                )
            }
        guard let description = (
            CGWindowListCreateDescriptionFromArray(identifiers)
                as? [[String: Any]]
        )?.first else {
            return ("ws=absent", false)
        }

        let bounds = description[kCGWindowBounds as String] as? [String: Any]
        let width = Int(bounds?["Width"] as? Double ?? -1)
        let height = Int(bounds?["Height"] as? Double ?? -1)

        let isOnScreen = description[
            kCGWindowIsOnscreen as String
        ] as? Bool ?? false
        let alpha = description[kCGWindowAlpha as String] as? Double ?? -1
        let matchesExpectedSize = abs(Double(width) - expectedSize.width) < 1
            && abs(Double(height) - expectedSize.height) < 1

        return (
            "wsOnScreen=\(isOnScreen) "
                + "wsAlpha=\(alpha) "
                + "wsLayer=\(description[kCGWindowLayer as String] as? Int ?? -1) "
                + "wsSize=\(width)x\(height)",
            isOnScreen && alpha > 0.01 && matchesExpectedSize
        )
    }

    private func recordPanelStateAfterWindowServerLag(
        itemCount: Int,
        expectedSize: CGSize,
        token: Int
    ) {
        let deadline = DispatchTime.now() + windowServerSettleAllowance
        pendingPresentationProbe = PendingPresentationProbe(
            token: token,
            itemCount: itemCount,
            expectedSize: expectedSize,
            deadline: deadline
        )

        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self,
                  pendingPresentationProbe?.token == token else {
                return
            }

            pendingPresentationProbe = nil
            recordPanelState(
                "panel.recheck",
                itemCount: itemCount,
                expectedSize: expectedSize,
                trustsWindowServer: true
            )
        }
    }

    // Reached when the switcher ends before the allowance does. The reading is
    // still worth taking: the WindowServer may have caught up in the meantime,
    // and if it has not, whether the allowance had elapsed is what separates a
    // verdict from an interrupted measurement.
    private func resolvePendingPresentationProbe() {
        guard let probe = pendingPresentationProbe else {
            return
        }

        pendingPresentationProbe = nil
        let windowServer = windowServerReadback(
            expectedSize: probe.expectedSize
        )
        let outcome: String
        if windowServer.isPresented {
            outcome = "recoveredBeforeDismissal"
        } else if DispatchTime.now() < probe.deadline {
            outcome = "INCONCLUSIVE dismissedBeforeAllowance"
        } else {
            outcome = "SUSPECT dismissedAfterAllowance"
        }

        PerformanceLog.record(
            "panel.recheck",
            nanoseconds: 0,
            "items=\(probe.itemCount) \(outcome) " + windowServer.detail
        )
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
