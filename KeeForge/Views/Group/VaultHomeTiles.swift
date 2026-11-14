import SwiftUI

/// The vault root's tiles: All Entries, Verification Codes, Tags and the
/// Recycle Bin with their counts. Two columns, one at accessibility sizes.
struct VaultHomeTiles: View {
    let counts: DatabaseCollectionCounts
    var isInSidebar = false
    let open: (DatabaseCollection) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Theme.Spacing.tileGap, alignment: .top),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
        LazyVGrid(columns: columns, spacing: Theme.Spacing.tileGap) {
            ForEach(DatabaseCollection.vaultTiles, id: \.self) { collection in
                VaultHomeTile(collection: collection, count: counts[collection], isInSidebar: isInSidebar) {
                    open(collection)
                }
            }
        }
    }
}

private struct VaultHomeTile: View {
    let collection: DatabaseCollection
    let count: Int
    let isInSidebar: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var circleSize = Theme.Size.tileCircle

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tileGap) {
                HStack(alignment: .top) {
                    Image(systemName: symbolName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.tileGlyph)
                        .frame(width: circleSize, height: circleSize)
                        .background(circleColor, in: Circle())
                    Spacer(minLength: 0)
                    Text(count, format: .number)
                        .font(Theme.Font.tileCount)
                        .foregroundStyle(Theme.labelSecondary)
                }
                Spacer(minLength: 0)
                Text(collection.tileTitle)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Spacing.tile)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.tile, alignment: .leading)
            .background(isInSidebar ? Theme.cardRaised : Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collection.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home-tile.\(collection.rawValue)")
    }

    /// Outline glyphs, except the trash, which iOS fills in tiles.
    private var symbolName: String {
        collection == .recycleBin ? "trash.fill" : collection.systemImage
    }

    private var circleColor: AnyShapeStyle {
        switch collection {
        case .allEntries: AnyShapeStyle(.tint)
        case .verificationCodes, .passkeys: AnyShapeStyle(Theme.tileCodes)
        case .tags: AnyShapeStyle(Theme.tileTags)
        case .recycleBin: AnyShapeStyle(Theme.tileTrash)
        }
    }
}
