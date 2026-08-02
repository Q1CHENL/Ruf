import XCTest
@testable import RufCore

final class WindowQueryPlanTests: XCTestCase {
    func testSeparatesMultipleWindowAndReopenCandidatesInInputOrder() {
        let plan = WindowQueryPlan(
            processIdentifiers: [10, 20, 30, 40, 50],
            visibleWindowCounts: [
                20: 1,
                30: 3,
                40: 0,
                50: 2,
            ]
        )

        XCTAssertEqual(plan.multipleWindowCandidates, [30, 50])
        XCTAssertEqual(plan.reopenCandidates, [10, 40])
    }
}
