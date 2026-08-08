import Foundation
import Observation

public enum AppSwitcherMode: String, Sendable {
    case system
    case ruf
}

@MainActor
@Observable
public final class AppPreferences {
    private enum Key {
        static let launchAtLoginConfigured = "launchAtLoginConfigured"
        static let switcherMode = "switcherMode"
        static let windowMovementEnabled = "windowMovementEnabled"
    }

    private let defaults: UserDefaults

    public var switcherMode: AppSwitcherMode {
        didSet {
            guard switcherMode != oldValue else {
                return
            }

            defaults.set(switcherMode.rawValue, forKey: Key.switcherMode)
        }
    }

    public var isWindowMovementEnabled: Bool {
        didSet {
            guard isWindowMovementEnabled != oldValue else {
                return
            }

            defaults.set(
                isWindowMovementEnabled,
                forKey: Key.windowMovementEnabled
            )
        }
    }

    public convenience init() {
        self.init(defaults: .standard)
    }

    public var shouldEnableLaunchAtLoginByDefault: Bool {
        !defaults.bool(forKey: Key.launchAtLoginConfigured)
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        switcherMode = defaults.string(forKey: Key.switcherMode)
            .flatMap(AppSwitcherMode.init(rawValue:)) ?? .ruf
        isWindowMovementEnabled = defaults.object(
            forKey: Key.windowMovementEnabled
        ) as? Bool ?? true
    }

    public func markLaunchAtLoginConfigured() {
        defaults.set(true, forKey: Key.launchAtLoginConfigured)
    }
}
