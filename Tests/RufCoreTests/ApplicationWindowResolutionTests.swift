import XCTest
@testable import RufCore

final class ApplicationWindowResolutionTests: XCTestCase {
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

    func testOffersOneVisibleWindowAsTheApplication() {
        XCTAssertEqual(
            resolve([window("A")], hasVisibleWindows: true),
            .singleWindow("A")
        )
    }

    func testOffersEachVisibleOrMinimizedWindowFocusedFirst() {
        XCTAssertEqual(
            resolve(
                [
                    window("A"),
                    window("B", isMinimized: true),
                    window("C", isFocused: true),
                ],
                hasVisibleWindows: true
            ),
            .windows(["C", "A", "B"])
        )
    }

    func testOffersALoneMinimizedWindowAsAWindow() {
        XCTAssertEqual(
            resolve([window("A", isMinimized: true)]),
            .windows(["A"])
        )
    }

    // Minimized windows leave the on-screen list, so Accessibility's own
    // marker is what keeps them, whatever the WindowServer reports.
    func testKeepsMinimizedWindowsWhateverTheirVisibility() {
        for visibility in [
            WindowServerVisibility.onScreen,
            .offScreen,
            .unknown,
        ] {
            XCTAssertEqual(
                resolve([
                    window("A", isMinimized: true, visibility: visibility),
                ]),
                .windows(["A"])
            )
        }
    }

    // Panels, sheets, and floating surfaces are not switch targets, and they
    // are no evidence that the application has one.
    func testIgnoresWindowsThatAreNotSwitchable() {
        XCTAssertEqual(
            resolve(
                [
                    window("Panel", isSwitchable: false),
                    window("A"),
                ],
                hasVisibleWindows: true
            ),
            .singleWindow("A")
        )
        XCTAssertEqual(
            resolve([window("Panel", isSwitchable: false, visibility: .offScreen)]),
            .windowless
        )
    }

    // Ordered-out and ghost Accessibility elements are not targets, but they
    // are no proof that the application has nothing either.
    func testDropsOffScreenWindowsWithoutReportingWindowless() {
        XCTAssertEqual(
            resolve(
                [window("Ghost", visibility: .offScreen), window("A")],
                hasVisibleWindows: true
            ),
            .singleWindow("A")
        )
        XCTAssertEqual(
            resolve([window("Ghost", visibility: .offScreen)]),
            .application
        )
    }

    // Without `_AXUIElementGetWindow` no visible window can be placed. The
    // minimized one alone would replace the app tile, and choosing it would
    // restore that window instead of showing the visible ones.
    func testUnidentifiedVisibleWindowsKeepTheApplicationTile() {
        XCTAssertEqual(
            resolve(
                [
                    window("A", visibility: .unknown),
                    window("B", visibility: .unknown),
                    window("M", isMinimized: true, visibility: .unknown),
                ],
                hasVisibleWindows: true
            ),
            .application
        )
        XCTAssertEqual(
            resolve([window("A", visibility: .unknown)]),
            .application
        )
    }

    func testConfirmedVisibleWindowsOutweighUnidentifiedOnes() {
        XCTAssertEqual(
            resolve(
                [
                    window("A"),
                    window("B", visibility: .unknown),
                    window("M", isMinimized: true),
                ],
                hasVisibleWindows: true
            ),
            .windows(["A", "M"])
        )
        XCTAssertEqual(
            resolve(
                [window("A"), window("B", visibility: .unknown)],
                hasVisibleWindows: true
            ),
            .singleWindow("A")
        )
    }

    func testUnreadWindowsKeepTheApplicationTileBesideMinimizedOnes() {
        XCTAssertEqual(
            resolve(
                [window("M", isMinimized: true)],
                hasUnreadWindows: true
            ),
            .application
        )
    }

    // Hiding an application orders its windows out, so they look exactly like
    // ghosts but are the windows the user will get back.
    func testHiddenWindowsKeepTheApplicationTile() {
        let windows = [
            window("H", visibility: .offScreen),
            window("M", isMinimized: true),
        ]

        XCTAssertEqual(
            resolve(windows, isApplicationHidden: true),
            .application
        )
        XCTAssertEqual(resolve(windows), .windows(["M"]))
        XCTAssertEqual(
            resolve(
                [window("M", isMinimized: true)],
                isApplicationHidden: true
            ),
            .windows(["M"])
        )
    }

    func testOffersReopeningOnlyWithoutAnyEvidenceOfWindows() {
        XCTAssertEqual(resolve([]), .windowless)
        XCTAssertEqual(resolve([], hasVisibleWindows: true), .application)
        XCTAssertEqual(resolve([], isApplicationHidden: true), .application)
    }

    // hasVisibleWindows stops covering for AX reads that time out as soon as
    // the application's windows are not on the current Space, so an incomplete
    // scan has to fall back to the app tile on its own.
    func testUnreadWindowsNeverReportWindowless() {
        XCTAssertEqual(resolve([], hasUnreadWindows: true), .application)

        // Windows that were read stay authoritative even when the rest of the
        // scan did not finish.
        XCTAssertEqual(
            resolve([window("A")], hasUnreadWindows: true),
            .singleWindow("A")
        )
    }

    // Accessibility hands back an empty window list for an application whose
    // windows are on another Space, and the on-screen list cannot see that
    // Space either, so both readings are complete, agree, and are wrong. The
    // WindowServer's Space bookkeeping is the only thing that contradicts them.
    func testWindowsOnAnotherSpaceOutweighTwoEmptyReadings() {
        XCTAssertEqual(
            resolve([], otherSpaceWindowEvidence: .present),
            .application
        )

        // Windows on the current Space stay the ones the switcher offers; a
        // Space the user is not on does not add targets to the grid.
        XCTAssertEqual(
            resolve(
                [window("A")],
                hasVisibleWindows: true,
                otherSpaceWindowEvidence: .present
            ),
            .singleWindow("A")
        )
    }

    func testUnavailableOtherSpaceEvidenceNeverReportsWindowless() {
        XCTAssertEqual(
            resolve([], otherSpaceWindowEvidence: .unavailable),
            .application
        )
    }

    private func window(
        _ name: String,
        isSwitchable: Bool = true,
        isMinimized: Bool = false,
        isFocused: Bool = false,
        visibility: WindowServerVisibility = .onScreen
    ) -> ApplicationWindowObservation<String> {
        ApplicationWindowObservation(
            window: name,
            isSwitchable: isSwitchable,
            isMinimized: isMinimized,
            isFocused: isFocused,
            visibility: visibility
        )
    }

    private func resolve(
        _ observations: [ApplicationWindowObservation<String>],
        hasUnreadWindows: Bool = false,
        hasVisibleWindows: Bool = false,
        isApplicationHidden: Bool = false,
        otherSpaceWindowEvidence: OtherSpaceWindowEvidence = .absent
    ) -> ApplicationWindowResolution<String> {
        .resolve(
            observations,
            hasUnreadWindows: hasUnreadWindows,
            hasVisibleWindows: hasVisibleWindows,
            isApplicationHidden: isApplicationHidden,
            otherSpaceWindowEvidence: otherSpaceWindowEvidence
        )
    }
}
