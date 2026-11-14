#if os(macOS)
import SwiftUI

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
                        if case .created(let entryID) = completion { presentation.showCreatedEntry(entryID, in: viewModel) }
                        if case .edit(let entryID) = formViewModel.mode,
                           viewModel.workspace.selectedEntryID == entryID,
                           viewModel.entry(withID: entryID) == nil {
                            viewModel.workspace.selectedEntryID = nil
                        }
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
            .disabled(viewModel.isSaving)
            .overlay {
                if viewModel.isSaving {
                    DatabaseSavingOverlay()
                }
            }
    }
}
#endif
