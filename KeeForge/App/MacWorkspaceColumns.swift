#if os(macOS)
import SwiftUI

struct MacWorkspaceEntriesColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation

    var body: some View {
        entries.entrySelectionBar(viewModel: viewModel) { presentation.pendingMove = $0 }
    }

    @ViewBuilder
    private var entries: some View {
        // Search wins over a sidebar tag selection: the search field is always-on
        // chrome on macOS, so typing must show results immediately. Clearing the
        // query returns to whatever the sidebar still has selected.
        if viewModel.searchText.isEmpty {
            // The `content:` column of a three-column `NavigationSplitView`
            // caches its subtree on macOS and doesn't re-evaluate on the view
            // model's observation changes (the detail column does), so an
            // edited entry keeps a stale row label without this id. Reading
            // `contentRevision` here also re-runs the body so the id updates.
            if let selectedTag = viewModel.workspace.selectedTag {
                TagEntriesView(
                    tag: selectedTag,
                    viewModel: viewModel,
                    onSelectEntry: { viewModel.workspace.selectedEntryID = $0.id },
                    onRequestDeletion: { presentation.pendingDeletion = $0 }
                )
                .id(viewModel.contentRevision)
            } else {
                MacGroupEntriesList(
                    viewModel: viewModel,
                    onOpenEntry: { presentation.beginEntryEdit(entryID: $0, in: viewModel) },
                    onRequestMove: { presentation.pendingMove = $0 },
                    onRequestDuplicate: { presentation.beginEntryDuplicate($0) },
                    onRequestDeletion: { presentation.pendingDeletion = $0 }
                )
                .id(viewModel.contentRevision)
            }
        } else {
            // Rendered inline in this column, so its deletions go to the
            // workspace's own host rather than adding a colliding one.
            SearchView(
                viewModel: viewModel,
                onSelectEntry: { viewModel.workspace.selectedEntryID = $0.id },
                onRequestDeletion: { presentation.pendingDeletion = $0 }
            )
        }
    }

}

struct MacWorkspaceDetailColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation

    var body: some View {
        NavigationStack {
            selectionDetail
        }
    }

    @ViewBuilder
    private var selectionDetail: some View {
        Group {
            if let selectedEntryID = viewModel.workspace.selectedEntryID {
                EntryDetailView(
                    entryID: selectedEntryID,
                    viewModel: viewModel,
                    onClose: {
                        viewModel.workspace.selectedEntryID = nil
                    },
                    onSelectTag: { viewModel.workspace.selectedTag = $0 },
                    popsOnClose: false
                )
                .id(selectedEntryID)
            } else if viewModel.searchText.isEmpty || viewModel.searchResults.isEmpty {
                // With no matches the sidebar already says "No Results"; the
                // detail must not contradict it with "select a matching entry".
                ContentUnavailableView(
                    "Select an Entry",
                    systemImage: "key.horizontal",
                    description: Text("Choose an entry to view or edit its details.")
                )
                .accessibilityIdentifier("regular-workspace.select-entry-placeholder")
            } else {
                ContentUnavailableView(
                    "Search Results",
                    systemImage: "magnifyingglass",
                    description: Text("Select a matching entry to view its details.")
                )
                .accessibilityIdentifier("regular-workspace.search-results-placeholder")
            }
        }
    }

}

/// The macOS content column: the selected group's entries in a native
/// `List(selection:)` bound to `DatabaseViewModel.workspace.selectedEntryID`, so arrow
/// keys, type-select, and the focus ring come from AppKit rather than being
/// hand-rolled. A dedicated `@Bindable` observing view (not an inline
/// `@ViewBuilder` on the workspace) so it re-renders on
/// `DatabaseViewModel.contentRevision` changes — e.g. after an edit renames an
/// entry, which an inline computed property missed.
private struct MacGroupEntriesList: View {
    @Bindable var viewModel: DatabaseViewModel
    /// A click on a row with a tap handler is not relied on to make the list
    /// first responder (it does on macOS 27.0; earlier releases are
    /// unverified), so the handler hands focus over explicitly.
    @FocusState private var isListFocused: Bool
    /// Double-click and Return; the workspace hosts the editor sheet.
    let onOpenEntry: (UUID) -> Void
    /// Raised to the workspace, which hosts the picker and the confirmation;
    /// a row-scoped host dies with the row the action removes.
    let onRequestMove: (PendingMove) -> Void
    /// Raised to the workspace too, so a duplicate opens the one editor sheet
    /// ⌘N and ⌘E open rather than a second one over this column.
    let onRequestDuplicate: (EntryEditViewModel) -> Void
    let onRequestDeletion: (PendingDeletion) -> Void

    /// A selected collection, else the selected group, else the workspace root.
    private var resolvedSelection: MacSidebarSelection? {
        if let collection = viewModel.workspace.selectedCollection { return .collection(collection) }
        guard let groupID = viewModel.workspace.selectedGroupID ?? viewModel.workspaceRootGroupID,
              viewModel.group(withID: groupID) != nil else { return nil }
        return .group(groupID)
    }

    var body: some View {
        @Bindable var workspace = viewModel.workspace
        if let selection = resolvedSelection {
            let entries = viewModel.entries(for: selection)
            Group {
                if entries.isEmpty {
                    emptyState(for: selection)
                } else {
                    List(entries, selection: $workspace.selectedEntryID) { entry in
                        MacEntryRow(
                            entry: entry,
                            viewModel: viewModel,
                            showsFolderPath: selection.isCollection,
                            isListFocused: $isListFocused,
                            onOpenEntry: onOpenEntry,
                            onRequestMove: onRequestMove,
                            onRequestDuplicate: onRequestDuplicate,
                            onRequestDeletion: onRequestDeletion
                        )
                    }
                    .listStyle(.inset)
                    .focused($isListFocused)
                    .onKeyPress(.return) {
                        guard let entryID = viewModel.workspace.commandEntryID else { return .ignored }
                        onOpenEntry(entryID)
                        return .handled
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Group",
                systemImage: "folder",
                description: Text("Choose a group to view its entries.")
            )
        }
    }

    @ViewBuilder
    private func emptyState(for selection: MacSidebarSelection) -> some View {
        switch selection {
        case .collection(.verificationCodes):
            ContentUnavailableView(
                "No Verification Codes",
                systemImage: DatabaseCollection.verificationCodes.systemImage,
                description: Text("Entries with a verification code appear here.")
            )
        case .collection:
            ContentUnavailableView(
                "No Entries",
                systemImage: "tray",
                description: Text("This database has no entries.")
            )
        case .group, .tag:
            ContentUnavailableView(
                "No Entries",
                systemImage: "tray",
                description: Text("This group has no entries.")
            )
        }
    }
}

private extension MacSidebarSelection {
    var isCollection: Bool {
        if case .collection = self { true } else { false }
    }
}
#endif
