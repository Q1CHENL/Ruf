import ApplicationServices
import RufCore
import XCTest

@testable import Ruf

final class ApplicationWindowSnapshotTests: XCTestCase {
    func testAccessoryApplicationsWithoutConfirmedAXWindowsAreExcluded() {
        let snapshot = ApplicationWindowService.Snapshot(
            states: [30: .windowless]
        )

        XCTAssertFalse(snapshot.includesApplication(20, policy: .windowsOnly))
        XCTAssertFalse(snapshot.includesApplication(30, policy: .windowsOnly))
    }

    func testConfirmedVisibleAccessoryWindowIsIncluded() {
        let window = ApplicationWindow(
            element: AXUIElementCreateApplication(getpid()),
            title: nil,
            isMinimized: false
        )
        let snapshot = ApplicationWindowService.Snapshot(
            states: [20: .singleWindow(window)]
        )

        XCTAssertTrue(snapshot.includesApplication(20, policy: .windowsOnly))
    }

    func testMinimizedAccessoryWindowIsIncludedWithoutVisibleWindows() {
        let window = ApplicationWindow(
            element: AXUIElementCreateApplication(getpid()),
            title: nil,
            isMinimized: true
        )
        let snapshot = ApplicationWindowService.Snapshot(
            states: [20: .windows([window]), 30: .windowless]
        )

        XCTAssertTrue(snapshot.includesApplication(20, policy: .windowsOnly))
        XCTAssertFalse(snapshot.includesApplication(30, policy: .windowsOnly))
    }

    func testUnavailableWindowInventoryKeepsOnlyRegularApplications() {
        let snapshot = ApplicationWindowService.Snapshot(states: [:])

        XCTAssertTrue(snapshot.includesApplication(20, policy: .regular))
        XCTAssertFalse(snapshot.includesApplication(30, policy: .windowsOnly))
    }
}
