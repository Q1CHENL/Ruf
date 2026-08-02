import XCTest
@testable import RufCore

final class GridNavigationTests: XCTestCase {
    func testUsesNearSquareGeometry() {
        XCTAssertEqual(GridNavigation(itemCount: 0).columnCount, 0)
        XCTAssertEqual(GridNavigation(itemCount: 1).columnCount, 1)
        XCTAssertEqual(GridNavigation(itemCount: 2).columnCount, 2)
        XCTAssertEqual(GridNavigation(itemCount: 4).columnCount, 2)
        XCTAssertEqual(GridNavigation(itemCount: 5).columnCount, 3)
        XCTAssertEqual(GridNavigation(itemCount: 20).columnCount, 5)

        XCTAssertEqual(GridNavigation(itemCount: 7).rowCount, 3)
    }

    func testForwardAndBackwardWrapAcrossTheWholeGrid() {
        let navigation = GridNavigation(itemCount: 7)

        XCTAssertEqual(navigation.moving(from: 6, .forward), 0)
        XCTAssertEqual(navigation.moving(from: 0, .backward), 6)
        XCTAssertEqual(navigation.moving(from: 3, .forward), 4)
        XCTAssertEqual(navigation.moving(from: 3, .backward), 2)
    }

    func testHorizontalArrowsContinueAcrossRowBoundaries() {
        let navigation = GridNavigation(itemCount: 7)

        XCTAssertEqual(navigation.moving(from: 4, .left), 3)
        XCTAssertEqual(navigation.moving(from: 4, .right), 5)
        XCTAssertEqual(navigation.moving(from: 2, .right), 3)
        XCTAssertEqual(navigation.moving(from: 3, .left), 2)
        XCTAssertEqual(navigation.moving(from: 5, .right), 6)
        XCTAssertEqual(navigation.moving(from: 6, .left), 5)

        XCTAssertEqual(navigation.moving(from: 0, .left), 0)
        XCTAssertEqual(navigation.moving(from: 6, .right), 6)
    }

    func testVerticalArrowsStayWithinTheGrid() {
        let navigation = GridNavigation(itemCount: 7)

        XCTAssertEqual(navigation.moving(from: 4, .up), 1)
        XCTAssertEqual(navigation.moving(from: 0, .up), 0)
        XCTAssertEqual(navigation.moving(from: 6, .down), 6)
    }

    func testVerticalMovementUsesTheNearestItemInACenteredPartialRow() {
        let singleItemLastRow = GridNavigation(itemCount: 7)

        XCTAssertEqual(singleItemLastRow.moving(from: 3, .down), 6)
        XCTAssertEqual(singleItemLastRow.moving(from: 4, .down), 6)
        XCTAssertEqual(singleItemLastRow.moving(from: 5, .down), 6)
        XCTAssertEqual(singleItemLastRow.moving(from: 6, .up), 4)

        let twoItemLastRow = GridNavigation(itemCount: 22)

        XCTAssertEqual(twoItemLastRow.moving(from: 15, .down), 20)
        XCTAssertEqual(twoItemLastRow.moving(from: 17, .down), 20)
        XCTAssertEqual(twoItemLastRow.moving(from: 18, .down), 21)
        XCTAssertEqual(twoItemLastRow.moving(from: 19, .down), 21)
        XCTAssertEqual(twoItemLastRow.moving(from: 20, .up), 16)
        XCTAssertEqual(twoItemLastRow.moving(from: 21, .up), 17)
    }

    func testRejectsIndexesOutsideTheGrid() {
        let navigation = GridNavigation(itemCount: 3)

        XCTAssertNil(navigation.moving(from: -1, .forward))
        XCTAssertNil(navigation.moving(from: 3, .forward))
        XCTAssertNil(GridNavigation(itemCount: 0).moving(from: 0, .forward))
    }
}
