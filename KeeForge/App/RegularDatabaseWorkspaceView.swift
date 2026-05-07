import AuthenticationServices
import SwiftUI
import UIKit

struct RegularDatabaseWorkspaceView: View {
    @Bindable var viewModel: DatabaseViewModel
    @State private var navigationPath: [UUID] = []
    @State private var presentedSaveError: DatabaseSaveError?
    @State private var isCloudReconnectInFlight = false

    var body: some View {
        NavigationSplitView {
            NavigationStack(path: $navigationPath) {
                if let rootID = viewModel.visibleRootGroupID {
                    GroupListView(
                        groupID: rootID,
                        viewModel: viewModel,
                        onSelectEntry: selectEntry
                    )
                    .navigationDestination(for: UUID.self) { groupID in
                        GroupListView(
                            groupID: groupID,
                            viewModel: viewModel,
                            onSelectEntry: selectEntry
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "Vault Not Loaded",
                        systemImage: "lock.doc",
                        description: Text("Unlock a database to browse groups and entries.")
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            NavigationStack {
                if let selectedEntryID = viewModel.selectedEntryID {
                    EntryDetailView(
                        entryID: selectedEntryID,
                        viewModel: viewModel,
                        onClose: {
                            viewModel.selectEntry(nil)
                        }
                    )
                } else if viewModel.searchText.isEmpty {
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
        .navigationSplitViewStyle(.balanced)
        .background(Color(.systemBackground))
        .accessibilityIdentifier("regular-workspace.root")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if let warningText = viewModel.cloudSyncBannerText {
                    HStack {
                        CloudSyncWarningButton(message: warningText)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if viewModel.saveError?.isWriteScopeRequired == true {
                    CloudReauthBanner(
                        providerName: viewModel.databaseReference.cloudProviderKind?.displayName ?? "cloud",
                        isReconnectInFlight: isCloudReconnectInFlight,
                        onReconnect: beginCloudReconnect
                    )
                }

                if viewModel.isDirty && viewModel.isSaving == false {
                    UnsavedChangesBanner(viewModel: viewModel)
                }
            }
        }
        .disabled(viewModel.isSaving)
        .overlay {
            if viewModel.isSaving {
                DatabaseSavingOverlay()
            }
        }
        .saveConflictAlert(viewModel: viewModel)
        .onChange(of: viewModel.saveError) { _, newValue in
            if let newValue {
                presentedSaveError = newValue
            }
        }
        .onChange(of: viewModel.visibleRootGroupID) { _, _ in
            navigationPath = []
            viewModel.selectEntry(nil)
        }
        .onChange(of: navigationPath) { _, _ in
            viewModel.selectEntry(nil)
        }
        .onChange(of: viewModel.searchText) { oldValue, newValue in
            guard oldValue != newValue else { return }
            viewModel.selectEntry(nil)
        }
        .alert(item: $presentedSaveError) { error in
            Alert(
                title: Text("Couldn't Save Database"),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            "Lock and discard unsaved changes?",
            isPresented: Binding(
                get: { viewModel.pendingLockRequest != nil },
                set: { isPresented in
                    if isPresented == false {
                        viewModel.cancelLockRequest()
                    }
                }
            )
        ) {
            Button("Lock and Discard", role: .destructive) {
                let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
            }
            Button("Keep Editing", role: .cancel) {
                viewModel.cancelLockRequest()
            }
        } message: {
            Text("Your unsaved entry changes will be lost.")
        }
    }

    private func selectEntry(_ entry: KPEntry) {
        viewModel.selectEntry(entry.id)
    }

    @MainActor
    private func beginCloudReconnect() {
        guard isCloudReconnectInFlight == false else { return }
        guard let providerID = viewModel.databaseReference.cloudSyncMetadata?.provider,
              let provider = CloudProviderRegistry.provider(for: providerID) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        isCloudReconnectInFlight = true
        Task { @MainActor in
            defer { isCloudReconnectInFlight = false }

            do {
                _ = try await provider.authenticate(from: presentationAnchor())
                viewModel.clearSaveError()
            } catch let error as CloudProviderError where error == .authenticationCancelled {
                return
            } catch {
                viewModel.presentSaveError(error)
            }
        }
    }

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
    }
}
