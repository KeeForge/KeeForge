import SwiftUI

/// Lets the user pick which of the standard KDBX icons a group displays.
///
/// An unlabeled grid, the way KeePass's own icon chooser presents them: the icon
/// set has no user-facing names in the format, and 69 invented captions would
/// dominate the sheet without describing the glyphs any better. Each cell instead
/// carries its index as an accessibility identifier so the UI suites can address a
/// specific icon.
///
/// Reports the chosen index through `onSelect` and dismisses; the caller applies and
/// saves it. Cancelling writes nothing.
struct GroupIconPickerView: View {
    let groupName: String
    let selectedIconID: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Opens at `.large` so most of the grid is visible at once; the sheet can still
    /// be pulled down to `.medium`. Needs the `selection:` form of
    /// `presentationDetents` — the plain one takes an unordered `Set` and always
    /// starts at the smallest detent.
    @State private var detent: PresentationDetent = .large

    /// The standard indices in ascending order. Driven off the same table the rest of
    /// the app renders from, so the picker can never offer an index that has no glyph.
    private static let iconIDs = KPEntry.standardIconNames.keys.sorted()

    /// 52pt cells clear the 44pt minimum tap target, so the grid fits as many columns
    /// as the sheet allows without any of them getting too small to hit.
    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Self.iconIDs, id: \.self) { iconID in
                            iconButton(for: iconID)
                                .id(iconID)
                        }
                    }
                    .padding()
                }
                .onAppear {
                    // Deferred a runloop pass on purpose: the grid is lazy, so during
                    // `onAppear` the target cell usually does not exist yet and
                    // `scrollTo` has nothing to scroll to.
                    Task { @MainActor in
                        proxy.scrollTo(selectedIconID, anchor: .center)
                    }
                }
            }
            .navigationTitle(groupName.isEmpty ? String(localized: "Group Icon") : groupName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("group-icon-picker.cancel")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .macSheetFrame(minWidth: 620, minHeight: 560)
    }

    private func iconButton(for iconID: Int) -> some View {
        let isSelected = iconID == selectedIconID
        return Button {
            onSelect(iconID)
            dismiss()
        } label: {
            Image(systemName: KPEntry.systemIconName(for: iconID, fallback: "folder.fill"))
                .font(.title3)
                .frame(width: 52, height: 52)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
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
        .accessibilityIdentifier("group-icon-picker.icon.\(iconID)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
