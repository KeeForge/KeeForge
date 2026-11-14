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
    /// Set by the shells that select an entry instead of pushing it (the iPad
    /// workspace and macOS), matching `EntryListView`'s own contract.
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    /// Set by shells that render this screen inline inside a container which
    /// already hosts a `PendingDeletion` — the macOS workspace content column.
    /// The stack shells push this screen, so they leave it nil and the list
    /// hosts its own. See `../Entry/PendingRowActions.swift`.
    var onRequestDeletion: ((PendingDeletion) -> Void)? = nil

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
        .modifier(TagEntriesTitle(tag: tag, entryCount: entries.count, viewModel: viewModel))
    }
}

/// The tag's entries, per shell — the same split `SearchView` makes, and for
/// the same reason: macOS selects an entry in the content column rather than
/// pushing it, so the column needs the native `List(selection:)` that carries
/// arrow keys and type-select.
private struct TagEntriesList: View {
    let entries: [KPEntry]
    @Bindable var viewModel: DatabaseViewModel
    let onSelectEntry: ((KPEntry) -> Void)?
    let onRequestDeletion: ((PendingDeletion) -> Void)?

    var body: some View {
        #if os(macOS)
        MacEntriesList(
            viewModel: viewModel,
            entries: entries,
            onRequestDeletion: onRequestDeletion
        )
        #else
        EntryListView(
            entries: entries,
            viewModel: viewModel,
            onSelectEntry: onSelectEntry,
            onRequestDeletion: onRequestDeletion
        )
        #endif
    }
}

/// Titles the tag-filtered list per shell: iOS pushes it, so the tag becomes the
/// navigation title (standard truncation for long names) with the entry count
/// under it and Lock in the bar, as on the other vault screens; macOS renders
/// it in the split view's content column, where the window title belongs to
/// the database and Lock to the sidebar, so the tag becomes the subtitle the
/// way the group name does in `MacEntriesColumn`.
private struct TagEntriesTitle: ViewModifier {
    let tag: String
    let entryCount: Int
    let viewModel: DatabaseViewModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.navigationSubtitle(tag)
        #else
        content
            .navigationTitle(tag)
            .navigationBarTitleDisplayMode(.large)
            .modifier(EntryCountSubtitle(entryCount: entryCount))
            .toolbar {
                ToolbarItem(placement: .databaseActions) {
                    DatabaseLockButton(viewModel: viewModel, isCompact: horizontalSizeClass == .compact)
                }
            }
        #endif
    }
}

#if os(iOS)
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
