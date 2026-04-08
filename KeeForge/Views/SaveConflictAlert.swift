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
                Text("The database changed outside KeeForge. Reload it or save your draft as a sibling conflict copy.")
            }
    }
}

extension View {
    func saveConflictAlert(viewModel: DatabaseViewModel) -> some View {
        modifier(SaveConflictAlertModifier(viewModel: viewModel))
    }
}
