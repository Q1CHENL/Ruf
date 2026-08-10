import XCTest
@testable import RufCore

final class SwitcherLoadingSessionTests: XCTestCase {
    func testQueuesActionsWhileLoadingAndReturnsAReplayPlanOnCompletion() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)

        XCTAssertEqual(
            session.receive(command(1, .cycle(backwards: false))),
            .queued
        )
        XCTAssertEqual(session.receive(command(1, .move(.right))), .queued)
        XCTAssertEqual(session.receive(command(1, .openNewWindow)), .queued)

        XCTAssertEqual(
            session.finishLoading(for: 1),
            SwitcherActionReplayPlan(
                pendingActions: [
                    .cycle(backwards: false),
                    .move(.right),
                    .openNewWindow,
                ]
            )
        )
        XCTAssertFalse(session.isLoading)
    }

    func testCancelDuringLoadingClearsQueuedActions() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)
        _ = session.receive(command(1, .move(.left)))

        XCTAssertEqual(session.receive(command(1, .cancel)), .cancelLoading)
        XCTAssertFalse(session.isLoading)

        session.beginLoading(for: 1)
        XCTAssertEqual(
            session.finishLoading(for: 1),
            SwitcherActionReplayPlan(pendingActions: [])
        )
    }

    func testHandlesActionsImmediatelyWhenNoLoadIsActive() {
        var session = SwitcherLoadingSession()

        XCTAssertEqual(
            session.receive(command(1, .cycle(backwards: true))),
            .handleImmediately
        )
        XCTAssertEqual(
            session.receive(command(1, .cancel)),
            .handleImmediately
        )
    }

    func testFinishesOneGestureBeforeStartingALaterGesture() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)

        XCTAssertEqual(session.receive(command(1, .commit)), .queued)
        XCTAssertEqual(
            session.receive(command(2, .cycle(backwards: false))),
            .queued
        )
        XCTAssertEqual(session.receive(command(2, .commit)), .queued)

        XCTAssertEqual(
            session.finishLoading(for: 1),
            SwitcherActionReplayPlan(pendingActions: [.commit])
        )
        XCTAssertEqual(
            session.takeNextGesture(),
            SwitcherGestureActions(
                gestureID: 2,
                actions: [.cycle(backwards: false), .commit]
            )
        )
        XCTAssertNil(session.takeNextGesture())
    }

    func testDeferredCancelOnlyDiscardsItsOwnGesture() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)
        _ = session.receive(command(1, .commit))
        _ = session.receive(command(2, .cycle(backwards: false)))

        XCTAssertEqual(session.receive(command(2, .cancel)), .queued)
        XCTAssertTrue(session.isLoading)
        XCTAssertEqual(
            session.finishLoading(for: 1),
            SwitcherActionReplayPlan(pendingActions: [.commit])
        )
        XCTAssertNil(session.takeNextGesture())
    }

    func testActiveCancelPreservesALaterGesture() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)
        _ = session.receive(command(2, .cycle(backwards: true)))

        XCTAssertEqual(session.receive(command(1, .cancel)), .cancelLoading)
        XCTAssertFalse(session.isLoading)
        XCTAssertEqual(
            session.takeNextGesture(),
            SwitcherGestureActions(
                gestureID: 2,
                actions: [.cycle(backwards: true)]
            )
        )
    }

    func testIgnoresAStaleSnapshotCompletion() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)

        XCTAssertNil(session.finishLoading(for: 2))
        XCTAssertTrue(session.isLoading)
        XCTAssertEqual(
            session.finishLoading(for: 1),
            SwitcherActionReplayPlan(pendingActions: [])
        )
    }

    private func command(
        _ gestureID: UInt64,
        _ action: SwitcherAction
    ) -> SwitcherCommand {
        SwitcherCommand(gestureID: gestureID, action: action)
    }
}
