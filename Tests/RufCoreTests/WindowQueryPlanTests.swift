import XCTest
@testable import RufCore

final class WindowQueryPlanTests: XCTestCase {
    func testIncludesOnlyVisibleOrMinimizedWindows() {
        let visibleWindowIdentifiers: [Int32: Set<UInt32>] = [
            20: [201],
            30: [301, 302, 303],
            40: [],
            50: [501, 502],
        ]
        let plan = WindowQueryPlan(
            visibleWindowIdentifiers: visibleWindowIdentifiers
        )

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

    func testChoosesTargetShapeFromSwitchableWindows() {
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                switchableWindowMinimizedStates: []
            ),
            .windowless
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: true,
                isApplicationHidden: false,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                isApplicationHidden: false,
                switchableWindowMinimizedStates: [false]
            ),
            .singleWindow
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                switchableWindowMinimizedStates: [true]
            ),
            .windows
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                isApplicationHidden: false,
                switchableWindowMinimizedStates: [false, true]
            ),
            .windows
        )

        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: false,
                isApplicationHidden: true,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
    }
}
