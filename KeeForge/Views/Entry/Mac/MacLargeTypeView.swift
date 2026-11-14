#if os(macOS)
import SwiftUI

/// The Large Type panel's content (EntryVariants board): "Title · Password · 19 characters", Close,
/// one 60 × 86 tile per character with its 1-based position, and the colour legend.
struct MacLargeTypeView: View {
    let model: LargeTypeModel
    let onClose: () -> Void

    private var columns: [GridItem] {
        let count = max(1, min(MacLargeTypePanelController.columnCount, model.characterCount))
        return Array(repeating: GridItem(.fixed(MacLargeTypePanelController.tileSize.width),
                                         spacing: MacLargeTypePanelController.tileSpacing), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 22)
                .padding(.bottom, 12)
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: MacLargeTypePanelController.tileSpacing) {
                    ForEach(model.tiles) { tile in
                        MacLargeTypeTile(tile: tile)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            legend
                .frame(height: 14)
                .padding(.top, 14)
        }
        .padding(.top, 16)
        .padding(.bottom, 18)
        .padding(.horizontal, MacLargeTypePanelController.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(MacDetailPalette.column))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: "· \(model.fieldName) · \(String(localized: "\(model.characterCount) characters"))")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.quaternary))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close Large Type"))
            .macHelp(String(localized: "Close Large Type"))
            .accessibilityIdentifier("large-type.close")
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Text("Letters")
            Text("Digits")
                .fontWeight(.semibold)
                .foregroundStyle(MacLargeTypeTile.digitColor)
            Text("Symbols")
                .fontWeight(.semibold)
                .foregroundStyle(MacLargeTypeTile.symbolColor)
            Spacer(minLength: 8)
            Text("Press Esc or click anywhere to close.")
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// One character and its position; every other tile has a tinted ground.
private struct MacLargeTypeTile: View {
    static let digitColor = Color.blue
    static let symbolColor = Color.orange

    let tile: LargeTypeModel.Tile

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: tile.kind == .space ? "\u{2423}" : tile.character)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(verbatim: String(tile.position))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: MacLargeTypePanelController.tileSize.width, height: MacLargeTypePanelController.tileSize.height)
        .background {
            if tile.position.isMultiple(of: 2) {
                RoundedRectangle(cornerRadius: 8).fill(.quinary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tile.kind {
        case .letter: .primary
        case .digit: Self.digitColor
        case .symbol: Self.symbolColor
        case .space: Color(nsColor: .tertiaryLabelColor)
        }
    }
}
#endif
