import XCTest
@testable import RufCore

final class SwitcherLoadingSessionTests: XCTestCase {
    func testQueuesActionsWhileLoadingAndReturnsAReplayPlanOnCompletion() {
        var session = SwitcherLoadingSession()
        session.beginLoading()

        XCTAssertEqual(
            session.receive(.cycle(backwards: false)),
            .queued
        )
        XCTAssertEqual(session.receive(.move(.right)), .queued)
        XCTAssertEqual(session.receive(.openNewWindow), .queued)

        XCTAssertEqual(
            session.finishLoading(),
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
        session.beginLoading()
        _ = session.receive(.move(.left))

        XCTAssertEqual(session.receive(.cancel), .cancelLoading)
        XCTAssertFalse(session.isLoading)

        session.beginLoading()
        XCTAssertEqual(
            session.finishLoading(),
            SwitcherActionReplayPlan(pendingActions: [])
        )
    }

    func testHandlesActionsImmediatelyWhenNoLoadIsActive() {
        var session = SwitcherLoadingSession()

        XCTAssertEqual(
            session.receive(.cycle(backwards: true)),
            .handleImmediately
        )
        XCTAssertEqual(session.receive(.cancel), .handleImmediately)
    }
}
