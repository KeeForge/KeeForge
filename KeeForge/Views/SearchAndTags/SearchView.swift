import SwiftUI

struct SearchView: View {
    @Bindable var viewModel: DatabaseViewModel
    var onSelectEntry: ((KPEntry) -> Void)? = nil

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    var body: some View {
        Group {
            if viewModel.isSearchQueryEmpty {
                ContentUnavailableView(
                    "Search Entries",
                    systemImage: "magnifyingglass",
                    description: Text("Type to search by title, username, URL, notes, or tags.")
                )
            } else if viewModel.searchResults.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("No entries matched \"\(viewModel.searchText)\".")
                )
                .accessibilityIdentifier("search.no-results")
            } else {
                EntryListView(
                    entries: viewModel.searchResults,
                    viewModel: viewModel,
                    onSelectEntry: onSelectEntry
                )
                    .accessibilityIdentifier("search.results")
            }
        }
        .modifier(SearchTitle())
        .overlay(alignment: .bottomTrailing) {
            if isUITesting {
                Text("results:\(viewModel.searchResults.count)")
                    .font(.caption2)
                    .padding(6)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("search.results.count")
            }
        }
    }
}

/// Titles the results per shell: iOS pushes them onto the browsing stack, so
/// "Search" is the navigation title; macOS renders them in the split view's
/// content column, where the window title belongs to the database, so it
/// becomes the subtitle the way the group name does in `MacEntriesColumn`.
private struct SearchTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.navigationSubtitle(Text("Search"))
        #else
        content
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
        #endif
    }
}
