#if os(iOS)
import SwiftUI

/// The Duplicate item every entry row's context menu offers, next to the copy
/// pair, over the shared `EntryRowActions` gate. It hands the prefilled New
/// Entry form back rather than presenting it: where a create form opens is a
/// property of the shell, not of the row.
struct EntryRowDuplicateAction: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel
    let onDuplicate: (EntryEditViewModel) -> Void

    var body: some View {
        let actions = EntryRowActions(entryID: entryID, session: viewModel)
        if actions.canDuplicate {
            Button("Duplicate") {
                guard let editor = actions.makeDuplicateEditor() else { return }
                onDuplicate(editor)
            }
            .accessibilityIdentifier(EntryRowActions.duplicateIdentifier)
        }
    }
}
#endif
