import SwiftUI
import RufCore

enum SwitcherMetrics {
    // Labels span the cell width, and the bottom row's label padding forms
    // the panel's edge inset.
    static let cellSize = CGSize(width: 78, height: 77)
    static let iconSize: CGFloat = 52
    static let iconPlateSize: CGFloat = 42
    static let iconCornerRadius: CGFloat = 10
    static let selectionRingWidth: CGFloat = 3
    static let selectionRingSize = iconPlateSize + 2 * selectionRingWidth
    static let selectionRingCornerRadius = iconCornerRadius + selectionRingWidth
    static let indicatorBadgeSize: CGFloat = 15
    static let dockBadgeHeight: CGFloat = 15
    static let dockBadgeDotSize: CGFloat = 9
    static let labelSpacing: CGFloat = 3
    static let labelHeight: CGFloat = 14
    /// Distance between neighboring cells in both directions, which leaves
    /// the same gap between neighboring icon plates horizontally and
    /// vertically.
    static let gridPitch: CGFloat = 82
    static let horizontalSpacing = gridPitch - cellSize.width
    static let verticalSpacing = gridPitch - cellSize.height
    static let cornerRadius: CGFloat = 22

    // The icon and label are centered in each cell; the icon art draws a
    // smaller plate centered in its frame.
    private static let plateTopInCell =
        (cellSize.height - iconSize - labelSpacing - labelHeight) / 2
        + (iconSize - iconPlateSize) / 2
    private static let plateSideInCell = (cellSize.width - iconPlateSize) / 2

    /// Visible gap between the outer icon plates and every panel edge. The
    /// bottom row's cell ends at the panel edge so its label stays inside;
    /// the top and side insets match the resulting plate gap.
    private static let plateEdgeInset =
        cellSize.height - plateTopInCell - iconPlateSize
    static let topInset = plateEdgeInset - plateTopInCell
    static let horizontalInset = plateEdgeInset - plateSideInCell

    /// The most rows whose panel fits within `height`, at least one.
    static func maximumRowCount(fittingHeight height: CGFloat) -> Int {
        // A panel of n rows is n pitches tall, less the spacing below the
        // last row, plus the top inset.
        let rows = (height + verticalSpacing - topInset) / gridPitch
        guard rows.isFinite else {
            return .max
        }

        return max(1, Int(rows.rounded(.down)))
    }

    static func panelSize(for navigation: GridNavigation) -> CGSize {
        let columns = max(1, navigation.columnCount)
        let rows = max(1, navigation.rowCount)

        let gridWidth = CGFloat(columns) * cellSize.width
            + CGFloat(columns - 1) * horizontalSpacing
        let gridHeight = CGFloat(rows) * cellSize.height
            + CGFloat(rows - 1) * verticalSpacing

        return CGSize(
            width: gridWidth + 2 * horizontalInset,
            height: gridHeight + topInset
        )
    }
}

struct SwitcherView: View {
    let model: SwitcherModel
    let onChoose: (Int) -> Void

    var body: some View {
        // Derive indices from the same snapshot captured by the row closures.
        let targets = model.targets
        let selectedIndex = model.selectedIndex
        let navigation = model.navigation

        VStack(spacing: SwitcherMetrics.verticalSpacing) {
            ForEach(0..<navigation.rowCount, id: \.self) { row in
                HStack(spacing: SwitcherMetrics.horizontalSpacing) {
                    ForEach(navigation.indices(inRow: row), id: \.self) { index in
                        let target = targets[index]
                        SwitchTargetCell(
                            target: target,
                            isSelected: selectedIndex == index,
                            onChoose: { onChoose(index) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, SwitcherMetrics.topInset)
        .padding(.horizontal, SwitcherMetrics.horizontalInset)
        .animation(.easeOut(duration: 0.08), value: model.selectedIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ruf app and window grid")
    }
}

private struct SwitchTargetCell: View {
    let target: SwitchTarget
    let isSelected: Bool
    let onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: SwitcherMetrics.labelSpacing) {
                Image(nsImage: target.item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: SwitcherMetrics.iconSize, height: SwitcherMetrics.iconSize)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(
                                cornerRadius: SwitcherMetrics.selectionRingCornerRadius,
                                style: .continuous
                            )
                                .strokeBorder(
                                    Color.primary.opacity(0.55),
                                    lineWidth: SwitcherMetrics.selectionRingWidth
                                )
                                .frame(
                                    width: SwitcherMetrics.selectionRingSize,
                                    height: SwitcherMetrics.selectionRingSize
                                )
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if target.showsReopenBadge {
                            ZStack {
                                Circle()
                                    .fill(Color(nsColor: .systemBlue))

                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(
                                width: SwitcherMetrics.indicatorBadgeSize,
                                height: SwitcherMetrics.indicatorBadgeSize
                            )
                            .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if target.showsSoftwareUpdateIndicator {
                            ZStack {
                                Circle()
                                    .fill(Color(nsColor: .systemGreen))

                                Image(systemName: "arrow.up")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(
                                width: SwitcherMetrics.indicatorBadgeSize,
                                height: SwitcherMetrics.indicatorBadgeSize
                            )
                            .accessibilityHidden(true)
                        } else if let dockBadge = target.dockBadge {
                            DockBadgeView(badge: dockBadge)
                        }
                    }

                SwitchTargetLabel(
                    title: target.title,
                    isWindowTitle: target.showsWindowTitle,
                    isSelected: isSelected
                )
            }
            .frame(width: SwitcherMetrics.cellSize.width, height: SwitcherMetrics.cellSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
        .accessibilityLabel(target.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct DockBadgeView: View {
    let badge: DockBadge

    var body: some View {
        Group {
            if let displayText = badge.displayText {
                Text(displayText)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(
                        minWidth: SwitcherMetrics.dockBadgeHeight,
                        minHeight: SwitcherMetrics.dockBadgeHeight
                    )
                    .background {
                        Capsule()
                            .fill(Color(nsColor: .systemRed))
                    }
            } else {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(
                        width: SwitcherMetrics.dockBadgeDotSize,
                        height: SwitcherMetrics.dockBadgeDotSize
                    )
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        .accessibilityHidden(true)
    }
}

private struct SwitchTargetLabel: View {
    let title: String
    let isWindowTitle: Bool
    let isSelected: Bool

    var body: some View {
        // Labels stay within their cell so edge-column labels remain inside
        // the panel's narrow side insets.
        Text(title)
            .lineLimit(1)
            .truncationMode(isWindowTitle ? .middle : .tail)
            .frame(
                width: SwitcherMetrics.cellSize.width,
                height: SwitcherMetrics.labelHeight
            )
            .foregroundStyle(
                Color.primary.opacity(isSelected ? 0.75 : 0.35)
            )
            .opacity(isWindowTitle || isSelected ? 1 : 0)
            .font(.system(size: 11, weight: .medium))
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}
