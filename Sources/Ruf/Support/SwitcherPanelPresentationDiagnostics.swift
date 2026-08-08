import AppKit
import CoreGraphics

@MainActor
final class SwitcherPanelPresentationDiagnostics {
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
    private struct PendingProbe {
        let token: Int
        let itemCount: Int
        let expectedSize: CGSize
        let deadline: DispatchTime
    }

    private let panel: NSPanel
    private let glassView: NSGlassEffectView
    private var pendingProbe: PendingProbe?
    // Distinguishes "this presentation is still the current one" from a panel
    // that a replayed action dismissed within the same frame.
    private var presentationToken = 0

    init(panel: NSPanel, glassView: NSGlassEffectView) {
        self.panel = panel
        self.glassView = glassView
    }

    func presentationWillBegin() {
        PerformanceLog.whenEnabled {
            resolvePendingProbe()
            presentationToken += 1
        }
    }

    func recordPresentation(itemCount: Int, expectedSize: CGSize) {
        PerformanceLog.whenEnabled {
            recordPanelState(
                "panel.configured",
                itemCount: itemCount,
                expectedSize: expectedSize,
                trustsWindowServer: false
            )
            recordPanelStateOnceSettled(
                itemCount: itemCount,
                expectedSize: expectedSize
            )
        }
    }

    func presentationWillEnd() {
        PerformanceLog.whenEnabled {
            resolvePendingProbe()
            presentationToken += 1
        }
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
                // diagnostic exists to raise.
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

        guard let description = WindowServerDescriptionReader.descriptions(
            for: [CGWindowID(windowNumber)]
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
        pendingProbe = PendingProbe(
            token: token,
            itemCount: itemCount,
            expectedSize: expectedSize,
            deadline: deadline
        )

        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self,
                  pendingProbe?.token == token else {
                return
            }

            pendingProbe = nil
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
    private func resolvePendingProbe() {
        guard let probe = pendingProbe else {
            return
        }

        pendingProbe = nil
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
}
