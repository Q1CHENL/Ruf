public struct WindowQueryPlan: Equatable, Sendable {
    public let multipleWindowCandidates: [Int32]
    public let reopenCandidates: [Int32]

    public init(
        processIdentifiers: [Int32],
        visibleWindowCounts: [Int32: Int]
    ) {
        multipleWindowCandidates = processIdentifiers.filter {
            visibleWindowCounts[$0, default: 0] > 1
        }
        reopenCandidates = processIdentifiers.filter {
            visibleWindowCounts[$0, default: 0] == 0
        }
    }
}
