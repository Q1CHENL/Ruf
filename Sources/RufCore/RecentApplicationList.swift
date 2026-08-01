public struct RecentApplicationList: Equatable, Sendable {
    public let limit: Int
    public private(set) var identifiers: [String]

    public init(identifiers: [String] = [], limit: Int = 64) {
        let resolvedLimit = max(0, limit)
        var seen: Set<String> = []
        let uniqueIdentifiers = identifiers.filter {
            seen.insert($0).inserted
        }

        self.limit = resolvedLimit
        self.identifiers = Array(uniqueIdentifiers.prefix(resolvedLimit))
    }

    public mutating func record(_ identifier: String) {
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
