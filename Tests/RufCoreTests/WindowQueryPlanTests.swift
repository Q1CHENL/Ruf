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
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: []
            ),
            .windowless
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: true,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: [false]
            ),
            .singleWindow
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: [true]
            ),
            .windows
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: [false, true]
            ),
            .windows
        )

        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: false,
                isApplicationHidden: true,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
    }

    // hasVisibleWindows stops covering for AX reads that time out as soon as
    // the application's windows are not on the current Space, so an incomplete
    // scan has to fall back to the app tile on its own.
    func testIncompleteWindowReadsNeverReportWindowless() {
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                hasIncompleteWindowReads: true,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: []
            ),
            .windowless
        )
        // Windows that were read stay authoritative even when the rest of the
        // scan did not finish.
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                hasIncompleteWindowReads: true,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: [false]
            ),
            .singleWindow
        )
    }

    // Accessibility hands back an empty window list for an application whose
    // windows are on another Space, and the on-screen list cannot see that
    // Space either, so both readings are complete, agree, and are wrong. The
    // WindowServer's Space bookkeeping is the only thing that contradicts them.
    func testWindowsOnAnotherSpaceOutweighTwoEmptyReadings() {
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: true,
                switchableWindowMinimizedStates: []
            ),
            .application
        )
        // An application with nothing anywhere still earns its reopen badge.
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: false,
                hasVisibleWindows: false,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: false,
                switchableWindowMinimizedStates: []
            ),
            .windowless
        )
        // Windows on the current Space stay the ones the switcher offers; a
        // Space the user is not on does not add targets to the grid.
        XCTAssertEqual(
            WindowQueryDisposition.resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                isApplicationHidden: false,
                hasIncompleteWindowReads: false,
                hasWindowsOnAnotherSpace: true,
                switchableWindowMinimizedStates: [false]
            ),
            .singleWindow
        )
    }
}
