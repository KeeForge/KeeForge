import SwiftUI

struct EntryListView: View {
    let entries: [KPEntry]
    @Bindable var viewModel: DatabaseViewModel
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    /// Set by containers that already host a `PendingDeletion` on this
    /// presentation context — the search results inside `GroupListView`. A
    /// second `.alert(item:)` there collides with the container's and SwiftUI
    /// silently drops one, so the row raises its confirmation instead of
    /// hosting it. Nil where this list is its own pushed screen (the tag
    /// browser), which keeps the host below.
    var onRequestDeletion: ((PendingDeletion) -> Void)? = nil
    @State private var pendingDeletion: PendingDeletion?
    /// The entry whose Move-to-Group picker is presented, or `nil` when none is.
    @State private var pendingMove: PendingMove?
    /// The prefilled New Entry form a Duplicate raised, or `nil` when none is.
    /// A sheet rather than a push: this list is the search results and the tag
    /// browser, which the iPad renders in the sidebar column, and a form
    /// pushed there would open beside the entry it was copied from.
    @State private var duplicateEditor: EntryEditViewModel?

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView.search
            } else {
                List(entries) { entry in
                    entryRow(for: entry)
                }
                .id(viewModel.contentRevision)
            }
        }
        // Outside the branches: deleting the last entry flips to the empty
        // branch, which would tear down a branch-scoped alert host.
        .modifier(
            ListScopedDeletionAlert(
                pending: $pendingDeletion,
                viewModel: viewModel,
                isHosted: onRequestDeletion == nil
            )
        )
        // Outside for the same reason. Destinations are resolved when the
        // picker is built, not when the menu was tapped.
        .sheet(item: $pendingMove) { pending in
            MoveToGroupPickerView(
                options: pending.destinationOptions(viewModel: viewModel)
            ) { destinationGroupID in
                pending.apply(destinationGroupID: destinationGroupID, viewModel: viewModel)
            }
        }
        // Outside the branches for the same reason as the hosts above.
        .sheet(item: $duplicateEditor) { formViewModel in
            NavigationStack {
                EntryEditView(
                    formViewModel: formViewModel,
                    databaseViewModel: viewModel
                ) { _ in
                    duplicateEditor = nil
                }
            }
        }
    }

    /// Resolves the soft/permanent choice per entry — these lists draw from
    /// more than one group — then hands the finished action to the container's
    /// host, or to this list's own.
    private func requestDeletion(for entry: KPEntry) {
        let deletion = PendingDeletion.entry(
            PendingEntryDeletion(
                entryID: entry.id,
                sendToRecycleBin: sendDeletionToRecycleBin(for: entry)
            )
        )
        if let onRequestDeletion {
            onRequestDeletion(deletion)
        } else {
            pendingDeletion = deletion
        }
    }

    @ViewBuilder
    private func entryRow(for entry: KPEntry) -> some View {
        Group {
            if let onSelectEntry {
                Button {
                    onSelectEntry(entry)
                } label: {
                    EntryRow(
                        entry: entry,
                        username: viewModel.resolvingFieldReferences(entry.username),
                        customIconData: viewModel.customIconData(for: entry),
                        folderPath: viewModel.folderPath(forEntryID: entry.id)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.entry.navlink")
            } else {
                NavigationLink(value: entry) {
                    EntryRow(
                        entry: entry,
                        username: viewModel.resolvingFieldReferences(entry.username),
                        customIconData: viewModel.customIconData(for: entry),
                        folderPath: viewModel.folderPath(forEntryID: entry.id)
                    )
                }
                .accessibilityIdentifier("search.entry.navlink")
            }
        }
        .macHoverHighlight()
        .contextMenu {
            EntryRowCopyActions(entry: entry, viewModel: viewModel)

            EntryRowDuplicateAction(entryID: entry.id, viewModel: viewModel) { editor in
                duplicateEditor = editor
            }

            if canMove(entry) {
                Button("Move to Group") {
                    pendingMove = .entry(entry.id)
                }
                .accessibilityIdentifier("entry-row.move-context")
            }

            if viewModel.isReadOnly == false {
                Button(deletionTitle(for: entry), role: .destructive) {
                    requestDeletion(for: entry)
                }
                .accessibilityIdentifier(
                    sendDeletionToRecycleBin(for: entry)
                        ? "entry-row.delete-context"
                        : "entry-row.delete-permanent"
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if viewModel.isReadOnly == false {
                Button(deletionTitle(for: entry), role: .destructive) {
                    requestDeletion(for: entry)
                }
                .accessibilityIdentifier("entry-row.delete-swipe")
            }
        }
    }

    private func deletionTitle(for entry: KPEntry) -> String {
        sendDeletionToRecycleBin(for: entry) ? "Delete" : "Delete Permanently"
    }

    private func sendDeletionToRecycleBin(for entry: KPEntry) -> Bool {
        viewModel.isEntryInRecycleBin(entryID: entry.id) == false
    }

    /// Matches the group list: entries move while the database accepts edits
    /// and the entry is not recycled — restoring from the bin is its own flow.
    private func canMove(_ entry: KPEntry) -> Bool {
        viewModel.isReadOnly == false
            && viewModel.isEntryInRecycleBin(entryID: entry.id) == false
    }
}
