public enum ApplicationDiscoveryPolicy: Equatable, Sendable {
    public enum WindowQueryPriority: Equatable, Sendable {
        case primary
        case secondary
        case skip
    }

    case regular
    case windowsOnly
    case excluded

    public var isCandidate: Bool {
        self != .excluded
    }

    public func windowQueryPriority(
        hasWindowServerWindows: Bool,
        hasVisibleWindows: Bool
    ) -> WindowQueryPriority {
        switch self {
        case .regular:
            return .primary
        case .windowsOnly:
            if hasVisibleWindows {
                return .primary
            }
            return hasWindowServerWindows ? .secondary : .skip
        case .excluded:
            return .skip
        }
    }

    public func shouldInclude(hasSwitchableWindows: Bool) -> Bool {
        switch self {
        case .regular:
            true
        case .windowsOnly:
            // WindowServer visibility alone also includes system surfaces.
            // Require a window confirmed by the Accessibility query.
            hasSwitchableWindows
        case .excluded:
            false
        }
    }
}
