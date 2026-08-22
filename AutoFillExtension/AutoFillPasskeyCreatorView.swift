import SwiftUI

struct AutoFillPasskeyCreatorView: View {
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

    let context: CredentialProviderPasskeyCreatorContext
    let onSave: @Sendable (String) async -> CredentialProviderEntrySaveOutcome
    let onCancel: () -> Void

    @State private var title: String
    @State private var isSaving = false
    @State private var inlineWarningMessage: String?
    @State private var alertState: AlertState?

    init(
        context: CredentialProviderPasskeyCreatorContext,
        onSave: @escaping @Sendable (String) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    ) {
        self.context = context
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: context.initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let inlineWarningMessage {
                    Section {
                        Text(inlineWarningMessage)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("autofill-passkey-creator.database-changed-warning")
                    }
                }

                Section {
                    LabeledContent("Website", value: context.relyingPartyIdentifier)
                        .accessibilityIdentifier("autofill-passkey-creator.relying-party")
                    LabeledContent("Username", value: context.userName)
                        .accessibilityIdentifier("autofill-passkey-creator.username")
                    LabeledContent("Database", value: context.databaseName)
                        .accessibilityIdentifier("autofill-passkey-creator.database")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        titleField
                            .accessibilityIdentifier("autofill-passkey-creator.title-field")
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("New Passkey")
            .passkeyNavigationTitleStyle()
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier("autofill-passkey-creator.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save Passkey") {
                            Task {
                                await save()
                            }
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("autofill-passkey-creator.save")
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

    @ViewBuilder
    private var titleField: some View {
        #if os(iOS)
        TextField("Title", text: $title)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        #else
        TextField("Title", text: $title)
        #endif
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        inlineWarningMessage = nil
        defer {
            isSaving = false
        }

        switch await onSave(title) {
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

private extension View {
    @ViewBuilder
    func passkeyNavigationTitleStyle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
