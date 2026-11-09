import CoreGraphics

public enum WindowMovementWritePurpose: Equatable, Sendable {
    /// An intermediate Continuous frame. Only the position changes.
    case frame
    /// The placement that completes the animation.
    case finalPlacement
    /// Places an abandoned animation's window at its destination.
    case settle
}

/// A frame change the session asks its owner to apply to a window.
public struct WindowMovementWrite<Window: Equatable>: Equatable {
    public let window: Window
    public let animationIdentifier: UInt64
    public let purpose: WindowMovementWritePurpose
    /// The frame the window takes.
    public let frame: CGRect
    /// The Accessibility writes that produce `frame`, in order.
    public let mutations: [WindowFrameMutation]
}

public enum WindowMovementEffect<Window: Equatable>: Equatable {
    /// Apply the write and report its result through `writeDidFinish`.
    /// Writes run one at a time in the order they are produced.
    case write(WindowMovementWrite<Window>)
    /// Drop the animation's writes that have not started. A write already in
    /// progress finishes, and its result no longer matters.
    case discardPendingWrites(animationIdentifier: UInt64)
}

/// Movement policy for the focused window: which frame a move plans from,
/// how its animation runs, and when the real window is written.
///
/// Continuous movement writes the real window on every frame. Ghost movement
/// animates `outlineFrame` and writes the real window once at the end. With
/// Reduce Motion, or when there is no distance to animate, the animation has
/// no duration and places the window at once. Either way the animation stays
/// current until its final placement finishes, so a further move plans from
/// where the window is headed and replaces a placement that has not started.
public struct WindowMovementSession<Window: Equatable> {
    public struct Animation: Equatable {
        public let identifier: UInt64
        public let window: Window
        public let style: WindowMovementStyle
        public let startFrame: CGRect
        public let destinationFrame: CGRect
        public let destinationDisplay: DisplayGeometry
        public let finalPlacement: [WindowFrameMutation]
        public let startTime: CFTimeInterval
        public let duration: CFTimeInterval
        public fileprivate(set) var currentFrame: CGRect
        /// Whether the final placement has been requested.
        public fileprivate(set) var isPlacing: Bool

        var outlineFrame: CGRect? {
            style == .outline && duration > 0 ? currentFrame : nil
        }
    }

    public static var animationDuration: CFTimeInterval {
        0.2
    }

    public private(set) var animation: Animation?
    private var nextAnimationIdentifier: UInt64 = 0

    public init() {}

    /// The Ghost preview's frame while it is shown.
    public var outlineFrame: CGRect? {
        animation?.outlineFrame
    }

    /// The display whose refresh paces `advance(to:)` while frames remain to
    /// animate.
    public var animatingDisplay: DisplayGeometry? {
        guard let animation, !animation.isPlacing else {
            return nil
        }
        return animation.destinationDisplay
    }

    /// Moves `window`, observed at `frame`, to the neighbouring display.
    /// `canResize` is consulted only when the move may change the size.
    public mutating func move(
        _ direction: WindowMoveDirection,
        style: WindowMovementStyle,
        reducesMotion: Bool,
        window: Window,
        frame observedFrame: CGRect,
        displays: [DisplayGeometry],
        at time: CFTimeInterval,
        canResize: () -> Bool
    ) -> [WindowMovementEffect<Window>] {
        var effects: [WindowMovementEffect<Window>] = []
        var retargeted: (animation: Animation, source: DisplayGeometry)?
        if let animation {
            if let source = displays.first(where: {
                $0.frame == animation.destinationDisplay.frame
            }) {
                if animation.window == window {
                    retargeted = (animation, source)
                } else {
                    effects += stop(.focusedWindowChanged)
                }
            } else {
                effects += stop(.displayConfigurationChanged)
            }
        }

        guard let plan = WindowMovementPlanner.plan(
            windowFrame: retargeted?.animation.destinationFrame
                ?? observedFrame,
            displays: displays,
            direction: direction,
            preferredSourceDisplay: retargeted?.source
        ) else {
            return effects
        }

        let destinationFrame = plan.destinationFrame
        let mustResize = destinationFrame.size != observedFrame.size
        guard !mustResize || canResize() else {
            return effects
        }
        // While retargeting, an earlier placement of this window may still be
        // resizing it, so the observed size cannot be trusted: write the size
        // whenever the window allows it.
        let resizes = mustResize || retargeted != nil && canResize()

        // Ghost continues from the preview already on screen; otherwise the
        // animation starts where the real window is.
        let startFrame = style == .outline
            ? retargeted?.animation.outlineFrame ?? observedFrame
            : observedFrame
        let hasDistance = switch style {
        case .live:
            startFrame.origin != destinationFrame.origin
        case .outline:
            startFrame != destinationFrame
        }
        let duration = hasDistance && !reducesMotion
            ? Self.animationDuration
            : 0

        if retargeted != nil {
            effects += stop(.retargeted)
        }

        nextAnimationIdentifier += 1
        let animation = Animation(
            identifier: nextAnimationIdentifier,
            window: window,
            style: style,
            startFrame: startFrame,
            destinationFrame: destinationFrame,
            destinationDisplay: plan.destinationDisplay,
            finalPlacement: Self.placementMutations(
                for: destinationFrame,
                resizing: resizes
            ),
            startTime: time,
            duration: duration,
            currentFrame: duration > 0 ? startFrame : destinationFrame,
            isPlacing: duration == 0
        )
        self.animation = animation

        if animation.isPlacing {
            effects.append(.write(finalPlacement(of: animation)))
        }
        return effects
    }

    /// Advances the animation to a display refresh at `time`.
    public mutating func advance(
        to time: CFTimeInterval
    ) -> [WindowMovementEffect<Window>] {
        guard var animation, !animation.isPlacing else {
            return []
        }

        let progress = min(
            1,
            max(0, (time - animation.startTime) / animation.duration)
        )
        animation.currentFrame = Self.interpolatedFrame(
            from: animation.startFrame,
            to: animation.destinationFrame,
            progress: Self.easeInOutCubic(CGFloat(progress)),
            style: animation.style
        )

        if progress >= 1 {
            animation.isPlacing = true
            self.animation = animation
            return [.write(finalPlacement(of: animation))]
        }

        self.animation = animation
        guard animation.style == .live else {
            return []
        }
        return [
            .write(
                WindowMovementWrite(
                    window: animation.window,
                    animationIdentifier: animation.identifier,
                    purpose: .frame,
                    frame: animation.currentFrame,
                    mutations: [.position(animation.currentFrame.origin)]
                )
            ),
        ]
    }

    public mutating func writeDidFinish(
        _ purpose: WindowMovementWritePurpose,
        animationIdentifier: UInt64,
        succeeded: Bool
    ) -> [WindowMovementEffect<Window>] {
        guard animation?.identifier == animationIdentifier else {
            return []
        }

        switch purpose {
        case .frame:
            return succeeded ? [] : stop(.positionWriteFailed)
        case .finalPlacement:
            return stop(succeeded ? .completed : .finalPlacementFailed)
        case .settle:
            return []
        }
    }

    /// Stops the animation when its destination display no longer exists in
    /// `displays`.
    public mutating func displaysDidChange(
        _ displays: [DisplayGeometry]
    ) -> [WindowMovementEffect<Window>] {
        guard let animation,
              !displays.contains(where: {
                  $0.frame == animation.destinationDisplay.frame
              }) else {
            return []
        }
        return stop(.displayConfigurationChanged)
    }

    public mutating func shutDown() -> [WindowMovementEffect<Window>] {
        stop(.shutdown)
    }

    private mutating func stop(
        _ reason: WindowMovementAnimationStopReason
    ) -> [WindowMovementEffect<Window>] {
        guard let stopped = animation else {
            return []
        }
        animation = nil

        var effects: [WindowMovementEffect<Window>] = [
            .discardPendingWrites(animationIdentifier: stopped.identifier),
        ]
        if reason.settlesAtDestination {
            effects.append(
                .write(
                    WindowMovementWrite(
                        window: stopped.window,
                        animationIdentifier: stopped.identifier,
                        purpose: .settle,
                        frame: stopped.destinationFrame,
                        mutations: stopped.finalPlacement
                    )
                )
            )
        }
        return effects
    }

    private func finalPlacement(
        of animation: Animation
    ) -> WindowMovementWrite<Window> {
        WindowMovementWrite(
            window: animation.window,
            animationIdentifier: animation.identifier,
            purpose: .finalPlacement,
            frame: animation.destinationFrame,
            mutations: animation.finalPlacement
        )
    }

    /// A resize is bracketed by moves: the window resizes once it is on the
    /// destination display, then returns to the exact origin in case the
    /// resize shifted it. Keep this order.
    private static func placementMutations(
        for frame: CGRect,
        resizing: Bool
    ) -> [WindowFrameMutation] {
        guard resizing else {
            return [.position(frame.origin)]
        }
        return [
            .position(frame.origin),
            .size(frame.size),
            .position(frame.origin),
        ]
    }

    /// Ghost resizes the preview along the way; Continuous keeps the real
    /// window's size until the final placement.
    private static func interpolatedFrame(
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

    private static func easeInOutCubic(_ progress: CGFloat) -> CGFloat {
        if progress < 0.5 {
            return 4 * progress * progress * progress
        }

        let inverse = -2 * progress + 2
        return 1 - inverse * inverse * inverse / 2
    }
}
