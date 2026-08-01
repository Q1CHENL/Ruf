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

    public mutating func begin(itemCount: Int, backwards: Bool) {
        guard itemCount > 0 else {
            clear()
            return
        }

        self.itemCount = itemCount
        selectedIndex = itemCount == 1
            ? 0
            : backwards ? itemCount - 1 : 1
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
