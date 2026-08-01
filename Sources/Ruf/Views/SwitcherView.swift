import SwiftUI
import RufCore

enum SwitcherMetrics {
    static let cellSize = CGSize(width: 84, height: 78)
    static let iconSize: CGFloat = 52
    static let iconPlateSize: CGFloat = 42
    static let iconCornerRadius: CGFloat = 10
    static let selectionRingWidth: CGFloat = 3
    static let selectionRingSize = iconPlateSize + 2 * selectionRingWidth
    static let selectionRingCornerRadius = iconCornerRadius + selectionRingWidth
    static let horizontalSpacing: CGFloat = 4
    static let verticalSpacing: CGFloat = 4
    static let containerInset: CGFloat = 12
    static let cornerRadius: CGFloat = 22

    static func panelSize(itemCount: Int) -> CGSize {
        let navigation = GridNavigation(itemCount: itemCount)
        let columns = max(1, navigation.columnCount)
        let rows = max(1, navigation.rowCount)

        let gridWidth = CGFloat(columns) * cellSize.width
            + CGFloat(columns - 1) * horizontalSpacing
        let gridHeight = CGFloat(rows) * cellSize.height
            + CGFloat(rows - 1) * verticalSpacing

        return CGSize(
            width: gridWidth + 2 * containerInset,
            height: gridHeight + 2 * containerInset
        )
    }
}

struct SwitcherView: View {
    let model: SwitcherModel
    let onChoose: (Int) -> Void

    var body: some View {
        let selectedIndex = model.selectedIndex
        let navigation = model.navigation

        VStack(spacing: SwitcherMetrics.verticalSpacing) {
            ForEach(0..<navigation.rowCount, id: \.self) { row in
                HStack(spacing: SwitcherMetrics.horizontalSpacing) {
                    ForEach(navigation.indices(inRow: row), id: \.self) { index in
                        let item = model.applications[index]
                        ApplicationCell(
                            item: item,
                            isSelected: selectedIndex == index,
                            onChoose: { onChoose(index) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(SwitcherMetrics.containerInset)
        .animation(.easeOut(duration: 0.08), value: model.selectedIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ruf app grid")
    }
}

private struct ApplicationCell: View {
    let item: ApplicationItem
    let isSelected: Bool
    let onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: 3) {
                Image(nsImage: item.icon)
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
                                    .black.opacity(0.55),
                                    lineWidth: SwitcherMetrics.selectionRingWidth
                                )
                                .frame(
                                    width: SwitcherMetrics.selectionRingSize,
                                    height: SwitcherMetrics.selectionRingSize
                                )
                        }
                    }

                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.primary.opacity(0.75))
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(width: SwitcherMetrics.cellSize.width, height: SwitcherMetrics.cellSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
