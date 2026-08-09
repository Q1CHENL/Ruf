import AppKit
@preconcurrency import ApplicationServices
import QuartzCore
import RufCore

@MainActor
final class FocusedWindowMover: NSObject {
    private struct ScreenSnapshot {
        let screen: NSScreen
        let geometry: DisplayGeometry
    }

    private enum WindowMutationTarget {
        case appKit(NSWindow)
        case accessibility(AXUIElement)
    }

    private struct WindowSnapshot {
        let element: AXUIElement
        let mutationTarget: WindowMutationTarget
        let frame: CGRect
    }

    private struct ActiveAnimation {
        let identifier: UInt64
        let window: AXUIElement
        let mutationTarget: WindowMutationTarget
        let startFrame: CGRect
        let mutationPlan: WindowMovementMutationPlan
        let destinationDisplayFrame: CGRect
        let style: WindowMovementStyle
        let startTimestamp: CFTimeInterval
        var currentFrame: CGRect

        var destinationFrame: CGRect {
            mutationPlan.destinationFrame
        }
    }

    private enum MutationPurpose: Sendable {
        case frame(animationIdentifier: UInt64)
        case animationCompletion(animationIdentifier: UInt64)
        case placement

        var animationIdentifier: UInt64? {
            switch self {
            case let .frame(animationIdentifier),
                 let .animationCompletion(animationIdentifier):
                animationIdentifier
            case .placement:
                nil
            }
        }
    }

    private enum MutationResolution: Equatable, Sendable {
        case proceed
        case fail
    }

    // AXUIElement is an immutable CF handle. The actual AX mutations below
    // are serialized on windowWriter; Swift does not declare the handle
    // Sendable even though Accessibility calls support cross-thread use.
    private struct WindowMutationRequest: @unchecked Sendable {
        let window: AXUIElement
        let mutations: [WindowFrameMutation]
        let purpose: MutationPurpose
    }

    private static let animationDuration: CFTimeInterval = 0.2
    private static let queryMessagingTimeout: Float = 0.05
    nonisolated private static let frameMessagingTimeout: Float = 0.005
    nonisolated private static let placementMessagingTimeout: Float = 0.05
    private static let fullScreenAttribute = "AXFullScreen"

    private let planner = WindowMovementPlanner()
    private let outlineController = WindowMovementOutlineController()
    private let windowWriter = DispatchQueue(
        label: "com.qichen.ruf.window-writer",
        qos: .userInteractive
    )
    private var activeAnimation: ActiveAnimation?
    private var displayLink: CADisplayLink?
    private var nextAnimationIdentifier: UInt64 = 0
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

        let screens = screenSnapshots()
        guard screens.count > 1 else {
            stopAnimation(.displayConfigurationChanged)
            return
        }

        guard let window = focusedWindow() else {
            return
        }

        let retargeting: (
            animation: ActiveAnimation,
            source: DisplayGeometry
        )?
        if let animation = activeAnimation {
            let destinationScreen = screens.first {
                $0.geometry.frame == animation.destinationDisplayFrame
            }
            if let reason = WindowMovementAnimationStopReason.beforeMove(
                destinationExists: destinationScreen != nil,
                focusedWindowMatches: CFEqual(animation.window, window.element)
            ) {
                stopAnimation(reason)
                retargeting = nil
            } else {
                retargeting = destinationScreen.map {
                    (animation: animation, source: $0.geometry)
                }
            }
        } else {
            retargeting = nil
        }

        let planningFrame = retargeting?.animation.destinationFrame
            ?? window.frame
        guard let plan = planner.plan(
            windowFrame: planningFrame,
            displays: screens.map(\.geometry),
            direction: direction,
            preferredSourceDisplay: retargeting?.source
        ), let destinationScreen = screens.first(where: {
            $0.geometry == plan.destinationDisplay
        }) else {
            return
        }

        let mutationPlan = WindowMovementMutationPlan(
            from: window.frame,
            to: plan.destinationFrame
        )
        guard !mutationPlan.requiresResize
                || isSizeSettable(of: window.element) else {
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAnimation(.retargeted)
            placeWindow(
                target: window.mutationTarget,
                with: mutationPlan,
                purpose: .placement
            )
            return
        }

        let startFrame: CGRect
        if let previous = retargeting?.animation,
           previous.style == .outline,
           style == .outline {
            startFrame = previous.currentFrame
        } else {
            startFrame = window.frame
        }

        startAnimation(
            window: window.element,
            mutationTarget: window.mutationTarget,
            from: startFrame,
            with: mutationPlan,
            on: destinationScreen,
            style: style
        )
    }

    func stop() {
        stopAnimation(.shutdown)
    }

    private func startAnimation(
        window: AXUIElement,
        mutationTarget: WindowMutationTarget,
        from startFrame: CGRect,
        with mutationPlan: WindowMovementMutationPlan,
        on destinationScreen: ScreenSnapshot,
        style: WindowMovementStyle
    ) {
        let preservesOutline = activeAnimation?.style == .outline
            && style == .outline
        stopAnimation(.retargeted, hidesOutline: !preservesOutline)

        let needsAnimation = switch style {
        case .live:
            startFrame.origin != mutationPlan.destinationPosition
        case .outline:
            startFrame != mutationPlan.destinationFrame
        }
        guard needsAnimation else {
            outlineController.hide()
            placeWindow(
                target: mutationTarget,
                with: mutationPlan,
                purpose: .placement
            )
            return
        }

        nextAnimationIdentifier += 1
        activeAnimation = ActiveAnimation(
            identifier: nextAnimationIdentifier,
            window: window,
            mutationTarget: mutationTarget,
            startFrame: startFrame,
            mutationPlan: mutationPlan,
            destinationDisplayFrame: destinationScreen.geometry.frame,
            style: style,
            startTimestamp: CACurrentMediaTime(),
            currentFrame: startFrame
        )

        if style == .outline {
            outlineController.show(accessibilityFrame: startFrame)
        }

        let displayLink = destinationScreen.screen.displayLink(
            target: self,
            selector: #selector(advanceAnimation(_:))
        )
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc
    private func advanceAnimation(_ displayLink: CADisplayLink) {
        guard displayLink === self.displayLink,
              let animation = activeAnimation else {
            displayLink.invalidate()
            return
        }

        let progress = CGFloat(
            min(
                1,
                max(
                    0,
                    (displayLink.targetTimestamp - animation.startTimestamp)
                        / Self.animationDuration
                )
            )
        )
        let frame = interpolatedFrame(
            from: animation.startFrame,
            to: animation.destinationFrame,
            progress: easeInOutCubic(progress),
            style: animation.style
        )
        activeAnimation?.currentFrame = frame

        if animation.style == .outline {
            outlineController.update(accessibilityFrame: frame)
        }

        if progress >= 1 {
            displayLink.invalidate()
            self.displayLink = nil
            placeWindow(
                target: animation.mutationTarget,
                with: animation.mutationPlan,
                purpose: .animationCompletion(
                    animationIdentifier: animation.identifier
                )
            )
        } else if animation.style == .live {
            moveWindow(
                target: animation.mutationTarget,
                to: frame,
                purpose: .frame(
                    animationIdentifier: animation.identifier
                )
            )
        }
    }

    private func interpolatedFrame(
        from start: CGRect,
        to destination: CGRect,
        progress: CGFloat,
        style: WindowMovementStyle
    ) -> CGRect {
        let size = switch style {
        case .live:
            start.size
        case .outline:
            CGSize(
                width: start.width
                    + (destination.width - start.width) * progress,
                height: start.height
                    + (destination.height - start.height) * progress
            )
        }

        return CGRect(
            origin: CGPoint(
                x: start.minX + (destination.minX - start.minX) * progress,
                y: start.minY + (destination.minY - start.minY) * progress
            ),
            size: size
        )
    }

    private func stopAnimation(
        _ reason: WindowMovementAnimationStopReason,
        hidesOutline: Bool = true
    ) {
        let animation = activeAnimation
        displayLink?.invalidate()
        displayLink = nil
        activeAnimation = nil

        guard let animation else {
            return
        }

        if hidesOutline, animation.style == .outline {
            outlineController.hide()
        }
        windowWrites.removePendingRequests(
            coalescingKey: animation.identifier
        )

        guard reason.settlesAtDestination else {
            return
        }

        placeWindow(
            target: animation.mutationTarget,
            with: animation.mutationPlan,
            purpose: .placement,
            synchronously: reason == .shutdown
        )
    }

    private func moveWindow(
        target: WindowMutationTarget,
        to frame: CGRect,
        purpose: MutationPurpose
    ) {
        switch target {
        case let .accessibility(window):
            enqueueWindowMutation(
                WindowMutationRequest(
                    window: window,
                    mutations: [.position(frame.origin)],
                    purpose: purpose
                )
            )
        case let .appKit(window):
            window.setFrame(
                appKitFrame(from: frame),
                display: true
            )
            mutationDidFinish(purpose, resolution: .proceed)
        }
    }

    private func placeWindow(
        target: WindowMutationTarget,
        with plan: WindowMovementMutationPlan,
        purpose: MutationPurpose,
        synchronously: Bool = false
    ) {
        switch target {
        case let .appKit(window):
            window.setFrame(
                appKitFrame(from: plan.destinationFrame),
                display: true
            )
            mutationDidFinish(purpose, resolution: .proceed)
        case let .accessibility(window):
            let request = WindowMutationRequest(
                window: window,
                mutations: plan.finalPlacementMutations,
                purpose: purpose
            )
            if synchronously {
                windowWriter.sync {
                    _ = Self.performWindowMutation(request)
                }
            } else {
                enqueueWindowMutation(request)
            }
        }
    }

    private func enqueueWindowMutation(_ request: WindowMutationRequest) {
        guard let requestToStart = windowWrites.submit(
            request,
            coalescingKey: request.purpose.animationIdentifier
        ) else {
            return
        }

        startWindowMutation(requestToStart)
    }

    private func startWindowMutation(_ request: WindowMutationRequest) {
        windowWriter.async { [weak self] in
            let resolution = Self.performWindowMutation(request)

            DispatchQueue.main.async { [weak self] in
                self?.windowMutationDidFinish(
                    request,
                    resolution: resolution
                )
            }
        }
    }

    private func windowMutationDidFinish(
        _ request: WindowMutationRequest,
        resolution: MutationResolution
    ) {
        mutationDidFinish(request.purpose, resolution: resolution)

        if let nextRequest = windowWrites.completeCurrentRequest() {
            startWindowMutation(nextRequest)
        }
    }

    private func mutationDidFinish(
        _ purpose: MutationPurpose,
        resolution: MutationResolution
    ) {
        switch purpose {
        case let .frame(animationIdentifier):
            if resolution == .fail,
               activeAnimation?.identifier == animationIdentifier {
                stopAnimation(.positionWriteFailed)
            }
        case let .animationCompletion(animationIdentifier):
            if activeAnimation?.identifier == animationIdentifier {
                stopAnimation(
                    resolution == .proceed
                        ? .completed
                        : .finalPlacementFailed
                )
            }
        case .placement:
            break
        }
    }

    private func focusedWindow() -> WindowSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let mutationBackend = WindowMutationBackend.forProcess(
            target: application.processIdentifier,
            current: ProcessInfo.processInfo.processIdentifier
        )

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

        let mutationTarget: WindowMutationTarget
        switch mutationBackend {
        case .appKit:
            guard let keyWindow = NSApp.keyWindow, keyWindow.isVisible else {
                return nil
            }
            mutationTarget = .appKit(keyWindow)
        case .accessibility:
            mutationTarget = .accessibility(window)
        }

        return WindowSnapshot(
            element: window,
            mutationTarget: mutationTarget,
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

    private func screenSnapshots() -> [ScreenSnapshot] {
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height

        return NSScreen.screens.map { screen in
            ScreenSnapshot(
                screen: screen,
                geometry: DisplayGeometry(
                    frame: verticallyFlippedRect(
                        screen.frame,
                        primaryDisplayHeight: primaryDisplayHeight
                    ),
                    visibleFrame: verticallyFlippedRect(
                        screen.visibleFrame,
                        primaryDisplayHeight: primaryDisplayHeight
                    )
                )
            )
        }
    }

    private func appKitFrame(from accessibilityFrame: CGRect) -> CGRect {
        verticallyFlippedRect(
            accessibilityFrame,
            primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
    }

    private func verticallyFlippedRect(
        _ rect: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
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
    ) -> MutationResolution {
        let messagingTimeout = switch request.purpose {
        case .frame:
            frameMessagingTimeout
        case .animationCompletion, .placement:
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
                return .fail
            }
        }

        return .proceed
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

    private func easeInOutCubic(_ progress: CGFloat) -> CGFloat {
        if progress < 0.5 {
            return 4 * progress * progress * progress
        }

        let inverse = -2 * progress + 2
        return 1 - inverse * inverse * inverse / 2
    }
}
