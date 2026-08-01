import Foundation
import XCTest
@testable import RufCore

final class AppPreferencesTests: XCTestCase {
    @MainActor
    func testDefaultsToRuf() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.switcherMode, .ruf)
    }

    @MainActor
    func testSwitcherModePersistsAcrossInstances() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.switcherMode = .system

        let reloadedPreferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(reloadedPreferences.switcherMode, .system)
    }

}
