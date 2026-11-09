public enum OtherSpaceWindowEvidence: Equatable, Sendable {
    case present
    case absent
    case unavailable

    public init(hasWindows: Bool?) {
        switch hasWindows {
        case true:
            self = .present
        case false:
            self = .absent
        case nil:
            self = .unavailable
        }
    }
}

/// One window Accessibility reported for an application.
public struct ApplicationWindowObservation<Window> {
    public let window: Window
    /// A standard window or dialog, as opposed to a panel, sheet, or other
    /// surface the user does not switch to.
    public let isSwitchable: Bool
    public let isMinimized: Bool
    public let isFocused: Bool
    public let visibility: WindowServerVisibility

    public init(
        window: Window,
        isSwitchable: Bool,
        isMinimized: Bool,
        isFocused: Bool,
        visibility: WindowServerVisibility
    ) {
        self.window = window
        self.isSwitchable = isSwitchable
        self.isMinimized = isMinimized
        self.isFocused = isFocused
        self.visibility = visibility
    }
}

/// What the switcher offers for one application.
public enum ApplicationWindowResolution<Window> {
    /// The application itself, because Ruf cannot tell which of its windows
    /// to offer.
    case application
    /// The application's only window, offered as the application.
    case singleWindow(Window)
    /// Nothing to switch to, so the application is offered to be reopened.
    case windowless
    /// Each window, the focused one first.
    case windows([Window])

    public var hasSwitchableWindows: Bool {
        switch self {
        case .singleWindow, .windows:
            true
        case .application, .windowless:
            false
        }
    }

    public static func resolve(
        _ observations: [ApplicationWindowObservation<Window>],
        hasUnreadWindows: Bool,
        hasVisibleWindows: Bool,
        isApplicationHidden: Bool,
        otherSpaceWindowEvidence: OtherSpaceWindowEvidence
    ) -> Self {
        let switchableObservations = observations.filter(\.isSwitchable)
        // The WindowServer is authoritative for ordinary windows and rejects
        // other-Space, ordered-out, and ghost Accessibility elements. It does
        // not show minimized windows, which Accessibility marks explicitly.
        var targets = switchableObservations.filter {
            $0.isMinimized || $0.visibility == .onScreen
        }
        if let focusedIndex = targets.firstIndex(where: \.isFocused) {
            targets.insert(targets.remove(at: focusedIndex), at: 0)
        }

        if targets.count == 1, !targets[0].isMinimized {
            return .singleWindow(targets[0].window)
        }

        if !targets.isEmpty {
            return .windows(targets.map(\.window))
        }

        // Only a window scan that ran to completion can prove an application
        // has nothing to switch to. A read that timed out or came back with a
        // transient AX error is unknown, and the app-level tile is the safe
        // reading of unknown -- a reopen badge on a windowed application sends
        // the user somewhere they did not ask to go. Neither Accessibility nor
        // the on-screen window list can see another Space at all, so windows
        // found there are the remaining reason an empty reading is not an
        // empty application. If that private query is unavailable, the absence
        // of other-Space windows is likewise unproven.
        return !switchableObservations.isEmpty
            || hasVisibleWindows
            || isApplicationHidden
            || hasUnreadWindows
            || otherSpaceWindowEvidence != .absent
            ? .application
            : .windowless
    }
}

extension ApplicationWindowResolution: Equatable where Window: Equatable {}
extension ApplicationWindowResolution: Sendable where Window: Sendable {}
