import Foundation

/// One running process of an application the switcher may offer.
public struct ApplicationInstance<Item> {
    public let item: Item
    /// Shared by every instance of the application. Recency and the
    /// switcher's grouping are kept per application, not per process.
    public let applicationIdentifier: String
    public let name: String
    public let processIdentifier: Int32
    public let policy: ApplicationDiscoveryPolicy

    public init(
        item: Item,
        applicationIdentifier: String,
        name: String,
        processIdentifier: Int32,
        policy: ApplicationDiscoveryPolicy
    ) {
        self.item = item
        self.applicationIdentifier = applicationIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
        self.policy = policy
    }
}

/// What the switcher offers for one instance.
public struct ApplicationOffer<Item, Window> {
    public let item: Item
    public let resolution: ApplicationWindowResolution<Window>

    public init(
        item: Item,
        resolution: ApplicationWindowResolution<Window>
    ) {
        self.item = item
        self.resolution = resolution
    }
}

extension ApplicationOffer: Equatable where Item: Equatable, Window: Equatable {}

public enum ApplicationTargetPlan {
    /// Orders applications by recency, then name, and keeps each
    /// application's instances together, the most recently active first and
    /// otherwise the oldest first.
    public static func ordered<Item>(
        _ instances: [ApplicationInstance<Item>],
        recentApplicationIdentifiers: [String],
        recentProcessIdentifiers: [Int32]
    ) -> [ApplicationInstance<Item>] {
        let applicationRanks = ranks(of: recentApplicationIdentifiers)
        let processRanks = ranks(of: recentProcessIdentifiers)
        let applications = Dictionary(
            grouping: instances,
            by: \.applicationIdentifier
        ).values.map { instances in
            instances.sorted { left, right in
                (
                    processRanks[left.processIdentifier] ?? .max,
                    left.processIdentifier
                ) < (
                    processRanks[right.processIdentifier] ?? .max,
                    right.processIdentifier
                )
            }
        }

        return applications.sorted { left, right in
            let leftRank = applicationRanks[left[0].applicationIdentifier] ?? .max
            let rightRank = applicationRanks[right[0].applicationIdentifier] ?? .max
            if leftRank != rightRank {
                return leftRank < rightRank
            }

            switch left[0].name.localizedStandardCompare(right[0].name) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return left[0].applicationIdentifier
                    < right[0].applicationIdentifier
            }
        }.flatMap { $0 }
    }

    /// Decides what each instance offers, keeping the order of `instances`.
    /// An instance whose windows were never resolved is offered as a whole.
    public static func offers<Item, Window>(
        for instances: [ApplicationInstance<Item>],
        resolutions: [Int32: ApplicationWindowResolution<Window>]
    ) -> [ApplicationOffer<Item, Window>] {
        var applicationIdentifiers: [String] = []
        var instancesByApplication: [String: [ApplicationInstance<Item>]] = [:]
        for instance in instances {
            if instancesByApplication[instance.applicationIdentifier] == nil {
                applicationIdentifiers.append(instance.applicationIdentifier)
            }
            instancesByApplication[instance.applicationIdentifier, default: []]
                .append(instance)
        }

        return applicationIdentifiers.flatMap { applicationIdentifier in
            offers(
                forInstancesOf: instancesByApplication[applicationIdentifier] ?? [],
                resolutions: resolutions
            )
        }
    }

    private static func offers<Item, Window>(
        forInstancesOf instances: [ApplicationInstance<Item>],
        resolutions: [Int32: ApplicationWindowResolution<Window>]
    ) -> [ApplicationOffer<Item, Window>] {
        let offers = instances.compactMap { instance -> ApplicationOffer<Item, Window>? in
            let resolution = resolutions[instance.processIdentifier] ?? .application
            guard instance.policy.shouldInclude(
                hasSwitchableWindows: resolution.hasSwitchableWindows
            ) else {
                return nil
            }

            return ApplicationOffer(item: instance.item, resolution: resolution)
        }

        // Reopening addresses the application, not one of its processes, so
        // it is offered once, and only while no instance may have a window.
        let reachableOffers = offers.filter {
            if case .windowless = $0.resolution { false } else { true }
        }
        guard !reachableOffers.isEmpty else {
            return Array(offers.prefix(1))
        }

        // Several tiles of one application are told apart by window title,
        // which a lone window offered as the application does not show.
        let targetCount = reachableOffers.reduce(0) { count, offer in
            if case let .windows(windows) = offer.resolution {
                count + windows.count
            } else {
                count + 1
            }
        }
        guard targetCount > 1 else {
            return reachableOffers
        }

        return reachableOffers.map { offer in
            guard case let .singleWindow(window) = offer.resolution else {
                return offer
            }

            return ApplicationOffer(item: offer.item, resolution: .windows([window]))
        }
    }

    private static func ranks<Identifier: Hashable>(
        of identifiers: [Identifier]
    ) -> [Identifier: Int] {
        Dictionary(
            identifiers.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
