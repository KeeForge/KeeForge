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
                    description: Text("Type to search by title, username, URL, or notes.")
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
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
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
