import Foundation
import Observation

public enum AppSwitcherMode: String, Sendable {
    case system
    case ruf
}

public enum WindowMovementStyle: String, Sendable {
    case live
    case outline
}

@MainActor
@Observable
public final class AppPreferences {
    private enum Key {
        static let launchAtLoginConfigured = "launchAtLoginConfigured"
        static let showsMenuBarItem = "showsMenuBarItem"
        static let switcherMode = "switcherMode"
        static let jumpToFirstOrLastEnabled = "jumpToFirstOrLastEnabled"
        static let newWindowShortcutEnabled = "newWindowShortcutEnabled"
        static let quitShortcutEnabled = "quitShortcutEnabled"
        static let windowMovementEnabled = "windowMovementEnabled"
        static let windowMovementStyle = "windowMovementStyle"
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

    public var isJumpToFirstOrLastEnabled: Bool {
        didSet {
            guard isJumpToFirstOrLastEnabled != oldValue else {
                return
            }

            defaults.set(
                isJumpToFirstOrLastEnabled,
                forKey: Key.jumpToFirstOrLastEnabled
            )
        }
    }

    public var isNewWindowShortcutEnabled: Bool {
        didSet {
            guard isNewWindowShortcutEnabled != oldValue else {
                return
            }

            defaults.set(
                isNewWindowShortcutEnabled,
                forKey: Key.newWindowShortcutEnabled
            )
        }
    }

    public var isQuitShortcutEnabled: Bool {
        didSet {
            guard isQuitShortcutEnabled != oldValue else {
                return
            }

            defaults.set(
                isQuitShortcutEnabled,
                forKey: Key.quitShortcutEnabled
            )
        }
    }

    public var windowMovementStyle: WindowMovementStyle {
        didSet {
            guard windowMovementStyle != oldValue else {
                return
            }

            defaults.set(
                windowMovementStyle.rawValue,
                forKey: Key.windowMovementStyle
            )
        }
    }

    public convenience init() {
        self.init(defaults: .standard)
    }

    public var shouldEnableLaunchAtLoginByDefault: Bool {
        !defaults.bool(forKey: Key.launchAtLoginConfigured)
    }

    public var requiresAccessibilityPermission: Bool {
        switcherMode == .ruf || isWindowMovementEnabled
    }

    public var enabledSwitcherShortcuts: SwitcherShortcuts {
        var shortcuts: SwitcherShortcuts = []
        if isJumpToFirstOrLastEnabled {
            shortcuts.insert(.jumpToFirstOrLast)
        }
        if isNewWindowShortcutEnabled {
            shortcuts.insert(.openNewWindow)
        }
        if isQuitShortcutEnabled {
            shortcuts.insert(.quitApplication)
        }
        return shortcuts
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
        isJumpToFirstOrLastEnabled = defaults.object(
            forKey: Key.jumpToFirstOrLastEnabled
        ) as? Bool ?? true
        isNewWindowShortcutEnabled = defaults.object(
            forKey: Key.newWindowShortcutEnabled
        ) as? Bool ?? true
        isQuitShortcutEnabled = defaults.object(
            forKey: Key.quitShortcutEnabled
        ) as? Bool ?? true
        isWindowMovementEnabled = defaults.object(
            forKey: Key.windowMovementEnabled
        ) as? Bool ?? true
        windowMovementStyle = defaults.string(
            forKey: Key.windowMovementStyle
        ).flatMap(WindowMovementStyle.init(rawValue:)) ?? .live

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
