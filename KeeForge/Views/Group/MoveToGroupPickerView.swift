import SwiftUI

/// Lets the user pick which group an entry or group moves into: the group
/// tree flattened with indentation, the same presentation as the TOTP
/// enrollment group picker. The row for the item's current parent is disabled
/// and checkmarked, so "where it already is" is visible rather than a hole.
///
/// Deliberately dumb: reports the chosen group through `onSelect` and
/// dismisses; the caller performs the mutation and save. Cancelling writes
/// nothing.
struct MoveToGroupPickerView: View {
    let options: [DatabaseViewModel.MoveDestinationOption]
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button {
                    onSelect(option.id)
                    dismiss()
                } label: {
                    HStack {
                        Label(option.name, systemImage: "folder")
                        if option.isCurrentParent {
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, CGFloat(option.depth) * 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(option.isCurrentParent)
                .accessibilityIdentifier("move-picker.group.\(option.id.uuidString)")
                .macHoverHighlight()
            }
            .navigationTitle("Move to Group")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("move-picker.cancel")
                }
            }
        }
        // Sized here rather than at each presentation: four surfaces raise this
        // picker, and a group tree needs room whichever one asked for it.
        .macSheetFrame(minWidth: 460, minHeight: 420)
    }
}
