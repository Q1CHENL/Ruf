import XCTest
@testable import RufCore

final class SwitcherSessionTests: XCTestCase {
    func testBeginChoosesTheNextItemInTheRequestedDirection() {
        var session = SwitcherSession()

        session.begin(itemCount: 4, backwards: false)
        XCTAssertTrue(session.isPresented)
        XCTAssertEqual(session.selectedIndex, 1)

        session.begin(itemCount: 4, backwards: true)
        XCTAssertEqual(session.selectedIndex, 3)

        session.begin(itemCount: 1, backwards: false)
        XCTAssertEqual(session.selectedIndex, 0)

        session.begin(itemCount: 0, backwards: false)
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)
    }

    func testMoveSelectFinishAndCancelMaintainSessionState() {
        var session = SwitcherSession()
        session.begin(itemCount: 7, backwards: false)

        session.move(.right)
        XCTAssertEqual(session.selectedIndex, 2)

        session.select(6)
        XCTAssertEqual(session.finish(), 6)
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)

        session.begin(itemCount: 3, backwards: false)
        session.cancel()
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)
    }
}
