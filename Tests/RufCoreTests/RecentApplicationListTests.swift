import XCTest
@testable import RufCore

final class RecentApplicationListTests: XCTestCase {
    func testInitializationDeduplicatesWhilePreservingMostRecentRank() {
        let recents = RecentApplicationList(
            identifiers: ["one", "two", "one", "three", "two", "four"],
            limit: 3
        )

        XCTAssertEqual(recents.identifiers, ["one", "two", "three"])
    }

    func testRecordingMovesAnIdentifierToTheFrontAndEnforcesTheLimit() {
        var recents = RecentApplicationList(
            identifiers: ["one", "two", "three"],
            limit: 3
        )

        recents.record("two")
        XCTAssertEqual(recents.identifiers, ["two", "one", "three"])

        recents.record("four")
        XCTAssertEqual(recents.identifiers, ["four", "two", "one"])
    }
}
