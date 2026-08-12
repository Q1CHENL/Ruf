import CoreGraphics

public enum WindowMoveDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum WindowMovementAnimationStopReason: Equatable, Sendable {
    case completed
    case retargeted
    case displayConfigurationChanged
    case focusedWindowChanged
    case positionWriteFailed
    case finalPlacementFailed
    case shutdown

    public var settlesAtDestination: Bool {
        switch self {
        case .focusedWindowChanged, .positionWriteFailed, .shutdown:
            true
        case .completed, .retargeted, .displayConfigurationChanged,
             .finalPlacementFailed:
            false
        }
    }

    public static func beforeMove(
        destinationExists: Bool,
        focusedWindowMatches: Bool
    ) -> Self? {
        if !destinationExists {
            return .displayConfigurationChanged
        }
        if !focusedWindowMatches {
            return .focusedWindowChanged
        }
        return nil
    }
}

public enum WindowMutationOutcome: Equatable, Sendable {
    case succeeded
    case indeterminate
    case failed
}

public enum WindowMutationPolicy {
    public static func accepts(_ outcome: WindowMutationOutcome) -> Bool {
        switch outcome {
        case .succeeded, .indeterminate:
            true
        case .failed:
            false
        }
    }
}

public struct DisplayGeometry: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public struct WindowMovementProjectionToken: Equatable, Sendable {
    public let identifier: UInt64
    public let revision: UInt64

    init(identifier: UInt64, revision: UInt64) {
        self.identifier = identifier
        self.revision = revision
    }
}

public struct WindowMovementProjection: Equatable, Sendable {
    public let token: WindowMovementProjectionToken
    public let destinationFrame: CGRect
    public let destinationDisplay: DisplayGeometry

    init(
        token: WindowMovementProjectionToken,
        destinationFrame: CGRect,
        destinationDisplay: DisplayGeometry
    ) {
        self.token = token
        self.destinationFrame = destinationFrame
        self.destinationDisplay = destinationDisplay
    }
}

public enum WindowMovementProjectionResolution: Equatable, Sendable {
    case unchanged
    case cleared
    case failed
}

public struct WindowMovementProjectionState: Equatable, Sendable {
    public private(set) var current: WindowMovementProjection?
    private var nextIdentifier: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func project(
        destinationFrame: CGRect,
        destinationDisplay: DisplayGeometry
    ) -> WindowMovementProjection {
        let token: WindowMovementProjectionToken
        if let current {
            token = WindowMovementProjectionToken(
                identifier: current.token.identifier,
                revision: current.token.revision + 1
            )
        } else {
            nextIdentifier += 1
            token = WindowMovementProjectionToken(
                identifier: nextIdentifier,
                revision: 1
            )
        }

        let projection = WindowMovementProjection(
            token: token,
            destinationFrame: destinationFrame,
            destinationDisplay: destinationDisplay
        )
        current = projection
        return projection
    }

    @discardableResult
    public mutating func finish(
        _ token: WindowMovementProjectionToken,
        succeeded: Bool
    ) -> WindowMovementProjectionResolution {
        guard succeeded else {
            if current?.token.identifier == token.identifier {
                current = nil
            }
            return .failed
        }

        guard current?.token == token else {
            return .unchanged
        }
        current = nil
        return .cleared
    }

    @discardableResult
    public mutating func invalidate() -> UInt64? {
        let identifier = current?.token.identifier
        current = nil
        return identifier
    }
}

public struct WindowMovementPlan: Sendable {
    public let destinationDisplay: DisplayGeometry
    public let destinationFrame: CGRect

    init(
        destinationDisplay: DisplayGeometry,
        destinationFrame: CGRect
    ) {
        self.destinationDisplay = destinationDisplay
        self.destinationFrame = destinationFrame
    }
}

public enum WindowFrameMutation: Equatable, Sendable {
    case position(CGPoint)
    case size(CGSize)
}

public struct WindowMovementMutationPlan: Sendable {
    public let destinationFrame: CGRect
    private let sourceSize: CGSize

    public init(from startFrame: CGRect, to destinationFrame: CGRect) {
        sourceSize = startFrame.size
        self.destinationFrame = destinationFrame
    }

    public var destinationPosition: CGPoint {
        destinationFrame.origin
    }

    public var requiresResize: Bool {
        sourceSize != destinationFrame.size
    }

    public var finalPlacementMutations: [WindowFrameMutation] {
        guard requiresResize else {
            return [.position(destinationPosition)]
        }

        return [
            .position(destinationPosition),
            .size(destinationFrame.size),
            .position(destinationPosition),
        ]
    }
}

public struct WindowMovementPlanner: Sendable {
    private static let fullSpanTolerance: CGFloat = 2

    public init() {}

    public func plan(
        windowFrame: CGRect,
        displays: [DisplayGeometry],
        direction: WindowMoveDirection,
        preferredSourceDisplay: DisplayGeometry? = nil
    ) -> WindowMovementPlan? {
        let displays = displays.filter { display in
            display.frame.width > 0
                && display.frame.height > 0
                && display.visibleFrame.width > 0
                && display.visibleFrame.height > 0
        }
        guard displays.count > 1 else {
            return nil
        }

        let sourceDisplay = preferredSourceDisplay.flatMap { preferred in
            displays.first { $0 == preferred }
        } ?? sourceDisplay(for: windowFrame, displays: displays)
        guard let sourceDisplay else {
            return nil
        }

        let candidates = displays.filter {
            $0 != sourceDisplay
                && isInDirection($0, from: sourceDisplay, direction: direction)
        }
        guard let destinationDisplay = candidates.min(by: { candidate, current in
            isBetterDestination(
                candidate,
                than: current,
                from: sourceDisplay,
                direction: direction
            )
        }) else {
            return nil
        }

        let sourceVisibleFrame = sourceDisplay.visibleFrame
        let destinationVisibleFrame = destinationDisplay.visibleFrame
        let sourceHorizontalRange = sourceVisibleFrame.minX...sourceVisibleFrame.maxX
        let destinationHorizontalRange = destinationVisibleFrame.minX...destinationVisibleFrame.maxX
        let sourceVerticalRange = sourceVisibleFrame.minY...sourceVisibleFrame.maxY
        let destinationVerticalRange = destinationVisibleFrame.minY...destinationVisibleFrame.maxY
        let destinationSize = CGSize(
            width: mappedLength(
                windowRange: windowFrame.minX...windowFrame.maxX,
                sourceRange: sourceHorizontalRange,
                destinationRange: destinationHorizontalRange
            ),
            height: mappedLength(
                windowRange: windowFrame.minY...windowFrame.maxY,
                sourceRange: sourceVerticalRange,
                destinationRange: destinationVerticalRange
            )
        )

        let destinationOrigin = CGPoint(
            x: mappedOrigin(
                windowOrigin: windowFrame.minX,
                sourceWindowLength: windowFrame.width,
                destinationWindowLength: destinationSize.width,
                sourceRange: sourceHorizontalRange,
                destinationRange: destinationHorizontalRange
            ),
            y: mappedOrigin(
                windowOrigin: windowFrame.minY,
                sourceWindowLength: windowFrame.height,
                destinationWindowLength: destinationSize.height,
                sourceRange: sourceVerticalRange,
                destinationRange: destinationVerticalRange
            )
        )

        return WindowMovementPlan(
            destinationDisplay: destinationDisplay,
            destinationFrame: CGRect(
                origin: destinationOrigin,
                size: destinationSize
            )
        )
    }

    private func sourceDisplay(
        for windowFrame: CGRect,
        displays: [DisplayGeometry]
    ) -> DisplayGeometry? {
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        return displays.reduce(nil) {
            (best: DisplayGeometry?, candidate: DisplayGeometry) in
            guard let best else {
                return candidate
            }

            let candidateIntersection = intersectionArea(
                windowFrame,
                candidate.frame
            )
            let bestIntersection = intersectionArea(windowFrame, best.frame)
            if candidateIntersection != bestIntersection {
                return candidateIntersection > bestIntersection ? candidate : best
            }

            let candidateDistance = squaredDistance(
                from: windowCenter,
                to: candidate.frame
            )
            let bestDistance = squaredDistance(from: windowCenter, to: best.frame)
            if candidateDistance != bestDistance {
                return candidateDistance < bestDistance ? candidate : best
            }

            return geometryOrder(candidate, best) ? candidate : best
        }
    }

    private func isInDirection(
        _ candidate: DisplayGeometry,
        from source: DisplayGeometry,
        direction: WindowMoveDirection
    ) -> Bool {
        switch direction {
        case .left:
            candidate.frame.midX < source.frame.midX
        case .right:
            candidate.frame.midX > source.frame.midX
        case .up:
            candidate.frame.midY < source.frame.midY
        case .down:
            candidate.frame.midY > source.frame.midY
        }
    }

    private func isBetterDestination(
        _ candidate: DisplayGeometry,
        than current: DisplayGeometry,
        from source: DisplayGeometry,
        direction: WindowMoveDirection
    ) -> Bool {
        let candidateScore = destinationScore(
            candidate,
            from: source,
            direction: direction
        )
        let currentScore = destinationScore(
            current,
            from: source,
            direction: direction
        )

        for (candidateValue, currentValue) in zip(candidateScore, currentScore) {
            if candidateValue != currentValue {
                return candidateValue < currentValue
            }
        }

        return geometryOrder(candidate, current)
    }

    private func destinationScore(
        _ candidate: DisplayGeometry,
        from source: DisplayGeometry,
        direction: WindowMoveDirection
    ) -> [CGFloat] {
        switch direction {
        case .left:
            return [
                intervalGap(
                    source.frame.minY...source.frame.maxY,
                    candidate.frame.minY...candidate.frame.maxY
                ),
                max(0, source.frame.minX - candidate.frame.maxX),
                abs(source.frame.midY - candidate.frame.midY),
                source.frame.midX - candidate.frame.midX,
            ]
        case .right:
            return [
                intervalGap(
                    source.frame.minY...source.frame.maxY,
                    candidate.frame.minY...candidate.frame.maxY
                ),
                max(0, candidate.frame.minX - source.frame.maxX),
                abs(source.frame.midY - candidate.frame.midY),
                candidate.frame.midX - source.frame.midX,
            ]
        case .up:
            return [
                intervalGap(
                    source.frame.minX...source.frame.maxX,
                    candidate.frame.minX...candidate.frame.maxX
                ),
                max(0, source.frame.minY - candidate.frame.maxY),
                abs(source.frame.midX - candidate.frame.midX),
                source.frame.midY - candidate.frame.midY,
            ]
        case .down:
            return [
                intervalGap(
                    source.frame.minX...source.frame.maxX,
                    candidate.frame.minX...candidate.frame.maxX
                ),
                max(0, candidate.frame.minY - source.frame.maxY),
                abs(source.frame.midX - candidate.frame.midX),
                candidate.frame.midY - source.frame.midY,
            ]
        }
    }

    private func mappedOrigin(
        windowOrigin: CGFloat,
        sourceWindowLength: CGFloat,
        destinationWindowLength: CGFloat,
        sourceRange: ClosedRange<CGFloat>,
        destinationRange: ClosedRange<CGFloat>
    ) -> CGFloat {
        let sourceTravel = max(0, sourceRange.upperBound
            - sourceRange.lowerBound
            - sourceWindowLength)
        let destinationTravel = max(0, destinationRange.upperBound
            - destinationRange.lowerBound
            - destinationWindowLength)
        guard sourceTravel > 0, destinationTravel > 0 else {
            return destinationRange.lowerBound
        }

        let progress = min(
            1,
            max(0, (windowOrigin - sourceRange.lowerBound) / sourceTravel)
        )
        return destinationRange.lowerBound + progress * destinationTravel
    }

    private func mappedLength(
        windowRange: ClosedRange<CGFloat>,
        sourceRange: ClosedRange<CGFloat>,
        destinationRange: ClosedRange<CGFloat>
    ) -> CGFloat {
        let destinationLength = destinationRange.upperBound
            - destinationRange.lowerBound
        guard !fills(windowRange, sourceRange) else {
            return destinationLength
        }

        let windowLength = windowRange.upperBound - windowRange.lowerBound
        return min(windowLength, destinationLength)
    }

    private func fills(
        _ windowRange: ClosedRange<CGFloat>,
        _ displayRange: ClosedRange<CGFloat>
    ) -> Bool {
        let lowerEdgeMatches = abs(
            windowRange.lowerBound - displayRange.lowerBound
        ) <= Self.fullSpanTolerance
        let upperEdgeMatches = abs(
            windowRange.upperBound - displayRange.upperBound
        ) <= Self.fullSpanTolerance

        return lowerEdgeMatches && upperEdgeMatches
    }

    private func intervalGap(
        _ lhs: ClosedRange<CGFloat>,
        _ rhs: ClosedRange<CGFloat>
    ) -> CGFloat {
        if lhs.upperBound < rhs.lowerBound {
            return rhs.lowerBound - lhs.upperBound
        }
        if rhs.upperBound < lhs.lowerBound {
            return lhs.lowerBound - rhs.upperBound
        }
        return 0
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }

        return max(0, intersection.width) * max(0, intersection.height)
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let horizontalDistance = max(
            0,
            max(rect.minX - point.x, point.x - rect.maxX)
        )
        let verticalDistance = max(
            0,
            max(rect.minY - point.y, point.y - rect.maxY)
        )
        return horizontalDistance * horizontalDistance
            + verticalDistance * verticalDistance
    }

    private func geometryOrder(
        _ lhs: DisplayGeometry,
        _ rhs: DisplayGeometry
    ) -> Bool {
        let lhsValues = [
            lhs.frame.minX,
            lhs.frame.minY,
            lhs.frame.width,
            lhs.frame.height,
        ]
        let rhsValues = [
            rhs.frame.minX,
            rhs.frame.minY,
            rhs.frame.width,
            rhs.frame.height,
        ]

        for (lhsValue, rhsValue) in zip(lhsValues, rhsValues) {
            if lhsValue != rhsValue {
                return lhsValue < rhsValue
            }
        }
        return false
    }
}
