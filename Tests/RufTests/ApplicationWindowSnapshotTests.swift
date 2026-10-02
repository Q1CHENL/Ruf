import ApplicationServices
import RufCore
import XCTest

@testable import Ruf

final class ApplicationWindowSnapshotTests: XCTestCase {
    func testVisibleAccessoryWindowSurvivesUnavailableAXRead() {
        let snapshot = ApplicationWindowService.Snapshot(
            states: [:],
            plan: WindowQueryPlan(
                visibleWindowIdentifiers: [20: [201]],
                windowOwnerProcessIdentifiers: [20, 30]
            )
        )

        XCTAssertTrue(snapshot.includesApplication(20, policy: .windowsOnly))
        XCTAssertFalse(snapshot.includesApplication(30, policy: .windowsOnly))
    }

    func testMinimizedAccessoryWindowIsIncludedWithoutVisibleWindows() {
        let window = ApplicationWindow(
            element: AXUIElementCreateApplication(getpid()),
            title: nil,
            isMinimized: true
        )
        let snapshot = ApplicationWindowService.Snapshot(
            states: [20: .windows([window]), 30: .windowless],
            plan: WindowQueryPlan(
                visibleWindowIdentifiers: [:],
                windowOwnerProcessIdentifiers: [20, 30]
            )
        )

        XCTAssertTrue(snapshot.includesApplication(20, policy: .windowsOnly))
        XCTAssertFalse(snapshot.includesApplication(30, policy: .windowsOnly))
    }

    func testUnavailableWindowInventoryKeepsOnlyRegularApplications() {
        let snapshot = ApplicationWindowService.Snapshot(states: [:], plan: nil)

        XCTAssertTrue(snapshot.includesApplication(20, policy: .regular))
        XCTAssertFalse(snapshot.includesApplication(30, policy: .windowsOnly))
    }
}
