public enum WindowQueryDisposition: Equatable, Sendable {
    case application
    case singleWindow
    case windowless
    case windows

    public static func resolve(
        hasSwitchableAXWindows: Bool,
        hasVisibleWindows: Bool,
        switchableWindowMinimizedStates: [Bool]
    ) -> Self {
        if switchableWindowMinimizedStates == [false] {
            return .singleWindow
        }

        if switchableWindowMinimizedStates.count > 1
            || switchableWindowMinimizedStates.contains(true) {
            return .windows
        }

        return hasSwitchableAXWindows || hasVisibleWindows
            ? .application
            : .windowless
    }
}

public struct WindowQueryPlan: Equatable, Sendable {
    public let windowQueryCandidates: [Int32]
    private let visibleWindowIdentifiers: [Int32: Set<UInt32>]

    public init(
        processIdentifiers: [Int32],
        visibleWindowIdentifiers: [Int32: Set<UInt32>]
    ) {
        self.visibleWindowIdentifiers = visibleWindowIdentifiers
        windowQueryCandidates = processIdentifiers
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
