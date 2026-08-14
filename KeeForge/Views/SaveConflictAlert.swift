import SwiftUI

struct SaveConflictAlertModifier: ViewModifier {
    @Bindable var viewModel: DatabaseViewModel
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.saveConflict) { _, newValue in
                if newValue != nil {
                    isPresented = true
                }
            }
            .alert("Save Conflict", isPresented: $isPresented) {
                Button("Merge Changes") {
                    Task {
                        do {
                            try await viewModel.mergeAndSave()
                        } catch {
                            viewModel.presentSaveError(error)
                        }
                    }
                }
                .accessibilityIdentifier("save-conflict.merge")

                Button("Reload and Re-edit") {
                    Task {
                        do {
                            try await viewModel.reloadDiscardingDraft()
                        } catch {
                            viewModel.presentSaveError(error)
                        }
                    }
                }
                .accessibilityIdentifier("save-conflict.reload")

                Button("Save as Conflict Copy") {
                    Task {
                        do {
                            try await viewModel.saveAsConflictCopy()
                        } catch {
                            viewModel.presentSaveError(error)
                        }
                    }
                }
                .accessibilityIdentifier("save-conflict.save-as-copy")

                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("save-conflict.cancel")
            } message: {
                Text("The database changed outside KeeForge. Merge both sets of changes, reload it, or save your draft as a sibling conflict copy.")
            }
            .alert(
                "Changes Merged",
                isPresented: Binding(
                    get: { viewModel.mergeSummaryMessage != nil },
                    set: { _ in }
                )
            ) {
                Button("OK") {
                    viewModel.acknowledgeMergeSummary()
                }
                .accessibilityIdentifier("merge-summary.ok")
            } message: {
                Text(viewModel.mergeSummaryMessage ?? "")
            }
            // A declined merge is not a dead end: acknowledging it puts the
            // conflict alert back up, with the same Reload and Save-as-Copy
            // options the user started from.
            .alert(
                "Couldn't Merge Changes",
                isPresented: Binding(
                    get: { viewModel.mergeFailure != nil },
                    set: { _ in }
                )
            ) {
                Button("OK") {
                    viewModel.dismissMergeFailure()
                    if viewModel.saveConflict != nil {
                        isPresented = true
                    }
                }
                .accessibilityIdentifier("merge-failure.ok")
            } message: {
                Text(viewModel.mergeFailure?.message ?? "")
            }
    }
}

extension View {
    func saveConflictAlert(viewModel: DatabaseViewModel) -> some View {
        modifier(SaveConflictAlertModifier(viewModel: viewModel))
    }
}
