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
