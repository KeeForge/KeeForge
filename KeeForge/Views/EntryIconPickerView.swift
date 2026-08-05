import SwiftUI

/// Lets the user pick the icon an entry displays: one of the standard KDBX
/// icons, or one of the images the database carries in `Meta/CustomIcons`.
///
/// Two sections rather than one grid, the way KeePass's own chooser splits them
/// — the standard set is the same in every database, the custom one is whatever
/// this file happens to contain, and the choice between them is what the format
/// stores. The custom section is absent when the database defines no icons, so
/// an empty grid never has to explain itself.
///
/// Reports the selection through `onSelect` and dismisses; the caller applies
/// and saves it. Cancelling writes nothing.
struct EntryIconPickerView: View {
    let entryTitle: String
    let selection: EntryIconSelection
    let customIcons: [DatabaseViewModel.CustomIcon]
    let onSelect: (EntryIconSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Opens at `.large` so most of the grid is visible at once; the sheet can
    /// still be pulled down to `.medium`. Needs the `selection:` form of
    /// `presentationDetents` — the plain one takes an unordered `Set` and always
    /// starts at the smallest detent.
    @State private var detent: PresentationDetent = .large

    /// The standard indices in ascending order. Driven off the same table the
    /// rest of the app renders from, so the picker can never offer an index that
    /// has no glyph.
    private static let standardIconIDs = KPEntry.standardIconNames.keys.sorted()

    /// 52pt cells clear the 44pt minimum tap target, so the grid fits as many
    /// columns as the sheet allows without any of them getting too small to hit.
    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 12)]

    /// Scroll target of the icon in use, so the sheet opens on the current
    /// choice instead of at the top of a grid it may sit far down in.
    private var selectedCellID: String {
        switch selection {
        case .standard(let iconID): Self.cellID(standard: iconID)
        case .custom(let uuid): Self.cellID(custom: uuid)
        }
    }

    private static func cellID(standard iconID: Int) -> String { "standard.\(iconID)" }
    private static func cellID(custom uuid: UUID) -> String { "custom.\(uuid.uuidString)" }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if customIcons.isEmpty == false {
                            section(title: String(localized: "Custom Icons")) {
                                ForEach(customIcons) { icon in
                                    customIconButton(for: icon)
                                }
                            }
                        }

                        section(title: String(localized: "Standard Icons")) {
                            ForEach(Self.standardIconIDs, id: \.self) { iconID in
                                standardIconButton(for: iconID)
                            }
                        }
                    }
                    .padding()
                }
                .onAppear {
                    // Deferred a runloop pass on purpose: the grid is lazy, so
                    // during `onAppear` the target cell usually does not exist
                    // yet and `scrollTo` has nothing to scroll to.
                    Task { @MainActor in
                        proxy.scrollTo(selectedCellID, anchor: .center)
                    }
                }
            }
            .navigationTitle(entryTitle.isEmpty ? String(localized: "Entry Icon") : entryTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("entry-icon-picker.cancel")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private func section<Cells: View>(
        title: String,
        @ViewBuilder cells: () -> Cells
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                cells()
            }
        }
    }

    private func standardIconButton(for iconID: Int) -> some View {
        let isSelected = selection == .standard(iconID: iconID)
        return iconCell(isSelected: isSelected) {
            onSelect(.standard(iconID: iconID))
        } content: {
            Image(systemName: KPEntry.systemIconName(for: iconID))
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .id(Self.cellID(standard: iconID))
        .accessibilityIdentifier("entry-icon-picker.standard.\(iconID)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Skips an icon whose bytes no image loader accepts rather than showing an
    /// empty cell: `Meta/CustomIcons` holds whatever the writing client put
    /// there, and an entry pointed at something unrenderable would look the same
    /// as one pointed at nothing.
    @ViewBuilder
    private func customIconButton(for icon: DatabaseViewModel.CustomIcon) -> some View {
        if let image = PlatformImage(data: icon.data) {
            let isSelected = selection == .custom(uuid: icon.id)
            iconCell(isSelected: isSelected) {
                onSelect(.custom(uuid: icon.id))
            } content: {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .id(Self.cellID(custom: icon.id))
            .accessibilityIdentifier("entry-icon-picker.custom.\(icon.id.uuidString)")
            .accessibilityLabel("Custom icon")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }

    private func iconCell<Content: View>(
        isSelected: Bool,
        select: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            select()
            dismiss()
        } label: {
            content()
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}
