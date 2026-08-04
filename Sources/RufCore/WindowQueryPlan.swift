public struct WindowQueryPlan: Equatable, Sendable {
    public let multipleWindowCandidates: [Int32]
    public let reopenCandidates: [Int32]
    private let visibleWindowIdentifiers: [Int32: Set<UInt32>]

    public init(
        processIdentifiers: [Int32],
        visibleWindowIdentifiers: [Int32: Set<UInt32>]
    ) {
        self.visibleWindowIdentifiers = visibleWindowIdentifiers
        multipleWindowCandidates = processIdentifiers.filter {
            visibleWindowIdentifiers[$0, default: []].count > 1
        }
        reopenCandidates = processIdentifiers.filter {
            visibleWindowIdentifiers[$0, default: []].isEmpty
        }
    }

    public func containsVisibleWindow(
        identifier: UInt32,
        processIdentifier: Int32
    ) -> Bool {
        visibleWindowIdentifiers[processIdentifier]?.contains(identifier) == true
    }
}
