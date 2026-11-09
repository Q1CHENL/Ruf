/// Where the WindowServer places a window Accessibility reported.
public enum WindowServerVisibility: Equatable, Sendable {
    case onScreen
    /// Ordered out, on another Space, or an Accessibility element the
    /// WindowServer no longer shows.
    case offScreen
    /// The window could not be matched to a WindowServer window.
    case unknown
}

public struct WindowQueryPlan: Equatable, Sendable {
    private let visibleWindowIdentifiers: [Int32: Set<UInt32>]
    private let windowOwnerProcessIdentifiers: Set<Int32>

    public init(
        visibleWindowIdentifiers: [Int32: Set<UInt32>],
        windowOwnerProcessIdentifiers: Set<Int32>
    ) {
        self.visibleWindowIdentifiers = visibleWindowIdentifiers
        self.windowOwnerProcessIdentifiers = windowOwnerProcessIdentifiers
    }

    public func hasWindows(for processIdentifier: Int32) -> Bool {
        windowOwnerProcessIdentifiers.contains(processIdentifier)
    }

    public func visibility(
        ofWindow identifier: UInt32?,
        ownedBy processIdentifier: Int32
    ) -> WindowServerVisibility {
        guard let identifier else {
            return .unknown
        }

        return visibleWindowIdentifiers[processIdentifier]?.contains(identifier) == true
            ? .onScreen
            : .offScreen
    }

    public func hasVisibleWindows(for processIdentifier: Int32) -> Bool {
        visibleWindowIdentifiers[processIdentifier]?.isEmpty == false
    }
}
