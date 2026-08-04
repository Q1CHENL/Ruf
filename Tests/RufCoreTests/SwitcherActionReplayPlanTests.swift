import XCTest
@testable import RufCore

final class SwitcherActionReplayPlanTests: XCTestCase {
    func testDefersNewWindowActionsUntilAfterPresentation() {
        let plan = SwitcherActionReplayPlan(
            pendingActions: [
                .cycle(backwards: false),
                .move(.right),
                .openNewWindow,
            ]
        )

        XCTAssertEqual(
            plan.beforePresentation,
            [
                .cycle(backwards: false),
                .move(.right),
            ]
        )
        XCTAssertEqual(plan.afterPresentation, [.openNewWindow])
    }

    func testKeepsOrdinaryCommitActionsBeforePresentation() {
        let actions: [SwitcherAction] = [
            .cycle(backwards: true),
            .commit,
        ]

        let plan = SwitcherActionReplayPlan(pendingActions: actions)

        XCTAssertEqual(plan.beforePresentation, actions)
        XCTAssertTrue(plan.afterPresentation.isEmpty)
    }
}
