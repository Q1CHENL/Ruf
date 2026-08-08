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
        static let showsMenuBarItem = "showsMenuBarItem"
        static let switcherMode = "switcherMode"
        static let windowMovementEnabled = "windowMovementEnabled"
    }

    private let defaults: UserDefaults

    public var switcherMode: AppSwitcherMode {
        didSet {
            if switcherMode == .system {
                showsMenuBarItem = true
            }

            guard switcherMode != oldValue else {
                return
            }

            defaults.set(switcherMode.rawValue, forKey: Key.switcherMode)
        }
    }

    public var showsMenuBarItem: Bool {
        didSet {
            if switcherMode == .system, !showsMenuBarItem {
                showsMenuBarItem = true
            }

            guard showsMenuBarItem != oldValue else {
                return
            }

            defaults.set(
                showsMenuBarItem,
                forKey: Key.showsMenuBarItem
            )
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
        let switcherMode = defaults.string(forKey: Key.switcherMode)
            .flatMap(AppSwitcherMode.init(rawValue:)) ?? .ruf
        let storedMenuBarVisibility = defaults.object(
            forKey: Key.showsMenuBarItem
        ) as? Bool ?? true

        self.defaults = defaults
        self.switcherMode = switcherMode
        showsMenuBarItem = switcherMode == .system
            ? true
            : storedMenuBarVisibility
        isWindowMovementEnabled = defaults.object(
            forKey: Key.windowMovementEnabled
        ) as? Bool ?? true

        if showsMenuBarItem != storedMenuBarVisibility {
            defaults.set(
                showsMenuBarItem,
                forKey: Key.showsMenuBarItem
            )
        }
    }

    public func markLaunchAtLoginConfigured() {
        defaults.set(true, forKey: Key.launchAtLoginConfigured)
    }
}
