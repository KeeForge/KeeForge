import SwiftUI

struct EntryEditView: View {
    enum Completion {
        case finished
        case deleted
    }

    @State private var formViewModel: EntryEditViewModel
    @Bindable var databaseViewModel: DatabaseViewModel
    let onComplete: (Completion) -> Void

    @State private var showDiscardConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showPasswordGenerator = false
    @State private var editingErrorMessage: String?

    init(
        formViewModel: EntryEditViewModel,
        databaseViewModel: DatabaseViewModel,
        onComplete: @escaping (Completion) -> Void = { _ in }
    ) {
        _formViewModel = State(initialValue: formViewModel)
        self.databaseViewModel = databaseViewModel
        self.onComplete = onComplete
    }

    var body: some View {
        Form {
            Section("Basics") {
                basicFieldRow("Title") {
                    TextField("Title", text: $formViewModel.title)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("entry-edit.title-field")
                }

                basicFieldRow("Username") {
                    TextField("Username", text: $formViewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("entry-edit.username-field")
                }

                basicFieldRow("Password") {
                    HStack(spacing: 12) {
                        SecureField("Password", text: $formViewModel.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("entry-edit.password-field")

                        Button {
                            showPasswordGenerator = true
                        } label: {
                            Image(systemName: "dice.fill")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Generate password")
                        .accessibilityIdentifier("entry-edit.password-generator-button")
                    }
                }

                basicFieldRow("URL") {
                    TextField("URL", text: $formViewModel.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .accessibilityIdentifier("entry-edit.url-field")
                }

                basicFieldRow("Tags") {
                    TextField("Tags", text: $formViewModel.tagsText, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("entry-edit.tags-field")
                }
            }

            Section("Notes") {
                TextEditor(text: $formViewModel.notes)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("entry-edit.notes-field")
            }

            if formViewModel.passkeyCredential != nil || formViewModel.unknownXMLNodeCount > 0 {
                Section("Preserved Read-Only Data") {
                    if let passkey = formViewModel.passkeyCredential {
                        LabeledContent("Passkey Relying Party", value: passkey.relyingParty)
                        LabeledContent("Passkey Username", value: passkey.username)
                    }

                    if formViewModel.unknownXMLNodeCount > 0 {
                        Text("Unknown KeePass XML will be preserved when you save this entry.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if case .edit = formViewModel.mode {
                Section {
                    Button("Delete Entry", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .accessibilityIdentifier("entry-edit.delete")
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    cancelTapped()
                }
                .accessibilityIdentifier("entry-edit.cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveTapped()
                }
                .disabled(formViewModel.canSave == false)
                .accessibilityIdentifier("entry-edit.save")
            }
        }
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorSheet { password in
                formViewModel.password = password
            }
        }
        .alert("Discard changes?", isPresented: $showDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) {
                onComplete(.finished)
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your entry changes haven't been saved to this database draft yet.")
        }
        .confirmationDialog(
            "Delete Entry",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Recycle Bin", role: .destructive) {
                deleteTapped(sendToRecycleBin: true)
            }
            Button("Delete Permanently", role: .destructive) {
                deleteTapped(sendToRecycleBin: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how to remove this entry.")
        }
        .alert(
            "Couldn’t Update Entry",
            isPresented: Binding(
                get: { editingErrorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        editingErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editingErrorMessage ?? "")
        }
    }

    private var navigationTitle: String {
        switch formViewModel.mode {
        case .create:
            "New Entry"
        case .edit:
            "Edit Entry"
        }
    }

    private func basicFieldRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
        }
        .padding(.vertical, 2)
    }

    private func cancelTapped() {
        if formViewModel.isDirty {
            showDiscardConfirmation = true
        } else {
            onComplete(.finished)
        }
    }

    private func saveTapped() {
        do {
            switch formViewModel.mode {
            case .create(let parentGroupID):
                try databaseViewModel.applyEntryEdit(
                    .createEntry(parentGroupID: parentGroupID, draft: formViewModel.entryDraftPayload)
                )
            case .edit(let entryID):
                try databaseViewModel.applyEntryEdit(
                    .updateEntry(entryID: entryID, draft: formViewModel.entryDraftPayload)
                )
            }

            onComplete(.finished)
        } catch {
            editingErrorMessage = error.localizedDescription
        }
    }

    private func deleteTapped(sendToRecycleBin: Bool) {
        guard case .edit(let entryID) = formViewModel.mode else { return }

        do {
            try databaseViewModel.deleteEntry(entryID, sendToRecycleBin: sendToRecycleBin)
            onComplete(.deleted)
        } catch {
            editingErrorMessage = error.localizedDescription
        }
    }
}
