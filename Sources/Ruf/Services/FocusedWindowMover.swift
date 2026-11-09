import AppKit
@preconcurrency import ApplicationServices
import QuartzCore
import RufCore

/// Applies `WindowMovementSession`'s decisions to the focused window: reads
/// it through Accessibility, writes frames on `windowWriter`, and presents
/// the Ghost outline and the display link that paces the animation.
@MainActor
final class FocusedWindowMover: NSObject {
    private enum WindowMutationTarget {
        case appKit(NSWindow)
        case accessibility(AXUIElement)
    }

    /// Identified by its Accessibility element; written through `target`.
    private struct MovingWindow: Equatable {
        let element: AXUIElement
        let target: WindowMutationTarget

        static func == (lhs: Self, rhs: Self) -> Bool {
            CFEqual(lhs.element, rhs.element)
        }
    }

    private struct WindowSnapshot {
        let window: MovingWindow
        let frame: CGRect
    }

    // AXUIElement is an immutable CF handle. The actual AX mutations below
    // are serialized on windowWriter; Swift does not declare the handle
    // Sendable even though Accessibility calls support cross-thread use.
    private struct WindowMutationRequest: @unchecked Sendable {
        let window: AXUIElement
        let mutations: [WindowFrameMutation]
        let purpose: WindowMovementWritePurpose
        let animationIdentifier: UInt64
    }

    private static let queryMessagingTimeout: Float = 0.05
    nonisolated private static let frameMessagingTimeout: Float = 0.005
    nonisolated private static let placementMessagingTimeout: Float = 0.05
    private static let fullScreenAttribute = "AXFullScreen"

    private let outlineController = WindowMovementOutlineController()
    private let windowWriter = DispatchQueue(
        label: "com.qichen.ruf.window-writer",
        qos: .userInteractive
    )
    private var session = WindowMovementSession<MovingWindow>()
    private var displayLink: CADisplayLink?
    private var displayLinkDisplayFrame: CGRect?
    private var windowWrites = CoalescingRequestQueue<
        WindowMutationRequest,
        UInt64
    >()

    func move(
        _ direction: WindowMoveDirection,
        style: WindowMovementStyle
    ) {
        guard AccessibilityPermission.isGranted else {
            return
        }

        let displays = NSScreen.screens.map(
            GlobalScreenCoordinates.displayGeometry(of:)
        )
        guard displays.count > 1 else {
            apply(session.displaysDidChange(displays))
            return
        }

        guard let snapshot = focusedWindow() else {
            return
        }

        apply(
            session.move(
                direction,
                style: style,
                reducesMotion: NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion,
                window: snapshot.window,
                frame: snapshot.frame,
                displays: displays,
                at: CACurrentMediaTime(),
                canResize: {
                    isSizeSettable(of: snapshot.window.element)
                }
            )
        )
    }

    func stop() {
        apply(session.shutDown(), synchronously: true)
    }

    private func apply(
        _ effects: [WindowMovementEffect<MovingWindow>],
        synchronously: Bool = false
    ) {
        for effect in effects {
            switch effect {
            case let .write(write):
                perform(write, synchronously: synchronously)
            case let .discardPendingWrites(animationIdentifier):
                windowWrites.removePendingRequests(
                    coalescingKey: animationIdentifier
                )
            }
        }
        updatePresentation()
    }

    private func updatePresentation() {
        if let outlineFrame = session.outlineFrame {
            outlineController.show(frame: appKitFrame(from: outlineFrame))
        } else {
            outlineController.hide()
        }

        let animatingDisplay = session.animatingDisplay
        guard animatingDisplay?.frame != displayLinkDisplayFrame else {
            return
        }

        displayLink?.invalidate()
        displayLink = nil
        displayLinkDisplayFrame = nil
        guard let animatingDisplay,
              let screen = NSScreen.screens.first(where: {
                  GlobalScreenCoordinates.displayGeometry(of: $0).frame
                      == animatingDisplay.frame
              }) else {
            return
        }

        let displayLink = screen.displayLink(
            target: self,
            selector: #selector(advanceAnimation(_:))
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        displayLinkDisplayFrame = animatingDisplay.frame
    }

    @objc
    private func advanceAnimation(_ displayLink: CADisplayLink) {
        guard displayLink === self.displayLink else {
            displayLink.invalidate()
            return
        }

        apply(session.advance(to: displayLink.targetTimestamp))
    }

    private func perform(
        _ write: WindowMovementWrite<MovingWindow>,
        synchronously: Bool
    ) {
        switch write.window.target {
        case let .appKit(window):
            window.setFrame(appKitFrame(from: write.frame), display: true)
            apply(
                session.writeDidFinish(
                    write.purpose,
                    animationIdentifier: write.animationIdentifier,
                    succeeded: true
                )
            )
        case let .accessibility(element):
            let request = WindowMutationRequest(
                window: element,
                mutations: write.mutations,
                purpose: write.purpose,
                animationIdentifier: write.animationIdentifier
            )
            if synchronously {
                windowWriter.sync {
                    _ = Self.performWindowMutation(request)
                }
            } else if let requestToStart = windowWrites.submit(
                request,
                // Settling is never replaced or discarded.
                coalescingKey: write.purpose == .settle
                    ? nil
                    : write.animationIdentifier
            ) {
                startWindowMutation(requestToStart)
            }
        }
    }

    private func startWindowMutation(_ request: WindowMutationRequest) {
        windowWriter.async { [weak self] in
            let succeeded = Self.performWindowMutation(request)

            DispatchQueue.main.async { [weak self] in
                self?.windowMutationDidFinish(
                    request,
                    succeeded: succeeded
                )
            }
        }
    }

    private func windowMutationDidFinish(
        _ request: WindowMutationRequest,
        succeeded: Bool
    ) {
        apply(
            session.writeDidFinish(
                request.purpose,
                animationIdentifier: request.animationIdentifier,
                succeeded: succeeded
            )
        )

        if let nextRequest = windowWrites.completeCurrentRequest() {
            startWindowMutation(nextRequest)
        }
    }

    private func focusedWindow() -> WindowSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let applicationElement = AXClientContext.applicationElement(
            for: application.processIdentifier
        )
        AXClientContext.setMessagingTimeout(
            Self.queryMessagingTimeout,
            for: applicationElement
        )

        let focusedWindowAttribute = copyFocusedWindowAttribute(
            from: applicationElement
        )
        guard focusedWindowAttribute.error == .success,
              let rawWindow = focusedWindowAttribute.value,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            return nil
        }

        let window = rawWindow as! AXUIElement
        AXClientContext.setMessagingTimeout(
            Self.queryMessagingTimeout,
            for: window
        )

        // Full-screen state rides along with the geometry read. Windows that
        // do not publish the attribute return an error entry instead, which
        // fails the cast and reads as "not full screen" exactly as a separate
        // unsupported-attribute request would.
        guard let values = AXElementReader.values(
            of: [
                kAXRoleAttribute,
                kAXSubroleAttribute,
                kAXPositionAttribute,
                kAXSizeAttribute,
                Self.fullScreenAttribute,
            ],
            from: window
        ),
              let role = values[0] as? String,
              role == kAXWindowRole,
              let subrole = values[1] as? String,
              subrole == kAXStandardWindowSubrole,
              values[4] as? Bool != true,
              isPositionSettable(of: window),
              let position: CGPoint = AXElementReader.decodedAXValue(
                  values[2],
                  type: .cgPoint,
                  initialValue: .zero
              ),
              let size: CGSize = AXElementReader.decodedAXValue(
                  values[3],
                  type: .cgSize,
                  initialValue: .zero
              ),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        let target: WindowMutationTarget
        if application.processIdentifier
            == ProcessInfo.processInfo.processIdentifier {
            guard let keyWindow = NSApp.keyWindow, keyWindow.isVisible else {
                return nil
            }
            target = .appKit(keyWindow)
        } else {
            target = .accessibility(window)
        }

        return WindowSnapshot(
            window: MovingWindow(element: window, target: target),
            frame: CGRect(origin: position, size: size)
        )
    }

    private func copyFocusedWindowAttribute(
        from application: AXUIElement
    ) -> (value: CFTypeRef?, error: AXError) {
        let initialAttribute = copyAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: application
        )
        guard initialAttribute.error == .apiDisabled else {
            return initialAttribute
        }

        return AXClientContext.withVoiceOverIdentity {
            // Chromium app shims enable their per-app partial AX mode when a
            // VoiceOver client queries the application's role.
            _ = copyAttribute(
                kAXRoleAttribute as CFString,
                from: application
            )
            return copyAttribute(
                kAXFocusedWindowAttribute as CFString,
                from: application
            )
        } ?? initialAttribute
    }

    private func copyAttribute(
        _ name: CFString,
        from element: AXUIElement
    ) -> (value: CFTypeRef?, error: AXError) {
        AXClientContext.withDefaultIdentity {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                element,
                name,
                &value
            )
            return (value, error)
        }
    }

    private func appKitFrame(from accessibilityFrame: CGRect) -> CGRect {
        GlobalScreenCoordinates.flipped(accessibilityFrame)
    }

    private func isPositionSettable(of window: AXUIElement) -> Bool {
        isAttributeSettable(kAXPositionAttribute as CFString, of: window)
    }

    private func isSizeSettable(of window: AXUIElement) -> Bool {
        isAttributeSettable(kAXSizeAttribute as CFString, of: window)
    }

    private func isAttributeSettable(
        _ attribute: CFString,
        of window: AXUIElement
    ) -> Bool {
        AXClientContext.withDefaultIdentity {
            var isSettable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(
                window,
                attribute,
                &isSettable
            ) == .success && isSettable.boolValue
        }
    }

    nonisolated private static func performWindowMutation(
        _ request: WindowMutationRequest
    ) -> Bool {
        let messagingTimeout = switch request.purpose {
        case .frame:
            frameMessagingTimeout
        case .finalPlacement, .settle:
            placementMessagingTimeout
        }
        AXClientContext.setMessagingTimeout(
            messagingTimeout,
            for: request.window
        )

        for mutation in request.mutations {
            let error = switch mutation {
            case let .position(position):
                setPosition(position, of: request.window)
            case let .size(size):
                setSize(size, of: request.window)
            }
            guard WindowMutationPolicy.accepts(
                mutationOutcome(for: error)
            ) else {
                return false
            }
        }

        return true
    }

    nonisolated private static func mutationOutcome(
        for error: AXError
    ) -> WindowMutationOutcome {
        switch error {
        case .success:
            .succeeded
        case .cannotComplete:
            .indeterminate
        default:
            .failed
        }
    }

    nonisolated private static func setSize(
        _ size: CGSize,
        of window: AXUIElement
    ) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            return .failure
        }

        return AXClientContext.withDefaultIdentity {
            AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                value
            )
        }
    }

    nonisolated private static func setPosition(
        _ position: CGPoint,
        of window: AXUIElement
    ) -> AXError {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else {
            return .failure
        }

        return AXClientContext.withDefaultIdentity {
            AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                value
            )
        }
    }
}
