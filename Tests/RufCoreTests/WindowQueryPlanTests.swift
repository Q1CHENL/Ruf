import XCTest
@testable import RufCore

final class WindowQueryPlanTests: XCTestCase {
    func testSeparatesMultipleWindowAndReopenCandidatesInInputOrder() {
        let visibleWindowIdentifiers: [Int32: Set<UInt32>] = [
            20: [201],
            30: [301, 302, 303],
            40: [],
            50: [501, 502],
        ]
        let plan = WindowQueryPlan(
            processIdentifiers: [10, 20, 30, 40, 50],
            visibleWindowIdentifiers: visibleWindowIdentifiers
        )

        XCTAssertEqual(plan.multipleWindowCandidates, [30, 50])
        XCTAssertEqual(plan.reopenCandidates, [10, 40])
        XCTAssertTrue(
            plan.containsVisibleWindow(
                identifier: 302,
                processIdentifier: 30
            )
        )
        XCTAssertFalse(
            plan.containsVisibleWindow(
                identifier: 399,
                processIdentifier: 30
            )
        )
    }
}
