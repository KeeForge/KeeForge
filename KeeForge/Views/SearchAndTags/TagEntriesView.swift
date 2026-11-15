#if os(iOS)
import SwiftUI

/// The entries carrying one tag.
///
/// The list is derived from the view model on every render rather than captured
/// when the screen was pushed, so edits, deletions, and recycling show up
/// immediately — including the case where the tag's last carrier disappears
/// while this screen is open, which shows the empty state instead of crashing
/// or popping.
struct TagEntriesView: View {
    let tag: String
    @Bindable var viewModel: DatabaseViewModel
    /// Set by the shell that selects an entry instead of pushing it (the iPad
    /// workspace), matching `EntryListView`'s own contract.
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    /// Set by shells that render this screen inline inside a container which
    /// already hosts a `PendingDeletion`. The stack shells push this screen, so
    /// they leave it nil and the list hosts its own. See
    /// `../Entry/PendingRowActions.swift`.
    var onRequestDeletion: ((PendingDeletion) -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let entries = viewModel.sortedEntries(viewModel.entries(withTag: tag))
        Group {
            if entries.isEmpty {
                // Deliberately not `ContentUnavailableView.search`: nothing was
                // searched for, the tag simply has no live carriers left.
                ContentUnavailableView(
                    "No Entries",
                    systemImage: "tag.slash",
                    description: Text("No entries carry this tag anymore.")
                )
            } else {
                TagEntriesList(
                    entries: entries,
                    viewModel: viewModel,
                    onSelectEntry: onSelectEntry,
                    onRequestDeletion: onRequestDeletion
                )
                .accessibilityIdentifier("tag-entries.list")
            }
        }
        .navigationTitle(tag)
        .navigationBarTitleDisplayMode(.large)
        .modifier(EntryCountSubtitle(entryCount: entries.count))
        .toolbar {
            ToolbarItem(placement: .databaseActions) {
                DatabaseLockButton(viewModel: viewModel, isCompact: horizontalSizeClass == .compact)
            }
        }
    }
}

private struct TagEntriesList: View {
    let entries: [KPEntry]
    @Bindable var viewModel: DatabaseViewModel
    let onSelectEntry: ((KPEntry) -> Void)?
    let onRequestDeletion: ((PendingDeletion) -> Void)?

    var body: some View {
        EntryListView(
            entries: entries,
            viewModel: viewModel,
            onSelectEntry: onSelectEntry,
            onRequestDeletion: onRequestDeletion
        )
    }
}

/// The count under the large title from iOS 26, like the group screens.
private struct EntryCountSubtitle: ViewModifier {
    let entryCount: Int

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(Text("\(entryCount) entries"))
        } else {
            content
        }
    }
}
#endif
