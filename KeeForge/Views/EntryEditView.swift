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
    @State private var isPasswordVisible = true
    @State private var editingErrorMessage: String?
    @State private var isSubmitting = false

    private var isSavingInProgress: Bool {
        isSubmitting || databaseViewModel.isSaving
    }

    private var isEntryInRecycleBin: Bool {
        guard case .edit(let entryID) = formViewModel.mode else { return false }
        return databaseViewModel.isEntryInRecycleBin(entryID: entryID)
    }

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
                    PasswordInputRow(
                        title: String(localized: "Password"),
                        text: $formViewModel.password,
                        isVisible: $isPasswordVisible,
                        fieldAccessibilityIdentifier: "entry-edit.password-field",
                        visibilityAccessibilityIdentifier: "entry-edit.password-visibility-button"
                    ) {
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

                    PasswordStrengthIndicator(password: formViewModel.password)
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

                    tagSuggestionStrip
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
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("entry-edit.delete")
                    // Attached to the button (not the Form) so iOS anchors the
                    // dialog to its source control instead of an arbitrary
                    // popover in the middle of the screen.
                    .confirmationDialog(
                        "Delete Entry",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        if !isEntryInRecycleBin {
                            Button("Move to Recycle Bin", role: .destructive) {
                                deleteTapped(sendToRecycleBin: true)
                            }
                        }
                        Button("Delete Permanently", role: .destructive) {
                            deleteTapped(sendToRecycleBin: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(isEntryInRecycleBin
                            ? "This entry is already in the recycle bin. It will be permanently deleted."
                            : "Choose how to remove this entry.")
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .disabled(isSavingInProgress)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    cancelTapped()
                }
                .disabled(isSavingInProgress)
                .accessibilityIdentifier("entry-edit.cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveTapped()
                }
                .disabled(formViewModel.canSave == false || isSavingInProgress)
                .accessibilityIdentifier("entry-edit.save")
            }
        }
        .overlay {
            if isSubmitting && databaseViewModel.isSaving == false {
                ZStack {
                    Color.black.opacity(0.14)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Saving changes...")
                            .font(.headline)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.regularMaterial)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saving changes")
                .accessibilityIdentifier("entry-edit.saving-overlay")
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

    /// The database's other tags, one tap each, wrapped under the tag field.
    /// Nothing at all renders when there is nothing left to offer — a database
    /// without tags, or an entry that already carries or inherits every one of
    /// them, shows the plain field with no empty husk below it.
    ///
    /// The strip carries a container identifier but is also declared an
    /// accessibility container, so the chips keep their own identifiers instead
    /// of inheriting the strip's (see `README.md`).
    @ViewBuilder
    private var tagSuggestionStrip: some View {
        let suggestions = formViewModel.tagSuggestions
        if suggestions.isEmpty == false {
            FlowLayout(spacing: 6) {
                // Enumerated for the identifier fallback index, which is what
                // gives an emoji-only tag — one that normalizes to nothing — a
                // usable identifier.
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, tag in
                    tagSuggestionChip(tag, fallbackIndex: index)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("entry-edit.tag-suggestions")
        }
    }

    private func tagSuggestionChip(_ tag: String, fallbackIndex: Int) -> some View {
        Button {
            formViewModel.appendTagSuggestion(tag)
        } label: {
            TagCapsule(tag: tag, systemImage: "plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add tag \(tag)"))
        .accessibilityIdentifier(
            "entry-edit.tag-suggestion.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    private var navigationTitle: String {
        switch formViewModel.mode {
        case .create:
            String(localized: "New Entry")
        case .edit:
            String(localized: "Edit Entry")
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

            isSubmitting = true
            Task { @MainActor in
                await databaseViewModel.saveHandlingError()
                isSubmitting = false
                if let saveError = databaseViewModel.saveError {
                    editingErrorMessage = saveError.localizedDescription
                    databaseViewModel.clearSaveError()
                } else {
                    onComplete(.finished)
                }
            }
        } catch {
            editingErrorMessage = error.localizedDescription
        }
    }

    private func deleteTapped(sendToRecycleBin: Bool) {
        guard case .edit(let entryID) = formViewModel.mode else { return }

        do {
            try databaseViewModel.deleteEntry(entryID, sendToRecycleBin: sendToRecycleBin)
            isSubmitting = true
            Task { @MainActor in
                await databaseViewModel.saveHandlingError()
                isSubmitting = false
                if let saveError = databaseViewModel.saveError {
                    editingErrorMessage = saveError.localizedDescription
                    databaseViewModel.clearSaveError()
                } else {
                    onComplete(.deleted)
                }
            }
        } catch {
            editingErrorMessage = error.localizedDescription
        }
    }
}
