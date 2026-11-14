import SwiftUI

/// The Restore and Move to Group items every entry row's context menu offers,
/// after Duplicate, over the shared `EntryRowActions` gate. It hands the
/// pending move back rather than presenting the picker: where the move sheet
/// is hosted is a property of the shell, not of the row.
struct EntryRowMoveAction: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel
    let onMove: (PendingMove) -> Void

    var body: some View {
        let actions = EntryRowActions(entryID: entryID, session: viewModel)
        RestoreRowAction(item: .entry(entryID), viewModel: viewModel, onChooseDestination: onMove)
        if actions.canMove {
            Button("Move to Group") {
                onMove(actions.pendingMove)
            }
            .accessibilityIdentifier(EntryRowActions.moveIdentifier)
        }
    }
}
