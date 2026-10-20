import SwiftUI

struct CustomIconsView: View {
    let viewModel: DatabaseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renameTarget: DatabaseViewModel.CustomIcon?
    @State private var deleteTarget: DatabaseViewModel.CustomIcon?
    @State private var needsSave = false
    @State private var errorMessage: String?

    private var canEdit: Bool {
        !viewModel.isReadOnly && !viewModel.isSaving && viewModel.saveConflict == nil
    }

    var body: some View {
        Form {
            if viewModel.customIcons.isEmpty {
                ContentUnavailableView("No Custom Icons", systemImage: "photo",
                                       description: Text("Downloaded website icons are stored in this database."))
            } else {
                Section {
                    ForEach(viewModel.customIcons) { icon in
                        iconRow(icon)
                    }
                } footer: {
                    Text("Deleting an icon resets affected entries, groups, and history versions to their default icons.")
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                        .accessibilityIdentifier("custom-icons.error")
                    Button("Retry") { save() }
                        .disabled(!canEdit || !viewModel.isDirty)
                        .accessibilityIdentifier("custom-icons.retry")
                }
            }
        }
        .macGroupedForm()
        .navigationTitle("Manage Custom Icons")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isSaving { ProgressView("Saving…") }
        }
        .sheet(item: $renameTarget, onDismiss: {
            if needsSave {
                needsSave = false
                save()
            }
        }) { icon in
            RenameCustomIconView(name: icon.name) { name in
                try viewModel.renameCustomIcon(icon.id, name: name)
                needsSave = true
            }
        }
        .confirmationDialog("Delete Custom Icon?", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible, presenting: deleteTarget) { icon in
            Button("Delete", role: .destructive) {
                deleteTarget = nil
                do {
                    try viewModel.deleteCustomIcon(icon.id)
                    save()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .accessibilityIdentifier("custom-icons.confirm-delete")
            Button("Cancel", role: .cancel) { deleteTarget = nil }
                .accessibilityIdentifier("custom-icons.delete-cancel")
        } message: { _ in
            Text("This icon will be removed from the database. Entries, groups, and history versions using it will show their default icons.")
        }
        .saveConflictAlert(viewModel: viewModel)
        .onChange(of: viewModel.lockCycleID) { _, _ in
            needsSave = false
            renameTarget = nil
            deleteTarget = nil
            errorMessage = nil
            dismiss()
        }
    }

    private func iconRow(_ icon: DatabaseViewModel.CustomIcon) -> some View {
        HStack {
            if let image = PlatformImage(data: icon.data) {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "photo").frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            }
            Text(icon.name.isEmpty ? String(localized: "Custom icon") : icon.name)
                .accessibilityIdentifier("custom-icons.name.\(icon.id.uuidString)")
            Spacer()
            Button("Rename") { renameTarget = icon }
                .accessibilityIdentifier("custom-icons.rename.\(icon.id.uuidString)")
            Button("Delete", role: .destructive) { deleteTarget = icon }
                .accessibilityIdentifier("custom-icons.delete.\(icon.id.uuidString)")
        }
        .buttonStyle(.borderless)
        .disabled(!canEdit)
    }

    private func save() {
        errorMessage = nil
        let cycle = viewModel.lockCycleID
        Task {
            do {
                try await viewModel.save()
            } catch {
                guard viewModel.lockCycleID == cycle else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RenameCustomIconView: View {
    @State var name: String
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .macFormFieldStyle()
                        .accessibilityIdentifier("custom-icons.rename-name")
                } footer: {
                    Text("Icon names require KDBX 4.1. Saving upgrades a KDBX 4.0 database; older KeePass clients may not open it.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .macGroupedForm()
            .navigationTitle("Rename Custom Icon")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("custom-icons.rename-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try onSave(name)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .accessibilityIdentifier("custom-icons.rename-save")
                }
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 260)
    }
}
