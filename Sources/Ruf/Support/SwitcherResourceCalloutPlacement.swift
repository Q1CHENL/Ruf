import CoreGraphics
import RufCore

enum SwitcherResourceCalloutMetrics {
    static let size = CGSize(width: 220, height: 28)
    static let gap: CGFloat = 4
}

struct SwitcherResourceCalloutPlacement: Equatable {
    let frame: CGRect

    static func resolve(
        selectedIndex: Int,
        itemCount: Int,
        panelFrame: CGRect,
        visibleFrame: CGRect
    ) -> Self? {
        guard let cellFrame = cellFrame(
            selectedIndex: selectedIndex,
            itemCount: itemCount,
            panelFrame: panelFrame
        ), visibleFrame.width >= SwitcherResourceCalloutMetrics.size.width,
           visibleFrame.height >= SwitcherResourceCalloutMetrics.size.height
        else {
            return nil
        }

        let size = SwitcherResourceCalloutMetrics.size
        let origin = CGPoint(
            x: clampedOrigin(
                cellFrame.midX - size.width / 2,
                length: size.width,
                within: visibleFrame.minX...visibleFrame.maxX
            ),
            y: clampedOrigin(
                cellFrame.maxY + SwitcherResourceCalloutMetrics.gap,
                length: size.height,
                within: visibleFrame.minY...visibleFrame.maxY
            )
        )
        return Self(frame: CGRect(origin: origin, size: size))
    }

    static func cellFrame(
        selectedIndex: Int,
        itemCount: Int,
        panelFrame: CGRect
    ) -> CGRect? {
        let navigation = GridNavigation(itemCount: itemCount)
        guard (0..<itemCount).contains(selectedIndex),
              navigation.columnCount > 0 else {
            return nil
        }

        let row = selectedIndex / navigation.columnCount
        let indices = navigation.indices(inRow: row)
        guard indices.contains(selectedIndex) else {
            return nil
        }
        let position = selectedIndex - indices.lowerBound

        let rowWidth = CGFloat(indices.count) * SwitcherMetrics.cellSize.width
            + CGFloat(max(0, indices.count - 1))
                * SwitcherMetrics.horizontalSpacing
        let originX = panelFrame.midX - rowWidth / 2
            + CGFloat(position)
                * (
                    SwitcherMetrics.cellSize.width
                        + SwitcherMetrics.horizontalSpacing
                )
        let maximumY = panelFrame.maxY
            - SwitcherMetrics.containerInset
            - CGFloat(row)
                * (
                    SwitcherMetrics.cellSize.height
                        + SwitcherMetrics.verticalSpacing
                )

        return CGRect(
            x: originX,
            y: maximumY - SwitcherMetrics.cellSize.height,
            width: SwitcherMetrics.cellSize.width,
            height: SwitcherMetrics.cellSize.height
        )
    }

    private static func clampedOrigin(
        _ origin: CGFloat,
        length: CGFloat,
        within range: ClosedRange<CGFloat>
    ) -> CGFloat {
        min(
            max(origin, range.lowerBound),
            range.upperBound - length
        )
    }
}
