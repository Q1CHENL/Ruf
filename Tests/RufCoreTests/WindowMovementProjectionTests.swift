import XCTest
@testable import RufCore

final class WindowMovementProjectionTests: XCTestCase {
    private let planner = WindowMovementPlanner()

    func testRapidMovesPlanFromTheQueuedDestinationUntilItsWriteCompletes() throws {
        let left = display(x: 0)
        let middle = display(x: 1_000)
        let right = display(x: 2_000)
        let displays = [left, middle, right]
        var projections = WindowMovementProjectionState()

        let first = projections.project(
            destinationFrame: CGRect(x: 1_100, y: 100, width: 500, height: 400),
            destinationDisplay: middle
        )
        let queuedSource = try XCTUnwrap(projections.current)
        let secondPlan = try XCTUnwrap(
            planner.plan(
                windowFrame: queuedSource.destinationFrame,
                displays: displays,
                direction: .right,
                preferredSourceDisplay: queuedSource.destinationDisplay
            )
        )

        XCTAssertEqual(secondPlan.destinationDisplay, right)
        XCTAssertEqual(
            secondPlan.destinationFrame,
            CGRect(x: 2_100, y: 100, width: 500, height: 400)
        )

        let second = projections.project(
            destinationFrame: secondPlan.destinationFrame,
            destinationDisplay: secondPlan.destinationDisplay
        )
        XCTAssertEqual(first.token.identifier, second.token.identifier)
        XCTAssertNotEqual(first.token, second.token)

        XCTAssertEqual(
            projections.finish(first.token, succeeded: true),
            .unchanged
        )
        XCTAssertEqual(projections.current, second)
        XCTAssertEqual(
            projections.finish(second.token, succeeded: true),
            .cleared
        )
        XCTAssertNil(projections.current)
    }

    func testFailedWriteInvalidatesTheWholeQueuedProjection() {
        let middle = display(x: 1_000)
        let right = display(x: 2_000)
        var projections = WindowMovementProjectionState()

        let first = projections.project(
            destinationFrame: middle.frame,
            destinationDisplay: middle
        )
        _ = projections.project(
            destinationFrame: right.frame,
            destinationDisplay: right
        )

        XCTAssertEqual(
            projections.finish(first.token, succeeded: false),
            .failed(identifier: first.token.identifier)
        )
        XCTAssertNil(projections.current)
    }

    func testInvalidatingForAWindowOrDisplayChangeStartsANewProjection() {
        let middle = display(x: 1_000)
        var projections = WindowMovementProjectionState()
        let first = projections.project(
            destinationFrame: middle.frame,
            destinationDisplay: middle
        )

        XCTAssertEqual(projections.invalidate(), first.token.identifier)
        XCTAssertNil(projections.current)

        let replacement = projections.project(
            destinationFrame: middle.frame,
            destinationDisplay: middle
        )
        XCTAssertNotEqual(first.token.identifier, replacement.token.identifier)

        XCTAssertEqual(
            projections.finish(first.token, succeeded: false),
            .failed(identifier: first.token.identifier)
        )
        XCTAssertEqual(projections.current, replacement)
    }

    private func display(x: CGFloat) -> DisplayGeometry {
        let frame = CGRect(x: x, y: 0, width: 1_000, height: 800)
        return DisplayGeometry(frame: frame, visibleFrame: frame)
    }
}
