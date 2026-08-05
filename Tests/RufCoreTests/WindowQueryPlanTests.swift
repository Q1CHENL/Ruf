import XCTest
@testable import RufCore

final class WindowQueryPlanTests: XCTestCase {
    func testQueriesEveryApplicationAndIncludesOnlyVisibleOrMinimizedWindows() {
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

        XCTAssertEqual(plan.windowQueryCandidates, [10, 20, 30, 40, 50])
        XCTAssertTrue(
            plan.shouldIncludeWindow(
                identifier: 302,
                processIdentifier: 30,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            plan.shouldIncludeWindow(
                identifier: 399,
                processIdentifier: 30,
                isMinimized: false
            )
        )
        XCTAssertTrue(
            plan.shouldIncludeWindow(
                identifier: nil,
                processIdentifier: 40,
                isMinimized: true
            )
        )
    }

    func testChoosesApplicationWindowAndReopenTargetShapes() {
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasAXWindows: false,
                hasVisibleWindows: false,
                switchableWindowMinimizedStates: []
            ),
            .windowless
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasAXWindows: false,
                hasVisibleWindows: true,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasAXWindows: true,
                hasVisibleWindows: false,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasAXWindows: true,
                hasVisibleWindows: true,
                switchableWindowMinimizedStates: [false]
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasAXWindows: true,
                hasVisibleWindows: false,
                switchableWindowMinimizedStates: [true]
            ),
            .windows
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasAXWindows: true,
                hasVisibleWindows: true,
                switchableWindowMinimizedStates: [false, true]
            ),
            .windows
        )
    }
}
