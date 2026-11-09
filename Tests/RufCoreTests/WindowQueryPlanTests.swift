import XCTest
@testable import RufCore

final class WindowQueryPlanTests: XCTestCase {
    func testWindowOwnershipDoesNotImplyVisibility() {
        let plan = WindowQueryPlan(
            visibleWindowIdentifiers: [20: [201]],
            windowOwnerProcessIdentifiers: [20, 30]
        )

        XCTAssertTrue(plan.hasWindows(for: 20))
        XCTAssertTrue(plan.hasVisibleWindows(for: 20))
        XCTAssertTrue(plan.hasWindows(for: 30))
        XCTAssertFalse(plan.hasVisibleWindows(for: 30))
        XCTAssertFalse(plan.hasWindows(for: 40))
        XCTAssertFalse(plan.hasVisibleWindows(for: 40))
    }

    func testReportsWhereTheWindowServerPlacesAWindow() {
        let plan = WindowQueryPlan(
            visibleWindowIdentifiers: [30: [301, 302, 303], 40: []],
            windowOwnerProcessIdentifiers: [30, 40]
        )

        XCTAssertEqual(plan.visibility(ofWindow: 302, ownedBy: 30), .onScreen)
        XCTAssertEqual(plan.visibility(ofWindow: 399, ownedBy: 30), .offScreen)
        // A window is visible only as its own process's window.
        XCTAssertEqual(plan.visibility(ofWindow: 302, ownedBy: 40), .offScreen)
        XCTAssertEqual(plan.visibility(ofWindow: nil, ownedBy: 30), .unknown)
    }
}
