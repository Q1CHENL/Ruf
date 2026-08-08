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

    @MainActor
    func testWindowMovementDefaultsOnAndPersistsOptOut() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.isWindowMovementEnabled)

        preferences.isWindowMovementEnabled = false

        let reloadedPreferences = AppPreferences(defaults: defaults)

        XCTAssertFalse(reloadedPreferences.isWindowMovementEnabled)
    }

    @MainActor
    func testMenuBarItemDefaultsVisibleAndPersistsHiddenInRufMode() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.showsMenuBarItem)

        preferences.showsMenuBarItem = false

        let reloadedPreferences = AppPreferences(defaults: defaults)

        XCTAssertFalse(reloadedPreferences.showsMenuBarItem)
    }

    @MainActor
    func testSystemSwitcherRequiresAVisibleMenuBarItem() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showsMenuBarItem = false

        preferences.switcherMode = .system

        XCTAssertTrue(preferences.showsMenuBarItem)

        preferences.showsMenuBarItem = false

        XCTAssertTrue(preferences.showsMenuBarItem)

        let reloadedPreferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(reloadedPreferences.switcherMode, .system)
        XCTAssertTrue(reloadedPreferences.showsMenuBarItem)
    }

    @MainActor
    func testLaunchAtLoginIsEnabledByDefaultOnlyUntilConfigured() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.shouldEnableLaunchAtLoginByDefault)

        preferences.markLaunchAtLoginConfigured()

        let reloadedPreferences = AppPreferences(defaults: defaults)

        XCTAssertFalse(reloadedPreferences.shouldEnableLaunchAtLoginByDefault)
    }
}
