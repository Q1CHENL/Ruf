import XCTest
@testable import RufCore

final class ApplicationDiscoveryPolicyTests: XCTestCase {
    func testRegularApplicationsRemainAvailableWithoutWindows() {
        let policy = ApplicationDiscoveryPolicy.regular

        XCTAssertTrue(policy.isCandidate)
        XCTAssertEqual(
            policy.windowQueryPriority(hasWindowServerWindows: false, hasVisibleWindows: false),
            .primary
        )
        XCTAssertTrue(policy.shouldInclude(hasVisibleWindows: false, hasSwitchableWindows: false))
    }

    func testMenuBarApplicationsRequireConfirmedWindows() {
        let policy = ApplicationDiscoveryPolicy.windowsOnly

        XCTAssertTrue(policy.isCandidate)
        XCTAssertEqual(
            policy.windowQueryPriority(hasWindowServerWindows: false, hasVisibleWindows: false),
            .skip
        )
        XCTAssertEqual(
            policy.windowQueryPriority(hasWindowServerWindows: true, hasVisibleWindows: false),
            .secondary
        )
        XCTAssertFalse(policy.shouldInclude(hasVisibleWindows: false, hasSwitchableWindows: false))
        XCTAssertTrue(policy.shouldInclude(hasVisibleWindows: true, hasSwitchableWindows: false))
        XCTAssertTrue(policy.shouldInclude(hasVisibleWindows: false, hasSwitchableWindows: true))
    }

    func testVisibleMenuBarWindowsTakePriorityOverPotentialMinimizedWindows() {
        let policy = ApplicationDiscoveryPolicy.windowsOnly

        XCTAssertEqual(
            policy.windowQueryPriority(hasWindowServerWindows: true, hasVisibleWindows: true),
            .primary
        )
        XCTAssertEqual(
            policy.windowQueryPriority(hasWindowServerWindows: true, hasVisibleWindows: false),
            .secondary
        )
    }

    func testExcludedApplicationsStayExcludedEvenWithWindows() {
        let policy = ApplicationDiscoveryPolicy.excluded

        XCTAssertFalse(policy.isCandidate)
        XCTAssertEqual(
            policy.windowQueryPriority(hasWindowServerWindows: true, hasVisibleWindows: true),
            .skip
        )
        XCTAssertFalse(policy.shouldInclude(hasVisibleWindows: true, hasSwitchableWindows: true))
    }
}
