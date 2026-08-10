import XCTest
@testable import RufCore

final class WindowQueryPlanTests: XCTestCase {
    func testOtherSpaceEvidencePreservesUnavailableAnswers() {
        XCTAssertEqual(
            OtherSpaceWindowEvidence(hasWindows: nil),
            .unavailable
        )
        XCTAssertEqual(
            OtherSpaceWindowEvidence(hasWindows: true),
            .present
        )
        XCTAssertEqual(
            OtherSpaceWindowEvidence(hasWindows: false),
            .absent
        )
    }

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
        XCTAssertEqual(resolve(), .windowless)
        XCTAssertEqual(resolve(hasVisibleWindows: true), .application)
        XCTAssertEqual(resolve(hasSwitchableAXWindows: true), .application)
        XCTAssertEqual(
            resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                switchableWindowMinimizedStates: [false]
            ),
            .singleWindow
        )
        XCTAssertEqual(
            resolve(
                hasSwitchableAXWindows: true,
                switchableWindowMinimizedStates: [true]
            ),
            .windows
        )
        XCTAssertEqual(
            resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                switchableWindowMinimizedStates: [false, true]
            ),
            .windows
        )
        XCTAssertEqual(resolve(isApplicationHidden: true), .application)
    }

    // hasVisibleWindows stops covering for AX reads that time out as soon as
    // the application's windows are not on the current Space, so an incomplete
    // scan has to fall back to the app tile on its own.
    func testIncompleteWindowReadsNeverReportWindowless() {
        XCTAssertEqual(
            resolve(hasIncompleteWindowReads: true),
            .application
        )
        XCTAssertEqual(resolve(), .windowless)

        // Windows that were read stay authoritative even when the rest of the
        // scan did not finish.
        XCTAssertEqual(
            resolve(
                hasSwitchableAXWindows: true,
                hasIncompleteWindowReads: true,
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
            resolve(otherSpaceWindowEvidence: .present),
            .application
        )

        // An application with nothing anywhere still earns its reopen badge.
        XCTAssertEqual(resolve(), .windowless)

        // Windows on the current Space stay the ones the switcher offers; a
        // Space the user is not on does not add targets to the grid.
        XCTAssertEqual(
            resolve(
                hasSwitchableAXWindows: true,
                hasVisibleWindows: true,
                otherSpaceWindowEvidence: .present,
                switchableWindowMinimizedStates: [false]
            ),
            .singleWindow
        )
    }

    func testUnavailableOtherSpaceEvidenceNeverReportsWindowless() {
        XCTAssertEqual(
            resolve(otherSpaceWindowEvidence: .unavailable),
            .application
        )
    }

    private func resolve(
        hasSwitchableAXWindows: Bool = false,
        hasVisibleWindows: Bool = false,
        isApplicationHidden: Bool = false,
        hasIncompleteWindowReads: Bool = false,
        otherSpaceWindowEvidence: OtherSpaceWindowEvidence = .absent,
        switchableWindowMinimizedStates: [Bool] = []
    ) -> WindowQueryDisposition {
        WindowQueryDisposition.resolve(
            hasSwitchableAXWindows: hasSwitchableAXWindows,
            hasVisibleWindows: hasVisibleWindows,
            isApplicationHidden: isApplicationHidden,
            hasIncompleteWindowReads: hasIncompleteWindowReads,
            otherSpaceWindowEvidence: otherSpaceWindowEvidence,
            switchableWindowMinimizedStates: switchableWindowMinimizedStates
        )
    }
}
