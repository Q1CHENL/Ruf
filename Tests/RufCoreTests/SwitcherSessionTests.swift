import XCTest
@testable import RufCore

final class SwitcherSessionTests: XCTestCase {
    func testBeginSelectsTheFirstTargetOutsideTheCurrentGroup() {
        var session = SwitcherSession()

        session.begin(
            groupIdentifiers: [0, 0, 0, 1, 2, 2],
            currentGroup: 0,
            backwards: false
        )
        XCTAssertTrue(session.isPresented)
        XCTAssertEqual(session.selectedIndex, 3)

        session.begin(
            groupIdentifiers: [0, 0, 0, 1, 2, 2],
            currentGroup: 0,
            backwards: true
        )
        XCTAssertEqual(session.selectedIndex, 5)
    }

    func testBeginFallsBackToCyclingWithinTheOnlyGroup() {
        var session = SwitcherSession()

        session.begin(
            groupIdentifiers: [0, 0, 0],
            currentGroup: 0,
            backwards: false
        )
        XCTAssertEqual(session.selectedIndex, 1)

        session.begin(
            groupIdentifiers: [0, 0, 0],
            currentGroup: 0,
            backwards: true
        )
        XCTAssertEqual(session.selectedIndex, 2)

        session.begin(groupIdentifiers: [0], currentGroup: 0, backwards: false)
        XCTAssertEqual(session.selectedIndex, 0)

        session.begin(
            groupIdentifiers: [Int](),
            currentGroup: 0,
            backwards: false
        )
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)
    }

    func testBeginSkipsATrailingAuxiliaryTargetForInitialSelection() {
        var session = SwitcherSession()
        let groupIdentifiers = [0, 1, 2, 99]

        session.begin(
            groupIdentifiers: groupIdentifiers,
            currentGroup: 0,
            initialSelectionTargetCount: 3,
            backwards: false
        )
        XCTAssertEqual(session.selectedIndex, 1)

        session.begin(
            groupIdentifiers: groupIdentifiers,
            currentGroup: 0,
            initialSelectionTargetCount: 3,
            backwards: true
        )
        XCTAssertEqual(session.selectedIndex, 2)
        XCTAssertEqual(session.itemCount, 4)

        session.move(.last)

        XCTAssertEqual(session.selectedIndex, 3)
    }

    func testBeginStartsAtTheEdgeWhenTheCurrentGroupHasNoTarget() {
        // Ruf itself, or an app without a switchable window, is frontmost.
        let groupIdentifiers = [1, 2, 3, 99]

        for currentGroup in [0, nil] {
            var session = SwitcherSession()

            session.begin(
                groupIdentifiers: groupIdentifiers,
                currentGroup: currentGroup,
                initialSelectionTargetCount: 3,
                backwards: false
            )
            XCTAssertEqual(session.selectedIndex, 0)

            session.begin(
                groupIdentifiers: groupIdentifiers,
                currentGroup: currentGroup,
                initialSelectionTargetCount: 3,
                backwards: true
            )
            XCTAssertEqual(session.selectedIndex, 2)
        }
    }

    func testBeginSkipsTheCurrentGroupWhereverItIsListed() {
        var session = SwitcherSession()

        session.begin(
            groupIdentifiers: [1, 0, 2],
            currentGroup: 0,
            backwards: false
        )
        XCTAssertEqual(session.selectedIndex, 0)

        session.begin(
            groupIdentifiers: [1, 2, 0],
            currentGroup: 0,
            backwards: true
        )
        XCTAssertEqual(session.selectedIndex, 1)
    }

    func testMoveSelectFinishAndCancelMaintainSessionState() {
        var session = SwitcherSession()
        session.begin(
            groupIdentifiers: Array(0..<7),
            currentGroup: 0,
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
            currentGroup: 0,
            backwards: false
        )
        session.cancel()
        XCTAssertFalse(session.isPresented)
        XCTAssertNil(session.selectedIndex)
    }

    func testNavigationUsesTheColumnsThatFitTheRowLimit() {
        var session = SwitcherSession()
        session.begin(
            groupIdentifiers: Array(0..<12),
            currentGroup: 99,
            maximumRowCount: 2,
            backwards: false
        )

        XCTAssertEqual(session.navigation.columnCount, 6)
        XCTAssertEqual(session.selectedIndex, 0)

        session.move(.down)
        XCTAssertEqual(session.selectedIndex, 6)
    }

    func testResourceUsageVisibilityCanSeedTheNextSession() {
        var session = SwitcherSession()

        session.begin(
            groupIdentifiers: [0, 1],
            currentGroup: 0,
            backwards: false,
            showsApplicationResourceUsage: false
        )
        XCTAssertFalse(session.showsApplicationResourceUsage)

        let rememberedVisibility = session.toggleApplicationResourceUsage()
        XCTAssertTrue(rememberedVisibility)
        XCTAssertTrue(session.showsApplicationResourceUsage)

        _ = session.finish()
        XCTAssertFalse(session.showsApplicationResourceUsage)

        session.begin(
            groupIdentifiers: [0, 1],
            currentGroup: 0,
            backwards: false,
            showsApplicationResourceUsage: rememberedVisibility
        )
        XCTAssertTrue(session.showsApplicationResourceUsage)
    }
}
