public struct SwitcherSession: Equatable, Sendable {
    public private(set) var itemCount = 0
    public private(set) var selectedIndex: Int?

    public init() {}

    public var isPresented: Bool {
        selectedIndex != nil
    }

    public var navigation: GridNavigation {
        GridNavigation(itemCount: itemCount)
    }

    public mutating func begin<Group: Equatable>(
        groupIdentifiers: [Group],
        initialSelectionTargetCount: Int? = nil,
        backwards: Bool
    ) {
        guard let currentGroup = groupIdentifiers.first else {
            clear()
            return
        }

        itemCount = groupIdentifiers.count
        let resolvedInitialTargetCount = min(
            max(initialSelectionTargetCount ?? itemCount, 0),
            itemCount
        )
        let initialTargetCount = max(1, resolvedInitialTargetCount)
        let initialGroupIdentifiers = groupIdentifiers.prefix(
            initialTargetCount
        )
        let differentGroupIndex = backwards
            ? initialGroupIdentifiers.lastIndex { $0 != currentGroup }
            : initialGroupIdentifiers.firstIndex { $0 != currentGroup }
        let fallbackMove: GridMove = backwards ? .backward : .forward
        let initialNavigation = GridNavigation(itemCount: initialTargetCount)

        selectedIndex = differentGroupIndex
            ?? initialNavigation.moving(from: 0, fallbackMove)
    }

    public mutating func move(_ move: GridMove) {
        guard
            let selectedIndex,
            let nextIndex = navigation.moving(from: selectedIndex, move)
        else {
            return
        }

        self.selectedIndex = nextIndex
    }

    public mutating func select(_ index: Int) {
        guard (0..<itemCount).contains(index) else {
            return
        }

        selectedIndex = index
    }

    @discardableResult
    public mutating func finish() -> Int? {
        let index = selectedIndex
        clear()
        return index
    }

    public mutating func cancel() {
        clear()
    }

    private mutating func clear() {
        itemCount = 0
        selectedIndex = nil
    }
}
