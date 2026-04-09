import SwiftUI

enum AutoFillEntryCreatorActionResult {
    case completed
    case showWarningAndCancel(String)
    case showError(String)
}

struct AutoFillEntryCreatorView: View {
    private struct AlertState: Identifiable {
        enum Kind {
            case warningAndCancel
            case error
        }

        let kind: Kind
        let message: String

        var id: String {
            "\(kind)-\(message)"
        }
    }

    let onSave: @Sendable (EntryDraftPayload) async -> AutoFillEntryCreatorActionResult
    let onCancel: () -> Void

    @State private var draft: EntryDraftPayload
    @State private var isSaving = false
    @State private var isEditingPasswordManually = false
    @State private var inlineWarningMessage: String?
    @State private var alertState: AlertState?

    init(
        initialDraft: EntryDraftPayload,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> AutoFillEntryCreatorActionResult,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let inlineWarningMessage {
                    Section {
                        Text(inlineWarningMessage)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("autofill-entry-creator.database-changed-warning")
                    }
                }

                Section("Entry") {
                    TextField("Title", text: $draft.title)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("autofill-entry-creator.title-field")

                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("autofill-entry-creator.username-field")

                    SecureField("Password", text: $draft.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isEditingPasswordManually == false)
                        .accessibilityIdentifier("autofill-entry-creator.password-field")

                    HStack {
                        Button("Regenerate") {
                            regeneratePassword()
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("autofill-entry-creator.regenerate-password")

                        Spacer()

                        Button("Edit Manually") {
                            isEditingPasswordManually = true
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("autofill-entry-creator.edit-password-manually")
                    }

                    TextField("URL", text: $draft.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("autofill-entry-creator.url-field")
                }

                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("autofill-entry-creator.notes-field")
                }

                Section {
                    Button {
                        Task {
                            await save()
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Save and Fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("autofill-entry-creator.save-and-fill")

                    Button("Cancel", role: .cancel, action: onCancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier("autofill-entry-creator.cancel")
                }
            }
            .navigationTitle("New Credential")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert(item: $alertState) { state in
            Alert(
                title: Text(state.kind == .warningAndCancel ? "Database Changed" : "Couldn’t Save"),
                message: Text(state.message),
                dismissButton: .default(Text("OK")) {
                    if state.kind == .warningAndCancel {
                        onCancel()
                    }
                }
            )
        }
    }

    private func regeneratePassword() {
        draft.password = PasswordGenerator.generate()
        isEditingPasswordManually = false
    }

    private func save() async {
        isSaving = true
        inlineWarningMessage = nil
        defer {
            isSaving = false
        }

        switch await onSave(draft) {
        case .completed:
            break
        case .showWarningAndCancel(let message):
            inlineWarningMessage = message
            alertState = AlertState(kind: .warningAndCancel, message: message)
        case .showError(let message):
            alertState = AlertState(kind: .error, message: message)
        }
    }
}
