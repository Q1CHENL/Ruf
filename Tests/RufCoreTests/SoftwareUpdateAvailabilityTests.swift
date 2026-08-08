import Foundation
import RufCore
import XCTest

final class SoftwareUpdateAvailabilityTests: XCTestCase {
    @MainActor
    func testPersistsAnAvailableUpdateForTheCurrentInstalledVersion() {
        withDefaults { defaults in
            let availability = SoftwareUpdateAvailability(
                currentVersion: "0.5.2",
                defaults: defaults
            )

            availability.recordAvailable(version: "0.5.3")

            let reloadedAvailability = SoftwareUpdateAvailability(
                currentVersion: "0.5.2",
                defaults: defaults
            )
            XCTAssertEqual(
                reloadedAvailability.availableVersion,
                "0.5.3"
            )
        }
    }

    @MainActor
    func testClearsPersistedAvailabilityAfterTheInstalledVersionChanges() {
        withDefaults { defaults in
            let availability = SoftwareUpdateAvailability(
                currentVersion: "0.5.2",
                defaults: defaults
            )
            availability.recordAvailable(version: "0.5.3")

            let updatedApplicationAvailability = SoftwareUpdateAvailability(
                currentVersion: "0.5.3",
                defaults: defaults
            )

            XCTAssertNil(updatedApplicationAvailability.availableVersion)
            XCTAssertNil(
                SoftwareUpdateAvailability(
                    currentVersion: "0.5.3",
                    defaults: defaults
                ).availableVersion
            )
        }
    }

    @MainActor
    func testOnlyMatchingUpdateEventsClearAvailability() {
        withDefaults { defaults in
            let availability = SoftwareUpdateAvailability(
                currentVersion: "0.5.2",
                defaults: defaults
            )
            availability.recordAvailable(version: "0.5.3")

            availability.clear(version: "0.5.4")
            XCTAssertEqual(availability.availableVersion, "0.5.3")

            availability.clear(version: "0.5.3")
            XCTAssertNil(availability.availableVersion)
        }
    }

    @MainActor
    private func withDefaults(
        _ body: (UserDefaults) -> Void
    ) {
        let suiteName = "SoftwareUpdateAvailabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        body(defaults)
    }
}
