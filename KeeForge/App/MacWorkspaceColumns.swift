#if os(macOS)
import AppKit
import AuthenticationServices
import SwiftUI

struct MacWorkspaceDetailColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation

    var body: some View {
        NavigationStack {
            selectionDetail
        }
        // The placeholders size to their content; filling keeps the banners at the column's top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            MacWorkspaceBanners(viewModel: viewModel, presentation: presentation)
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

/// The save, upload-conflict and cloud reconnect banners, at the top of the detail column.
private struct MacWorkspaceBanners: View {
    let viewModel: DatabaseViewModel
    let presentation: MacWorkspacePresentation

    var body: some View {
        VStack(spacing: 8) {
            if viewModel.saveError?.isWriteScopeRequired == true {
                CloudReauthBanner(
                    providerName: viewModel.databaseReference.cloudProviderKind?.displayName ?? "cloud",
                    isReconnectInFlight: presentation.isCloudReconnectInFlight,
                    onReconnect: beginCloudReconnect
                )
            }

            if viewModel.isDirty && viewModel.isSaving == false {
                UnsavedChangesBanner(viewModel: viewModel)
            }

            if viewModel.hasPendingUploadConflict && viewModel.isSaving == false {
                PendingUploadConflictBanner(viewModel: viewModel)
            }
        }
        // The detail scrolls under this inset, and the banners are only tinted.
        .background(Color(.systemBackground), ignoresSafeAreaEdges: [])
    }

    private func beginCloudReconnect() {
        guard presentation.isCloudReconnectInFlight == false else { return }
        guard let providerID = viewModel.databaseReference.cloudSyncMetadata?.provider,
              let provider = CloudProviderRegistry.provider(for: providerID) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        presentation.reconnectCloud(in: viewModel) {
            _ = try await provider.authenticate(from: presentationAnchor())
        }
    }

    private func presentationAnchor() -> ASPresentationAnchor {
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}
#endif
