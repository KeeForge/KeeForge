#if os(iOS)
import AuthenticationServices
import SwiftUI
import UIKit

struct RegularDatabaseWorkspaceView: View {
    @Bindable var viewModel: DatabaseViewModel
    @State private var presentedSaveError: DatabaseSaveError?
    @State private var isCloudReconnectInFlight = false

    var body: some View {
        decoratedSplitView
            .onChange(of: viewModel.saveError) { _, newValue in
                if let newValue {
                    presentedSaveError = newValue
                }
            }
            .onChange(of: viewModel.visibleRootGroupID) { _, _ in
                // Lock, close, and database switch all land here (the visible
                // root goes nil), clearing pushed group *and* tag destinations.
                viewModel.workspace.navigationPath = []
                viewModel.workspace.selectedEntryID = nil
                viewModel.workspace.closeEditor()
            }
            .onChange(of: viewModel.workspace.navigationPath) { _, _ in
                viewModel.workspace.selectedEntryID = nil
            }
            .onChange(of: viewModel.searchText) { oldValue, newValue in
                guard oldValue != newValue else { return }
                viewModel.workspace.selectedEntryID = nil
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
                    get: { viewModel.pendingLockRequest?.reason == .draft },
                    set: { _ in }
                )
            ) {
                if viewModel.isReadOnly == false {
                    Button("Retry Save and Lock") {
                        Task { await viewModel.saveAndLockAfterLockRequest() }
                    }
                }
                Button("Lock and Discard", role: .destructive) {
                    let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                    viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
                }
                Button("Keep Editing", role: .cancel) {
                    Task {
                        await viewModel.continueEditingAfterLockRequest()
                    }
                }
            } message: {
                Text("Your unsaved entry changes will be lost.")
            }
    }

    private var decoratedSplitView: some View {
        splitView
            .navigationSplitViewStyle(.balanced)
            .background(Color(.systemBackground))
            .accessibilityIdentifier("regular-workspace.root")
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
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

                    if viewModel.hasPendingUploadConflict && viewModel.isSaving == false {
                        PendingUploadConflictBanner(viewModel: viewModel)
                    }
                }
                // The lists scroll under this inset, and the banners are only tinted.
                .background(Color(.systemBackground), ignoresSafeAreaEdges: [])
            }
            .disabled(viewModel.isSaving)
            .overlay {
                if viewModel.isSaving {
                    DatabaseSavingOverlay()
                }
            }
            .saveConflictAlert(viewModel: viewModel)
    }

    @ViewBuilder
    private var splitView: some View {
        NavigationSplitView {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            detailColumn
        }
    }

    private var detailColumn: some View {
        NavigationStack {
            // The workspace's editor opens here, not in the 320–440pt sidebar,
            // which would leave the wide column idle behind a placeholder.
            if let editor = viewModel.workspace.openEditor {
                hostedEditor(editor)
            } else {
                selectionDetail
            }
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
                    onSelectTag: selectTag,
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
        .appSettingsToolbarButton()
    }

    @ViewBuilder
    private func hostedEditor(_ editor: DatabaseWorkspaceState.OpenEditor) -> some View {
        switch editor {
        case .entry(let formViewModel):
            EntryEditView(
                formViewModel: formViewModel,
                databaseViewModel: viewModel,
                coordinator: viewModel.workspace.editorCoordinator(database: viewModel)
            ) { completion in
                selectCreatedEntry(completion)
                viewModel.workspace.closeEditor()
            }
        case .group(let formViewModel):
            GroupEditView(
                formViewModel: formViewModel,
                databaseViewModel: viewModel,
                coordinator: viewModel.workspace.editorCoordinator(database: viewModel)
            ) {
                viewModel.workspace.closeEditor()
            }
        }
    }

    /// iPad sidebar group navigation.
    @ViewBuilder
    private var sidebarColumn: some View {
        NavigationStack(path: Bindable(viewModel.workspace).navigationPath) {
            if let rootID = viewModel.visibleRootGroupID {
                GroupListView(
                    groupID: rootID,
                    viewModel: viewModel,
                    onSelectEntry: selectEntry,
                    onOpenRoute: openSidebarRoute
                )
                .navigationDestination(for: DatabaseRoute.self) { destination in
                    switch destination {
                    case .group(let groupID):
                        GroupListView(
                            groupID: groupID,
                            viewModel: viewModel,
                            onSelectEntry: selectEntry,
                            onOpenRoute: openSidebarRoute
                        )
                    case .collection(let collection):
                        GroupListView(
                            groupID: rootID,
                            collection: collection,
                            viewModel: viewModel,
                            onSelectEntry: selectEntry,
                            onOpenRoute: openSidebarRoute
                        )
                    case .tag(let tag):
                        TagEntriesView(
                            tag: tag,
                            viewModel: viewModel,
                            onSelectEntry: selectEntry
                        )
                    case .entry(let entryID):
                        EntryDetailView(entryID: entryID, viewModel: viewModel)
                    case .editor:
                        // The detail column hosts the editor.
                        EmptyView()
                    }
                }
            } else {
                ContentUnavailableView(
                    "Vault Not Loaded",
                    systemImage: "lock.doc",
                    description: Text("Unlock a database to browse groups and entries.")
                )
            }
        }
    }

    private func selectCreatedEntry(_ completion: EntryEditCompletion) {
        guard case .created(let entryID) = completion else { return }
        viewModel.revealEntry(entryID)
    }

    private func selectEntry(_ entry: KPEntry) {
        viewModel.workspace.selectedEntryID = entry.id
    }

    private func openSidebarRoute(_ route: DatabaseRoute) {
        viewModel.workspace.navigationPath.append(route)
    }

    /// Tag chips navigate the sidebar stack, where the root Tags row leads.
    private func selectTag(_ tag: String) {
        viewModel.workspace.navigationPath.append(.tag(tag))
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

#endif
