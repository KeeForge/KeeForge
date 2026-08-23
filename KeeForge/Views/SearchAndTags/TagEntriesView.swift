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
                EntryListView(
                    entries: entries,
                    viewModel: viewModel,
                    onSelectEntry: onSelectEntry
                )
                .accessibilityIdentifier("tag-entries.list")
            }
        }
        .modifier(TagEntriesTitle(tag: tag))
    }
}

/// Titles the tag-filtered list per shell: iOS pushes it, so the tag becomes the
/// navigation title (standard truncation for long names); macOS renders it in
/// the split view's content column, where the window title belongs to the
/// database, so the tag becomes the subtitle the way the group name does in
/// `MacEntriesColumn`.
private struct TagEntriesTitle: ViewModifier {
    let tag: String

    func body(content: Content) -> some View {
        #if os(macOS)
        content.navigationSubtitle(tag)
        #else
        content
            .navigationTitle(tag)
            .navigationBarTitleDisplayMode(.large)
        #endif
    }
}
