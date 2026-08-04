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

    private struct WindowSnapshot {
        let element: AXUIElement
        let frame: CGRect
    }

    private struct ActiveAnimation {
        let window: AXUIElement
        let startPosition: CGPoint
        let destinationFrame: CGRect
        let destinationDisplayFrame: CGRect
        let startTimestamp: CFTimeInterval
    }

    private static let animationDuration: CFTimeInterval = 0.2
    private static let messagingTimeout: Float = 0.05

    private let planner = WindowMovementPlanner()
    private var activeAnimation: ActiveAnimation?
    private var displayLink: CADisplayLink?

    func move(_ direction: WindowMoveDirection) {
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

        if let activeAnimation {
            let destinationExists = screens.contains {
                $0.geometry.frame == activeAnimation.destinationDisplayFrame
            }
            let focusedWindowMatches = CFEqual(
                activeAnimation.window,
                window.element
            )
            if let reason = WindowMovementAnimationStopReason.beforeMove(
                destinationExists: destinationExists,
                focusedWindowMatches: focusedWindowMatches
            ) {
                stopAnimation(reason)
            }
        }

        let currentAnimation = activeAnimation.flatMap { animation in
            CFEqual(animation.window, window.element) ? animation : nil
        }
        let preferredSource = currentAnimation.flatMap { animation in
            screens.first {
                $0.geometry.frame == animation.destinationDisplayFrame
            }?.geometry
        }
        let planningFrame: CGRect
        if let currentAnimation, preferredSource != nil {
            planningFrame = CGRect(
                origin: currentAnimation.destinationFrame.origin,
                size: window.frame.size
            )
        } else {
            if currentAnimation != nil {
                stopAnimation(.displayConfigurationChanged)
            }
            planningFrame = window.frame
        }

        guard let plan = planner.plan(
            windowFrame: planningFrame,
            displays: screens.map(\.geometry),
            direction: direction,
            preferredSourceDisplay: preferredSource
        ), let destinationScreen = screens.first(where: {
            $0.geometry == plan.destinationDisplay
        }) else {
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAnimation(.retargeted)
            setPosition(plan.destinationFrame.origin, of: window.element)
            return
        }

        startAnimation(
            window: window.element,
            from: window.frame.origin,
            to: plan.destinationFrame,
            on: destinationScreen
        )
    }

    func stop() {
        stopAnimation(.shutdown)
    }

    private func startAnimation(
        window: AXUIElement,
        from startPosition: CGPoint,
        to destinationFrame: CGRect,
        on destinationScreen: ScreenSnapshot
    ) {
        stopAnimation(.retargeted)

        guard startPosition != destinationFrame.origin else {
            setPosition(destinationFrame.origin, of: window)
            return
        }

        activeAnimation = ActiveAnimation(
            window: window,
            startPosition: startPosition,
            destinationFrame: destinationFrame,
            destinationDisplayFrame: destinationScreen.geometry.frame,
            startTimestamp: CACurrentMediaTime()
        )

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

        let progress = min(
            1,
            max(
                0,
                (displayLink.targetTimestamp - animation.startTimestamp)
                    / Self.animationDuration
            )
        )
        let easedProgress = easeInOutCubic(progress)
        let destinationPosition = animation.destinationFrame.origin
        let position = CGPoint(
            x: animation.startPosition.x
                + (destinationPosition.x - animation.startPosition.x)
                    * easedProgress,
            y: animation.startPosition.y
                + (destinationPosition.y - animation.startPosition.y)
                    * easedProgress
        )

        guard setPosition(position, of: animation.window) else {
            stopAnimation(.positionWriteFailed)
            return
        }

        if progress >= 1 {
            stopAnimation(.completed)
        }
    }

    private func stopAnimation(_ reason: WindowMovementAnimationStopReason) {
        let animation = activeAnimation
        displayLink?.invalidate()
        displayLink = nil
        activeAnimation = nil

        if reason.settlesAtDestination, let animation {
            setPosition(
                animation.destinationFrame.origin,
                of: animation.window
            )
        }
    }

    private func focusedWindow() -> WindowSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        AXUIElementSetMessagingTimeout(
            applicationElement,
            Self.messagingTimeout
        )

        guard let rawWindow = attribute(
            kAXFocusedWindowAttribute as CFString,
            of: applicationElement
        ), CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            return nil
        }

        let window = rawWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)

        guard let values = values(
            of: [
                kAXRoleAttribute,
                kAXSubroleAttribute,
                kAXPositionAttribute,
                kAXSizeAttribute,
            ],
            from: window
        ),
              let role = values[0] as? String,
              role == kAXWindowRole,
              let subrole = values[1] as? String,
              subrole == kAXStandardWindowSubrole,
              !isFullScreen(window),
              isPositionSettable(of: window),
              let position = point(from: values[2]),
              let size = size(from: values[3]),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return WindowSnapshot(
            element: window,
            frame: CGRect(origin: position, size: size)
        )
    }

    private func screenSnapshots() -> [ScreenSnapshot] {
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height

        return NSScreen.screens.map { screen in
            ScreenSnapshot(
                screen: screen,
                geometry: DisplayGeometry(
                    frame: accessibilityRect(
                        from: screen.frame,
                        primaryDisplayHeight: primaryDisplayHeight
                    ),
                    visibleFrame: accessibilityRect(
                        from: screen.visibleFrame,
                        primaryDisplayHeight: primaryDisplayHeight
                    )
                )
            )
        }
    }

    private func accessibilityRect(
        from appKitRect: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: appKitRect.minX,
            y: primaryDisplayHeight - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    private func attribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    private func values(
        of attributes: [String],
        from element: AXUIElement
    ) -> [Any]? {
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        ) == .success,
              let rawValues,
              let values = rawValues as? [Any],
              values.count == attributes.count else {
            return nil
        }
        return values
    }

    private func point(from rawValue: Any) -> CGPoint? {
        let rawValue = rawValue as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let value = rawValue as! AXValue
        guard AXValueGetType(value) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func size(from rawValue: Any) -> CGSize? {
        let rawValue = rawValue as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let value = rawValue as! AXValue
        guard AXValueGetType(value) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func isPositionSettable(of window: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            window,
            kAXPositionAttribute as CFString,
            &isSettable
        ) == .success && isSettable.boolValue
    }

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        attribute("AXFullScreen" as CFString, of: window) as? Bool == true
    }

    @discardableResult
    private func setPosition(
        _ position: CGPoint,
        of window: AXUIElement
    ) -> Bool {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else {
            return false
        }

        return AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    private func easeInOutCubic(_ progress: CGFloat) -> CGFloat {
        if progress < 0.5 {
            return 4 * progress * progress * progress
        }

        let inverse = -2 * progress + 2
        return 1 - inverse * inverse * inverse / 2
    }
}
