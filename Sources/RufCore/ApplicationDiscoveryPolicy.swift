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

    public func shouldInclude(hasVisibleWindows: Bool, hasSwitchableWindows: Bool) -> Bool {
        switch self {
        case .regular:
            true
        case .windowsOnly:
            hasVisibleWindows || hasSwitchableWindows
        case .excluded:
            false
        }
    }
}
