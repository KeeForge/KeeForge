#if os(macOS)
import AuthenticationServices
import SwiftUI
import AppKit

/// Column revisions must never replace the host while a sheet is dismissing.
struct MacWorkspacePresentationHost<Content: View>: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation
    @ViewBuilder var content: Content

    var body: some View {
        decoratedContent
            .onChange(of: viewModel.saveError) { _, newValue in
                if let newValue {
                    presentation.presentedSaveError = newValue
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
            .onChange(of: viewModel.workspace.newEntryRequestID) { oldValue, newValue in
                guard newValue != oldValue else { return }
                presentation.beginNewEntry(in: viewModel)
            }
            .onChange(of: viewModel.workspace.newGroupRequestID) { oldValue, newValue in
                guard newValue != oldValue else { return }
                presentation.beginNewGroup()
            }
            .onChange(of: viewModel.workspace.editEntryRequestID) { oldValue, newValue in
                guard newValue != oldValue else { return }
                presentation.beginSelectedEntryEdit(in: viewModel)
            }
            .onChange(of: viewModel.workspace.deleteSelectionRequestID) { oldValue, newValue in
                guard newValue != oldValue else { return }
                presentation.beginSelectionDeletion(in: viewModel)
            }
            .sheet(item: $presentation.commandEditor) { formViewModel in
                NavigationStack {
                    EntryEditView(
                        formViewModel: formViewModel,
                        databaseViewModel: viewModel
                    ) { completion in
                        if case .created(let entryID) = completion { viewModel.revealEntry(entryID) }
                        presentation.commandEditor = nil
                    }
                }
                .macSheetFrame()
            }
            .alert(item: $presentation.presentedSaveError) { error in
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
            .sheet(isPresented: $presentation.isShowingNewGroupSheet) {
                NewGroupSheet(
                    name: $presentation.newGroupName,
                    errorMessage: $presentation.groupCreationErrorMessage,
                    onCancel: { presentation.dismissNewGroup() },
                    onCreate: { presentation.createGroup(named: $0, in: viewModel) }
                )
            }
            .sheet(item: $presentation.groupEditor) { formViewModel in
                NavigationStack {
                    GroupEditView(
                        formViewModel: formViewModel,
                        databaseViewModel: viewModel
                    ) {
                        presentation.groupEditor = nil
                    }
                }
                .macSheetFrame(minHeight: 520)
            }
            .sheet(item: $presentation.pendingMove) { pending in
                MoveToGroupPickerView(
                    options: pending.destinationOptions(viewModel: viewModel),
                    navigationTitle: pending.navigationTitle
                ) { destinationGroupID in
                    pending.apply(destinationGroupID: destinationGroupID, viewModel: viewModel)
                }
            }
            .sheet(isPresented: $presentation.isShowingDatabaseDetails) {
                DatabaseDetailsView(
                    reference: viewModel.databaseReference,
                    sessionViewModel: viewModel
                )
                .macSheetFrame()
            }
            // A separate dialog channel avoids colliding with the save-error alert.
            .confirmationDialog(
                presentation.pendingDeletion?.confirmationTitle ?? "",
                isPresented: Binding(
                    get: { presentation.pendingDeletion != nil },
                    set: { if $0 == false { presentation.pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: presentation.pendingDeletion
            ) { deletion in
                Button(deletion.confirmActionTitle, role: .destructive) {
                    deletion.performDeletion(viewModel: viewModel)
                }
                Button("Cancel", role: .cancel) {}
            } message: { deletion in
                Text(deletion.confirmationMessage)
            }
            .onDisappear { presentation.reset() }
    }

    private var decoratedContent: some View {
        content
            .background(Color(.systemBackground))
            .accessibilityIdentifier("regular-workspace.root")
            .safeAreaInset(edge: .top, spacing: 0) {
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

    @MainActor
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

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}
#endif
