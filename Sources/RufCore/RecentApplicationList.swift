public struct RecentApplicationList<Identifier: Hashable & Sendable>: Equatable, Sendable {
    public let limit: Int
    public private(set) var identifiers: [Identifier]

    public init(identifiers: [Identifier] = [], limit: Int = 64) {
        let resolvedLimit = max(0, limit)
        var seen: Set<Identifier> = []
        let uniqueIdentifiers = identifiers.filter {
            seen.insert($0).inserted
        }

        self.limit = resolvedLimit
        self.identifiers = Array(uniqueIdentifiers.prefix(resolvedLimit))
    }

    public mutating func record(_ identifier: Identifier) {
        guard limit > 0 else {
            identifiers = []
            return
        }

        identifiers.removeAll { $0 == identifier }
        identifiers.insert(identifier, at: 0)

        if identifiers.count > limit {
            identifiers.removeSubrange(limit...)
        }
    }
}
