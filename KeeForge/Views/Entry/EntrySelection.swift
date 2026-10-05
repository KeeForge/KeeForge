import SwiftUI

// Selection mode for the entry lists: the context-menu item that starts it, the
// row it turns an entry into, and the bar that ends it or moves what was
// picked. Shared for the reason the other row actions are: the three shells
// must not drift in wording, gating, or identifiers. The selection itself
// lives in `DatabaseWorkspaceState.entrySelection`.

/// The Select Entries item every entry row's context menu offers, after Move
/// to Group. It starts selection mode with this entry picked, behind Move to
/// Group's gate: moving is what a selection is for.
struct EntryRowSelectAction: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel

    var body: some View {
        if EntryRowMoveAction.isAvailable(entryID: entryID, viewModel: viewModel) {
            Button("Select Entries") {
                viewModel.workspace.beginEntrySelection(with: entryID)
            }
            .accessibilityIdentifier("entry-row.select-context")
        }
    }
}

struct EntrySelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
    }
}

/// An entry row while its list is in selection mode: a tap picks the entry
/// instead of opening it, and the row offers no other action. An entry that
/// cannot be moved stays visible but takes no taps.
struct EntrySelectionRow<Row: View>: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel
    /// The identifier the row carries outside selection mode.
    let identifier: String
    @ViewBuilder let row: Row

    var body: some View {
        let isSelectable = EntryRowMoveAction.isAvailable(entryID: entryID, viewModel: viewModel)
        let isSelected = viewModel.workspace.entrySelection?.contains(entryID) == true
        Button {
            viewModel.workspace.toggleEntrySelection(entryID)
        } label: {
            HStack(spacing: 12) {
                EntrySelectionIndicator(isSelected: isSelected)
                    .opacity(isSelectable ? 1 : 0)
                row
            }
        }
        .buttonStyle(.plain)
        .disabled(isSelectable == false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// What a list shows along its bottom edge in selection mode: how many entries
/// are picked, the way out, and Move to Group. It hands the move back rather
/// than presenting the picker, because each shell hosts that sheet itself.
struct EntrySelectionBar: View {
    let viewModel: DatabaseViewModel
    let onMove: (PendingMove) -> Void

    var body: some View {
        if let selection = viewModel.workspace.entrySelection {
            VStack(spacing: 0) {
                Divider()
                // The sidebar and content columns get narrow enough that a
                // long translation of the two buttons leaves the count no room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        cancelButton
                        Spacer(minLength: 8)
                        countLabel(for: selection)
                        Spacer(minLength: 8)
                        moveButton(for: selection)
                    }
                    VStack(spacing: 6) {
                        countLabel(for: selection)
                        HStack {
                            cancelButton
                            Spacer(minLength: 8)
                            moveButton(for: selection)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            viewModel.workspace.endEntrySelection()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("entry-selection.cancel")
    }

    private func countLabel(for selection: Set<UUID>) -> some View {
        Text(selection.isEmpty ? String(localized: "Select Entries") : String(localized: "\(selection.count) entries"))
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .accessibilityIdentifier("entry-selection.count")
    }

    private func moveButton(for selection: Set<UUID>) -> some View {
        Button("Move to Group") {
            onMove(.entries(selection))
        }
        .fontWeight(.semibold)
        .disabled(selection.isEmpty)
        .accessibilityIdentifier("entry-selection.move")
    }
}

extension View {
    /// Hosts the selection bar on a screen that lists entries.
    func entrySelectionBar(viewModel: DatabaseViewModel, onMove: @escaping (PendingMove) -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            EntrySelectionBar(viewModel: viewModel, onMove: onMove)
        }
    }
}

/// Hosts a list's own selection bar, and nothing when the list renders inline
/// inside a screen that already shows one — the split `ListScopedDeletionAlert`
/// makes for the delete confirmation, so one screen never stacks two bars.
struct ListScopedSelectionBar: ViewModifier {
    let viewModel: DatabaseViewModel
    let isHosted: Bool
    let onMove: (PendingMove) -> Void

    func body(content: Content) -> some View {
        if isHosted {
            content.entrySelectionBar(viewModel: viewModel, onMove: onMove)
        } else {
            content
        }
    }
}
