import SwiftUI

/// The Duplicate item every entry row's context menu offers, next to the copy
/// pair. Shared so the wording, the gating, and the accessibility identifier
/// cannot drift per shell.
///
/// It builds the prefilled New Entry form and hands it back rather than
/// presenting it: where a create form opens — pushed, in the detail column, or
/// as a sheet — is a property of the shell, not of the row.
struct EntryRowDuplicateAction: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel
    let onDuplicate: (EntryEditViewModel) -> Void

    var body: some View {
        if isAvailable {
            Button("Duplicate") {
                guard let editor = makeEditor() else { return }
                onDuplicate(editor)
            }
            .accessibilityIdentifier("entry-row.duplicate-context")
        }
    }

    /// Same eligibility as Move to Group — copying is an edit, and an entry in
    /// the recycle bin comes back through the restore flow rather than being
    /// copied out of it — plus the session key the copy's secrets need.
    private var isAvailable: Bool {
        viewModel.isReadOnly == false
            && viewModel.sessionKey != nil
            && viewModel.isEntryInRecycleBin(entryID: entryID) == false
    }

    /// Built when the item is tapped rather than per render, so the copy is
    /// seeded from the entry as it stands at that moment.
    private func makeEditor() -> EntryEditViewModel? {
        guard let sessionKey = viewModel.sessionKey,
              let entry = viewModel.entry(withID: entryID),
              let parentGroupID = viewModel.parentGroupID(forEntryID: entryID) else { return nil }

        return EntryEditViewModel(
            duplicating: entry,
            sessionKey: sessionKey,
            into: parentGroupID,
            knownTags: viewModel.tagsInDisplayOrder,
            inheritedTags: viewModel.inheritedTags(forGroupID: parentGroupID)
        )
    }
}
