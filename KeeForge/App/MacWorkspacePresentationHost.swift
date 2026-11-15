#if os(macOS)
import SwiftUI

/// Keeps command observers and the saving overlay stable across column revisions.
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
