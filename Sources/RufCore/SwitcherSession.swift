public struct SwitcherSession: Equatable, Sendable {
    /// The grid every presentation of this session lays out and navigates.
    public private(set) var navigation = GridNavigation(itemCount: 0)
    public private(set) var selectedIndex: Int?
    public private(set) var showsApplicationResourceUsage = false

    public init() {}

    public var itemCount: Int {
        navigation.itemCount
    }

    public var isPresented: Bool {
        selectedIndex != nil
    }

    /// Starts a session whose first selection skips `currentGroup`, the
    /// group the user is switching away from. That group can have no target,
    /// for example when Ruf itself is frontmost; the selection then starts at
    /// the first initial target, or the last one going backwards.
    public mutating func begin<Group: Equatable>(
        groupIdentifiers: [Group],
        currentGroup: Group?,
        initialSelectionTargetCount: Int? = nil,
        maximumRowCount: Int = .max,
        backwards: Bool,
        showsApplicationResourceUsage: Bool = false
    ) {
        guard !groupIdentifiers.isEmpty else {
            clear()
            return
        }

        navigation = GridNavigation(
            itemCount: groupIdentifiers.count,
            maximumRowCount: maximumRowCount
        )
        self.showsApplicationResourceUsage =
            showsApplicationResourceUsage
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

    public mutating func toggleApplicationResourceUsage() -> Bool {
        guard isPresented else {
            return showsApplicationResourceUsage
        }

        showsApplicationResourceUsage.toggle()
        return showsApplicationResourceUsage
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
        navigation = GridNavigation(itemCount: 0)
        selectedIndex = nil
        showsApplicationResourceUsage = false
    }
}
