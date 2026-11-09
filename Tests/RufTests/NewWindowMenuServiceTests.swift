import ApplicationServices
import XCTest

@testable import Ruf

final class NewWindowMenuServiceTests: XCTestCase {
    func testTimedOutPressCountsAsDeliveredSoItIsNotRepeated() {
        XCTAssertEqual(
            NewWindowMenuService.pressResult(for: .cannotComplete),
            .delivered
        )
        XCTAssertEqual(
            NewWindowMenuService.pressResult(for: .success),
            .delivered
        )
    }

    func testOnlyAVanishedMenuItemIsPressedAgain() {
        XCTAssertEqual(
            NewWindowMenuService.pressResult(for: .invalidUIElement),
            .stale
        )

        for error in [AXError.failure, .actionUnsupported, .apiDisabled] {
            XCTAssertEqual(
                NewWindowMenuService.pressResult(for: error),
                .failed
            )
        }
    }
}
