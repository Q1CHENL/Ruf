import XCTest
@testable import RufCore

final class WindowMovementPlannerTests: XCTestCase {
    private let planner = WindowMovementPlanner()

    func testSelectsTheSpatialNeighborInTheRequestedDirection() throws {
        let primary = display(x: 0, y: 0, width: 1_920, height: 1_080)
        let builtIn = display(x: 408, y: 1_080, width: 1_512, height: 982)
        let portrait = display(x: 1_920, y: 0, width: 1_080, height: 1_920)
        let displays = [primary, builtIn, portrait]
        let window = CGRect(x: 600, y: 240, width: 800, height: 600)

        XCTAssertEqual(
            try XCTUnwrap(
                planner.plan(
                    windowFrame: window,
                    displays: displays,
                    direction: .right
                )
            ).destinationDisplay,
            portrait
        )
        XCTAssertEqual(
            try XCTUnwrap(
                planner.plan(
                    windowFrame: window,
                    displays: displays,
                    direction: .down
                )
            ).destinationDisplay,
            builtIn
        )
        XCTAssertNil(
            planner.plan(
                windowFrame: window,
                displays: displays,
                direction: .left
            )
        )
        XCTAssertNil(
            planner.plan(
                windowFrame: window,
                displays: displays,
                direction: .up
            )
        )
    }

    func testUsesTheNearestAlignedDisplayFromASecondaryScreen() throws {
        let primary = display(x: 0, y: 0, width: 1_920, height: 1_080)
        let builtIn = display(x: 408, y: 1_080, width: 1_512, height: 982)
        let portrait = display(x: 1_920, y: 0, width: 1_080, height: 1_920)
        let displays = [primary, builtIn, portrait]
        let window = CGRect(x: 700, y: 1_240, width: 900, height: 700)

        XCTAssertEqual(
            try XCTUnwrap(
                planner.plan(
                    windowFrame: window,
                    displays: displays,
                    direction: .up
                )
            ).destinationDisplay,
            primary
        )
        XCTAssertEqual(
            try XCTUnwrap(
                planner.plan(
                    windowFrame: window,
                    displays: displays,
                    direction: .right
                )
            ).destinationDisplay,
            portrait
        )
    }

    func testOffsetSideBySideDisplaysAreNeighborsOnlyHorizontally() {
        let left = display(x: 0, y: 0, width: 1_000, height: 800)
        let right = display(x: 1_000, y: 300, width: 1_000, height: 800)
        let displays = [left, right]

        XCTAssertEqual(destination(from: left, .right, displays), right)
        XCTAssertNil(destination(from: left, .down, displays))
        XCTAssertNil(destination(from: left, .up, displays))
        XCTAssertEqual(destination(from: right, .left, displays), left)
        XCTAssertNil(destination(from: right, .up, displays))
        XCTAssertNil(destination(from: right, .down, displays))
    }

    func testOffsetStackedDisplaysAreNeighborsOnlyVertically() {
        let top = display(x: 0, y: 0, width: 1_000, height: 800)
        let bottom = display(x: 300, y: 800, width: 1_000, height: 800)
        let displays = [top, bottom]

        XCTAssertEqual(destination(from: top, .down, displays), bottom)
        XCTAssertNil(destination(from: top, .right, displays))
        XCTAssertNil(destination(from: top, .left, displays))
        XCTAssertEqual(destination(from: bottom, .up, displays), top)
        XCTAssertNil(destination(from: bottom, .left, displays))
        XCTAssertNil(destination(from: bottom, .right, displays))
    }

    func testBuiltInDisplayStraddlingBelowTwoExternalDisplays() {
        let external = display(x: 0, y: 0, width: 2_560, height: 1_440)
        let builtIn = display(x: 2_135, y: 1_440, width: 1_512, height: 982)
        let sideExternal = display(x: 2_560, y: 360, width: 1_920, height: 1_080)
        let displays = [external, builtIn, sideExternal]

        XCTAssertEqual(destination(from: external, .right, displays), sideExternal)
        XCTAssertEqual(destination(from: external, .down, displays), builtIn)
        XCTAssertNil(destination(from: external, .left, displays))
        XCTAssertNil(destination(from: external, .up, displays))

        XCTAssertEqual(destination(from: sideExternal, .left, displays), external)
        XCTAssertEqual(destination(from: sideExternal, .down, displays), builtIn)
        XCTAssertNil(destination(from: sideExternal, .up, displays))
        XCTAssertNil(destination(from: sideExternal, .right, displays))

        XCTAssertEqual(destination(from: builtIn, .up, displays), sideExternal)
        XCTAssertNil(destination(from: builtIn, .left, displays))
        XCTAssertNil(destination(from: builtIn, .right, displays))
        XCTAssertNil(destination(from: builtIn, .down, displays))
    }

    func testPrefersASharedEdgeOverADisplayTouchingOnlyAtACorner() {
        let source = display(x: 1_000, y: 0, width: 1_000, height: 1_000)
        let sharedEdge = display(x: 0, y: 990, width: 1_000, height: 1_000)
        let cornerOnly = display(x: 800, y: -200, width: 200, height: 200)
        let displays = [source, sharedEdge, cornerOnly]

        XCTAssertEqual(destination(from: source, .left, displays), sharedEdge)
        XCTAssertEqual(destination(from: source, .up, displays), cornerOnly)
    }

    func testPreservesSizeAndRelativePlacementWithinVisibleFrames() throws {
        let source = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 50, y: 30, width: 950, height: 770)
        )
        let destination = DisplayGeometry(
            frame: CGRect(x: 1_000, y: 0, width: 500, height: 400),
            visibleFrame: CGRect(x: 1_000, y: 20, width: 500, height: 380)
        )
        let window = CGRect(x: 425, y: 365, width: 200, height: 100)

        let plan = try XCTUnwrap(
            planner.plan(
                windowFrame: window,
                displays: [source, destination],
                direction: .right
            )
        )

        XCTAssertEqual(
            plan.destinationFrame,
            CGRect(x: 1_150, y: 160, width: 200, height: 100)
        )
    }

    func testShrinksOnlyOversizedDimensionsToFitTheVisibleFrame() throws {
        let source = display(x: 0, y: 0, width: 1_000, height: 800)
        let destination = display(x: 1_000, y: 0, width: 500, height: 400)
        let window = CGRect(x: 100, y: 300, width: 700, height: 200)

        let plan = try XCTUnwrap(
            planner.plan(
                windowFrame: window,
                displays: [source, destination],
                direction: .right
            )
        )

        XCTAssertEqual(
            plan.destinationFrame,
            CGRect(x: 1_000, y: 100, width: 500, height: 200)
        )
    }

    func testPreservesFullSpanLayoutAcrossDifferentVisibleFrames() throws {
        let source = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 50, y: 30, width: 950, height: 770)
        )
        let destination = DisplayGeometry(
            frame: CGRect(x: 1_000, y: 0, width: 500, height: 400),
            visibleFrame: CGRect(x: 1_000, y: 20, width: 500, height: 380)
        )

        let plan = try XCTUnwrap(
            planner.plan(
                windowFrame: source.visibleFrame,
                displays: [source, destination],
                direction: .right
            )
        )

        XCTAssertEqual(plan.destinationFrame, destination.visibleFrame)
    }

    func testRestoresFullWidthLayoutOnALargerDisplay() throws {
        let source = display(x: 0, y: 0, width: 500, height: 400)
        let destination = display(x: 500, y: 0, width: 1_000, height: 800)
        let window = CGRect(x: 0, y: 100, width: 500, height: 200)

        let plan = try XCTUnwrap(
            planner.plan(
                windowFrame: window,
                displays: [source, destination],
                direction: .right
            )
        )

        XCTAssertEqual(
            plan.destinationFrame,
            CGRect(x: 500, y: 300, width: 1_000, height: 200)
        )
    }

    func testPreferredSourceSupportsRetargetingAnAnimationInFlight() throws {
        let left = display(x: 0, y: 0, width: 1_000, height: 800)
        let middle = display(x: 1_000, y: 0, width: 1_000, height: 800)
        let right = display(x: 2_000, y: 0, width: 1_000, height: 800)
        let futureMiddleFrame = CGRect(
            x: 1_600,
            y: 100,
            width: 1_400,
            height: 500
        )

        XCTAssertNil(
            planner.plan(
                windowFrame: futureMiddleFrame,
                displays: [left, middle, right],
                direction: .right
            )
        )

        let plan = try XCTUnwrap(
            planner.plan(
                windowFrame: futureMiddleFrame,
                displays: [left, middle, right],
                direction: .right,
                preferredSourceDisplay: middle
            )
        )

        XCTAssertEqual(plan.destinationDisplay, right)
        XCTAssertEqual(
            plan.destinationFrame,
            CGRect(x: 2_000, y: 100, width: 1_000, height: 500)
        )
    }

    func testSourceDisplayShowsMostOfAStraddlingWindow() {
        let left = display(x: 0, y: 0, width: 1_000, height: 800)
        let right = display(x: 1_000, y: 0, width: 1_600, height: 1_000)

        XCTAssertEqual(
            planner.sourceDisplay(
                for: CGRect(x: 900, y: 100, width: 400, height: 300),
                displays: [left, right]
            ),
            right
        )
    }

    func testSourceDisplayIsTheNearestDisplayForAnOffscreenWindow() {
        let left = display(x: 0, y: 0, width: 1_000, height: 800)
        let right = display(x: 1_000, y: 0, width: 1_600, height: 1_000)

        XCTAssertEqual(
            planner.sourceDisplay(
                for: CGRect(x: -500, y: 200, width: 300, height: 300),
                displays: [right, left]
            ),
            left
        )
    }

    func testExposesResizeWhenTheDestinationSizeChanges() {
        let start = CGRect(x: 0, y: 100, width: 1_000, height: 800)
        let destination = CGRect(x: 1_000, y: 300, width: 500, height: 400)
        let mutations = WindowMovementMutationPlan(
            from: start,
            to: destination
        )

        XCTAssertEqual(mutations.destinationPosition, destination.origin)
        XCTAssertTrue(mutations.requiresResize)
        XCTAssertEqual(
            mutations.finalPlacementMutations,
            [
                .position(destination.origin),
                .size(destination.size),
                .position(destination.origin),
            ]
        )
    }

    func testOmitsResizeWhenTheWindowAlreadyFits() {
        let mutations = WindowMovementMutationPlan(
            from: CGRect(x: 0, y: 100, width: 500, height: 400),
            to: CGRect(x: 1_000, y: 300, width: 500, height: 400)
        )

        XCTAssertFalse(mutations.requiresResize)
        XCTAssertEqual(
            mutations.finalPlacementMutations,
            [.position(CGPoint(x: 1_000, y: 300))]
        )
    }

    func testMutationPolicyAcceptsIndeterminateAXWritesWithoutRetrying() {
        XCTAssertTrue(WindowMutationPolicy.accepts(.succeeded))
        XCTAssertTrue(WindowMutationPolicy.accepts(.indeterminate))
        XCTAssertFalse(WindowMutationPolicy.accepts(.failed))
    }

    func testAnimationStopPolicySettlesOnlyAbandonedReachableDestinations() {
        XCTAssertTrue(
            WindowMovementAnimationStopReason.focusedWindowChanged
                .settlesAtDestination
        )
        XCTAssertTrue(
            WindowMovementAnimationStopReason.positionWriteFailed
                .settlesAtDestination
        )
        XCTAssertTrue(
            WindowMovementAnimationStopReason.shutdown
                .settlesAtDestination
        )

        XCTAssertFalse(
            WindowMovementAnimationStopReason.retargeted
                .settlesAtDestination
        )
        XCTAssertFalse(
            WindowMovementAnimationStopReason.displayConfigurationChanged
                .settlesAtDestination
        )
        XCTAssertFalse(
            WindowMovementAnimationStopReason.completed
                .settlesAtDestination
        )
        XCTAssertFalse(
            WindowMovementAnimationStopReason.finalPlacementFailed
                .settlesAtDestination
        )
    }

    func testAnimationRequestPolicyPrioritizesDisplayConfigurationChanges() {
        XCTAssertEqual(
            WindowMovementAnimationStopReason.beforeMove(
                destinationExists: false,
                focusedWindowMatches: false
            ),
            .displayConfigurationChanged
        )
        XCTAssertEqual(
            WindowMovementAnimationStopReason.beforeMove(
                destinationExists: true,
                focusedWindowMatches: false
            ),
            .focusedWindowChanged
        )
        XCTAssertNil(
            WindowMovementAnimationStopReason.beforeMove(
                destinationExists: true,
                focusedWindowMatches: true
            )
        )
    }

    private func destination(
        from source: DisplayGeometry,
        _ direction: WindowMoveDirection,
        _ displays: [DisplayGeometry]
    ) -> DisplayGeometry? {
        planner.plan(
            windowFrame: CGRect(
                x: source.visibleFrame.midX - 100,
                y: source.visibleFrame.midY - 100,
                width: 200,
                height: 200
            ),
            displays: displays,
            direction: direction
        )?.destinationDisplay
    }

    private func display(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> DisplayGeometry {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return DisplayGeometry(frame: frame, visibleFrame: frame)
    }
}
