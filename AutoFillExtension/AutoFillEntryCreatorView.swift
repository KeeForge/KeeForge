// Save-password requests are iOS-only (`ASSavePasswordRequest` is
// `API_UNAVAILABLE(macos)` per the macOS 26.5 SDK), so this creator UI — plus
// its iOS-only text-input modifiers such as `.textContentType(.URL)` — is
// gated to iOS. The macOS shell stubs `presentEntryCreator` as unreachable.
#if os(iOS)
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

    /// Save-password requests carry the password the user already typed into
    /// the form, so editing it there would desync the entry from what the site
    /// received. Only the picker-initiated flow, where no password exists yet,
    /// unlocks the field and its generate button.
    let allowsPasswordEditing: Bool
    let onSave: @Sendable (EntryDraftPayload) async -> AutoFillEntryCreatorActionResult
    let onCancel: () -> Void

    @State private var draft: EntryDraftPayload
    @State private var isSaving = false
    @State private var isPasswordVisible = false
    @State private var inlineWarningMessage: String?
    @State private var alertState: AlertState?

    init(
        initialDraft: EntryDraftPayload,
        allowsPasswordEditing: Bool = false,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> AutoFillEntryCreatorActionResult,
        onCancel: @escaping () -> Void
    ) {
        self.allowsPasswordEditing = allowsPasswordEditing
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

                Section("Basics") {
                    basicFieldRow(String(localized: "Title")) {
                        TextField("Title", text: $draft.title)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("autofill-entry-creator.title-field")
                    }

                    basicFieldRow(String(localized: "Username")) {
                        TextField("Username", text: $draft.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("autofill-entry-creator.username-field")
                    }

                    basicFieldRow(String(localized: "Password")) {
                        if allowsPasswordEditing {
                            PasswordInputRow(
                                title: String(localized: "Password"),
                                text: $draft.password,
                                isVisible: $isPasswordVisible,
                                fieldAccessibilityIdentifier: "autofill-entry-creator.password-field",
                                visibilityAccessibilityIdentifier: "autofill-entry-creator.password-visibility",
                                // Labelled, not trailing: `onVisibilityToggle`
                                // precedes `actions` and also takes a closure,
                                // so a trailing one binds there and the button
                                // silently never renders.
                                actions: {
                                    Button {
                                        draft.password = PasswordGenerator.generate()
                                    } label: {
                                        Image(systemName: "dice.fill")
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Generate password")
                                    .accessibilityIdentifier("autofill-entry-creator.password-generator-button")
                                }
                            )
                        } else {
                            SecureField("Password", text: $draft.password)
                                .passwordInputStyle()
                                .disabled(true)
                                .accessibilityIdentifier("autofill-entry-creator.password-field")
                        }
                    }

                    basicFieldRow(String(localized: "URL")) {
                        TextField("URL", text: $draft.url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .accessibilityIdentifier("autofill-entry-creator.url-field")
                    }
                }

                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("autofill-entry-creator.notes-field")
                }
            }
            .navigationTitle("New Credential")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier("autofill-entry-creator.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save and Fill") {
                            Task {
                                await save()
                            }
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("autofill-entry-creator.save-and-fill")
                    }
                }
            }
        }
        .alert(item: $alertState) { state in
            Alert(
                title: Text(state.kind == .warningAndCancel ? "Database Changed" : "Couldn't Save"),
                message: Text(state.message),
                dismissButton: .default(Text("OK")) {
                    if state.kind == .warningAndCancel {
                        onCancel()
                    }
                }
            )
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

#endif
