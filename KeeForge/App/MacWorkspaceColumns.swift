#if os(macOS)
import SwiftUI

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
#endif
