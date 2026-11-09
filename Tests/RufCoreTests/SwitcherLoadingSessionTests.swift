import XCTest
@testable import RufCore

final class SwitcherLoadingSessionTests: XCTestCase {
    func testQueuesActionsWhileLoadingAndReturnsThemOnCompletion() {
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
            [
                .cycle(backwards: false),
                .move(.right),
                .openNewWindow,
            ]
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
            []
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
            [.commit]
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
            [.commit]
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

    func testDiscardsCommandsFromGesturesTheAppEnded() {
        var session = SwitcherLoadingSession()
        session.endGestures(through: 2)

        XCTAssertEqual(
            session.receive(command(1, .cycle(backwards: false))),
            .discard
        )
        XCTAssertEqual(
            session.receive(command(2, .toggleApplicationResourceUsage)),
            .discard
        )
        XCTAssertEqual(
            session.receive(command(3, .cycle(backwards: false))),
            .handleImmediately
        )
    }

    func testEndedGesturesNeverReopen() {
        var session = SwitcherLoadingSession()
        session.endGestures(through: 3)
        session.endGestures(through: 1)

        XCTAssertEqual(
            session.receive(command(2, .cycle(backwards: false))),
            .discard
        )
    }

    func testEndingGesturesDropsTheirQueuedWorkButKeepsLaterGestures() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)
        _ = session.receive(command(1, .move(.right)))
        _ = session.receive(command(2, .cycle(backwards: false)))
        _ = session.receive(command(2, .commit))
        _ = session.receive(command(3, .cycle(backwards: true)))

        session.endGestures(through: 2)

        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.finishLoading(for: 1))
        XCTAssertEqual(
            session.takeNextGesture(),
            SwitcherGestureActions(
                gestureID: 3,
                actions: [.cycle(backwards: true)]
            )
        )
        XCTAssertNil(session.takeNextGesture())
    }

    func testIgnoresAStaleSnapshotCompletion() {
        var session = SwitcherLoadingSession()
        session.beginLoading(for: 1)

        XCTAssertNil(session.finishLoading(for: 2))
        XCTAssertTrue(session.isLoading)
        XCTAssertEqual(
            session.finishLoading(for: 1),
            []
        )
    }

    private func command(
        _ gestureID: UInt64,
        _ action: SwitcherAction
    ) -> SwitcherCommand {
        SwitcherCommand(gestureID: gestureID, action: action)
    }
}
