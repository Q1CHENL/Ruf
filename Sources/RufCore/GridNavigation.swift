public enum GridMove: Equatable, Sendable {
    case forward
    case backward
    case left
    case right
    case up
    case down
}

public struct GridNavigation: Sendable {
    public let itemCount: Int

    public init(itemCount: Int) {
        self.itemCount = max(0, itemCount)
    }

    public var columnCount: Int {
        guard itemCount > 0 else {
            return 0
        }

        var columns = 1
        while columns * columns < itemCount {
            columns += 1
        }
        return columns
    }

    public var rowCount: Int {
        guard columnCount > 0 else {
            return 0
        }

        return (itemCount + columnCount - 1) / columnCount
    }

    public func indices(inRow row: Int) -> Range<Int> {
        guard columnCount > 0, (0..<rowCount).contains(row) else {
            return 0..<0
        }

        let startIndex = row * columnCount
        return startIndex..<min(startIndex + columnCount, itemCount)
    }

    public func moving(from index: Int, _ move: GridMove) -> Int? {
        guard itemCount > 0, (0..<itemCount).contains(index) else {
            return nil
        }

        switch move {
        case .forward:
            return (index + 1) % itemCount
        case .backward:
            return (index - 1 + itemCount) % itemCount
        case .left:
            return index % columnCount > 0 ? index - 1 : index
        case .right:
            let hasNextColumn = index % columnCount + 1 < columnCount
            return hasNextColumn && index + 1 < itemCount ? index + 1 : index
        case .up:
            return movingVertically(from: index, rowOffset: -1)
        case .down:
            return movingVertically(from: index, rowOffset: 1)
        }
    }

    private func movingVertically(from index: Int, rowOffset: Int) -> Int {
        let targetRow = index / columnCount + rowOffset
        let targetIndices = indices(inRow: targetRow)
        guard !targetIndices.isEmpty else {
            return index
        }

        let sourcePosition = horizontalPosition(of: index)
        return targetIndices.min { leftIndex, rightIndex in
            let leftDistance = abs(horizontalPosition(of: leftIndex) - sourcePosition)
            let rightDistance = abs(horizontalPosition(of: rightIndex) - sourcePosition)

            if leftDistance == rightDistance {
                return leftIndex < rightIndex
            }
            return leftDistance < rightDistance
        } ?? index
    }

    private func horizontalPosition(of index: Int) -> Int {
        let rowIndices = indices(inRow: index / columnCount)
        let positionInRow = index - rowIndices.lowerBound

        // Doubling the position keeps half-column offsets exact when a centered
        // partial row has an odd number of missing items.
        return columnCount - rowIndices.count + 2 * positionInRow
    }
}
