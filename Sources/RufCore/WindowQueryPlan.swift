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

public enum WindowQueryDisposition: Equatable, Sendable {
    case application
    case singleWindow
    case windowless
    case windows

    public static func resolve(
        hasSwitchableAXWindows: Bool,
        hasVisibleWindows: Bool,
        isApplicationHidden: Bool,
        hasIncompleteWindowReads: Bool,
        otherSpaceWindowEvidence: OtherSpaceWindowEvidence,
        switchableWindowMinimizedStates: [Bool]
    ) -> Self {
        if switchableWindowMinimizedStates == [false] {
            return .singleWindow
        }

        if switchableWindowMinimizedStates.count > 1
            || switchableWindowMinimizedStates.contains(true) {
            return .windows
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
        return hasSwitchableAXWindows
            || hasVisibleWindows
            || isApplicationHidden
            || hasIncompleteWindowReads
            || otherSpaceWindowEvidence != .absent
            ? .application
            : .windowless
    }
}

public struct WindowQueryPlan: Equatable, Sendable {
    private let visibleWindowIdentifiers: [Int32: Set<UInt32>]

    public init(visibleWindowIdentifiers: [Int32: Set<UInt32>]) {
        self.visibleWindowIdentifiers = visibleWindowIdentifiers
    }

    public func shouldIncludeWindow(
        identifier: UInt32?,
        processIdentifier: Int32,
        isMinimized: Bool
    ) -> Bool {
        if isMinimized {
            return true
        }

        guard let identifier else {
            return false
        }

        return visibleWindowIdentifiers[processIdentifier]?.contains(identifier) == true
    }

    public func hasVisibleWindows(for processIdentifier: Int32) -> Bool {
        visibleWindowIdentifiers[processIdentifier]?.isEmpty == false
    }
}
