import XCTest
@testable import RufCore

final class SwitcherSessionTests: XCTestCase {
    func testBeginSelectsTheFirstTargetOutsideTheCurrentGroup() {
        var session = SwitcherSession()

        session.begin(
            groupIdentifiers: [0, 0, 0, 1, 2, 2],
            backwards: false
        )
        XCTAssertTrue(session.isPresented)
        XCTAssertEqual(session.selectedIndex, 3)

        session.begin(
            groupIdentifiers: [0, 0, 0, 1, 2, 2],
            backwards: true
        )
        XCTAssertEqual(session.selectedIndex, 5)
    }

    func testBeginFallsBackToCyclingWithinTheOnlyGroup() {
        var session = SwitcherSession()

        session.begin(groupIdentifiers: [0, 0, 0], backwards: false)
        XCTAssertEqual(session.selectedIndex, 1)

        session.begin(groupIdentifiers: [0, 0, 0], backwards: true)
        XCTAssertEqual(session.selectedIndex, 2)

        session.begin(groupIdentifiers: [0], backwards: false)
        XCTAssertEqual(session.selectedIndex, 0)

        session.begin(groupIdentifiers: [Int](), backwards: false)
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)
    }

    func testMoveSelectFinishAndCancelMaintainSessionState() {
        var session = SwitcherSession()
        session.begin(
            groupIdentifiers: Array(0..<7),
            backwards: false
        )

        session.move(.right)
        XCTAssertEqual(session.selectedIndex, 2)

        session.select(6)
        XCTAssertEqual(session.finish(), 6)
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)

        session.begin(
            groupIdentifiers: Array(0..<3),
            backwards: false
        )
        session.cancel()
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)
    }
}
