import XCTest
@testable import RufCore

final class DockBadgeTests: XCTestCase {
    func testRejectsMissingOrBlankStatusLabels() {
        XCTAssertNil(DockBadge(statusLabel: nil))
        XCTAssertNil(DockBadge(statusLabel: "  \n"))
    }

    func testPreservesCompactStatusLabels() throws {
        let countBadge = try XCTUnwrap(DockBadge(statusLabel: "  42 "))
        XCTAssertEqual(countBadge.displayText, "42")
        XCTAssertEqual(countBadge.accessibilityLabel, "42")

        let symbolBadge = try XCTUnwrap(DockBadge(statusLabel: "!"))
        XCTAssertEqual(symbolBadge.displayText, "!")
        XCTAssertEqual(symbolBadge.accessibilityLabel, "!")
    }

    func testCapsLargeNumericCounts() throws {
        let badge = try XCTUnwrap(DockBadge(statusLabel: "1000"))
        XCTAssertEqual(badge.displayText, "999+")
        XCTAssertEqual(badge.accessibilityLabel, "1000")
    }

    func testUsesADotForLongNonnumericLabels() throws {
        let badge = try XCTUnwrap(DockBadge(statusLabel: "SYNCING"))
        XCTAssertNil(badge.displayText)
        XCTAssertEqual(badge.accessibilityLabel, "SYNCING")
    }
}
