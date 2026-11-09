import XCTest
@testable import RufCore

final class ManagedDisplaySpacesTests: XCTestCase {
    func testListsEverySpaceThatIsNotCurrentOnItsDisplay() {
        let displays = [
            display(current: 1, spaces: [1, 2, 3]),
            display(current: 10, spaces: [10, 11]),
        ]

        XCTAssertEqual(
            ManagedDisplaySpaces.otherSpaceIdentifiers(in: displays),
            [2, 3, 11]
        )
    }

    func testASingleSpaceMacHasNoOtherSpaces() {
        XCTAssertEqual(
            ManagedDisplaySpaces.otherSpaceIdentifiers(
                in: [display(current: 1, spaces: [1])]
            ),
            []
        )
    }

    // An unreadable layout must not pass for a Mac without other Spaces, or
    // applications whose windows are elsewhere would read as windowless.
    func testALayoutWithoutSpaceIdentifiersIsUnavailable() {
        XCTAssertNil(ManagedDisplaySpaces.otherSpaceIdentifiers(in: []))
        XCTAssertNil(
            ManagedDisplaySpaces.otherSpaceIdentifiers(
                in: [display(current: 1, spaces: [])]
            )
        )
        XCTAssertNil(
            ManagedDisplaySpaces.otherSpaceIdentifiers(
                in: [["Spaces": [["ManagedSpaceID": 1]]]]
            )
        )
    }

    // SkyLight hands back Foundation objects, so the identifiers arrive as
    // NSNumber values inside NSDictionary instances.
    func testReadsTheFoundationObjectsSkyLightReturns() {
        let displays: NSArray = [
            NSDictionary(dictionary: [
                "Current Space": NSDictionary(dictionary: [
                    "id64": NSNumber(value: UInt64(1)),
                ]),
                "Spaces": NSArray(array: [
                    NSDictionary(dictionary: ["id64": NSNumber(value: UInt64(1))]),
                    NSDictionary(dictionary: ["id64": NSNumber(value: UInt64(2))]),
                ]),
            ]),
        ]

        XCTAssertEqual(
            (displays as? [[String: Any]]).flatMap(
                ManagedDisplaySpaces.otherSpaceIdentifiers(in:)
            ),
            [2]
        )
    }

    private func display(
        current: UInt64,
        spaces: [UInt64]
    ) -> [String: Any] {
        [
            "Current Space": ["id64": current],
            "Spaces": spaces.map { ["id64": $0] },
        ]
    }
}
