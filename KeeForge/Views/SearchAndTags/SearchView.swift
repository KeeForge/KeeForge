#if os(iOS)
import SwiftUI

struct SearchView: View {
    @Bindable var viewModel: DatabaseViewModel
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    /// Set by the shells that render these results inline inside a container
    /// that already hosts a `PendingDeletion` — every shell does, since search
    /// never gets a screen of its own. See `../Entry/PendingRowActions.swift`.
    var onRequestDeletion: ((PendingDeletion) -> Void)? = nil

    private var showsUITestResultsCount: Bool {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("-ui-testing")
            && processInfo.environment["UI_TEST_HIDE_SEARCH_RESULTS_COUNT"] != "1"
        #else
        return false
        #endif
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
                SearchResultsList(
                    viewModel: viewModel,
                    onSelectEntry: onSelectEntry,
                    onRequestDeletion: onRequestDeletion
                )
                .accessibilityIdentifier("search.results")
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .overlay(alignment: .bottomTrailing) {
            if showsUITestResultsCount {
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

private struct SearchResultsList: View {
    @Bindable var viewModel: DatabaseViewModel
    let onSelectEntry: ((KPEntry) -> Void)?
    let onRequestDeletion: ((PendingDeletion) -> Void)?

    var body: some View {
        EntryListView(
            entries: viewModel.searchResults,
            viewModel: viewModel,
            onSelectEntry: onSelectEntry,
            onRequestDeletion: onRequestDeletion,
            header: String(localized: "Results: \(viewModel.searchResults.count)"),
            footer: String(localized: "Type to search by title, username, URL, notes, or tags.")
        )
    }
}
#endif
