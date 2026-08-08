import Foundation
import Observation

@MainActor
@Observable
public final class SoftwareUpdateAvailability {
    private enum Key {
        static let availableVersion = "availableSoftwareUpdateVersion"
        static let installedVersion = "installedVersionAtUpdateDiscovery"
    }

    private let currentVersion: String
    private let defaults: UserDefaults

    public private(set) var availableVersion: String?

    public init(
        currentVersion: String,
        defaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults

        if defaults.string(forKey: Key.installedVersion) == currentVersion {
            availableVersion = defaults.string(forKey: Key.availableVersion)
        } else {
            availableVersion = nil
            defaults.removeObject(forKey: Key.availableVersion)
            defaults.removeObject(forKey: Key.installedVersion)
        }
    }

    public func recordAvailable(version: String) {
        guard !version.isEmpty, version != currentVersion else {
            clear()
            return
        }

        availableVersion = version
        defaults.set(version, forKey: Key.availableVersion)
        defaults.set(currentVersion, forKey: Key.installedVersion)
    }

    public func clear(version: String? = nil) {
        guard version == nil || version == availableVersion else {
            return
        }

        availableVersion = nil
        defaults.removeObject(forKey: Key.availableVersion)
        defaults.removeObject(forKey: Key.installedVersion)
    }
}
