import SwiftUI

/// The Move to Group item every entry row's context menu offers, after
/// Duplicate. Shared so the wording, the gating, and the accessibility
/// identifier cannot drift per shell.
///
/// It hands the pending move back rather than presenting the picker: where the
/// move sheet is hosted — on the list itself, or raised to the macOS
/// workspace — is a property of the shell, not of the row.
struct EntryRowMoveAction: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel
    let onMove: (PendingMove) -> Void

    var body: some View {
        if Self.isAvailable(entryID: entryID, viewModel: viewModel) {
            Button("Move to Group") {
                onMove(.entry(entryID))
            }
            .accessibilityIdentifier("entry-row.move-context")
        }
    }

    /// Moving is an edit, so the database has to accept one; and an entry in
    /// the recycle bin comes back through the restore flow, not through a move.
    @MainActor
    static func isAvailable(entryID: UUID, viewModel: DatabaseViewModel) -> Bool {
        viewModel.isReadOnly == false
            && viewModel.isEntryInRecycleBin(entryID: entryID) == false
    }
}
