import LocalAuthentication
import SwiftUI

/// Change the master key (password and/or key file) of the unlocked database.
/// Pushed from `DatabaseDetailsView`'s Master Key section, so it lives inside
/// the details sheet's `NavigationStack` — never a nested sheet. Hosts its own
/// `.fileImporter`, following the details sheet's session-context wiring (the
/// list's `onSelectKeyFile` closure never applies here because this screen is
/// only reachable with a `sessionViewModel`).
struct MasterKeyChangeView: View {
    private let sessionViewModel: DatabaseViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MasterKeyChangeViewModel
    @State private var isNewPasswordVisible = false
    @State private var isConfirmPasswordVisible = false
    @State private var isKeyFileImporterPresented = false
    @State private var isAuthenticating = false
    @State private var isChangeConfirmationPresented = false
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?

    init(sessionViewModel: DatabaseViewModel) {
        self.sessionViewModel = sessionViewModel
        let reference = sessionViewModel.databaseReference
        _viewModel = State(
            initialValue: MasterKeyChangeViewModel(
                currentKeyFileFilename: reference.keyFileFilename,
                currentKeyFileBookmarkData: reference.keyFileBookmarkData,
                sessionKeyFileData: sessionViewModel.sessionKeyFileData,
                loadCurrentKeyFile: { [weak sessionViewModel] in
                    await sessionViewModel?.loadAssociatedKeyFile()
                },
                changeOperation: { [weak sessionViewModel] password, keyFileData, bookmarkData, filename in
                    guard let sessionViewModel else {
                        throw DatabaseViewModel.RekeyError.sessionUnavailable
                    }
                    try await sessionViewModel.changeMasterKey(
                        newPassword: password,
                        newKeyFileData: keyFileData,
                        newKeyFileBookmarkData: bookmarkData,
                        newKeyFileFilename: filename
                    )
                }
            )
        )
    }

    var body: some View {
        Form {
            passwordSection
            keyFileSection
        }
        .disabled(viewModel.isWorking)
        .navigationTitle("Master Key")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = viewModel.validationError ?? viewModel.changeError {
                MasterKeyErrorBanner(message: errorMessage)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
        }
        .overlay {
            if viewModel.isWorking {
                ProgressView("Changing Master Key")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    viewModel.cancelPendingChange()
                    dismiss()
                }
                .disabled(viewModel.isWorking)
                .accessibilityIdentifier("master-key.cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    handleSaveTap()
                }
                .disabled(viewModel.isWorking || isAuthenticating)
                .accessibilityIdentifier("master-key.save")
            }
        }
        .fileImporter(
            isPresented: $isKeyFileImporterPresented,
            allowedContentTypes: DocumentPickerService.keyFilePickerContentTypes,
            onCompletion: handleKeyFileSelection
        )
        .alert(item: $selectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            isRemovingPassword ? Text("Save Without a Master Password?") : Text("Change Master Key?"),
            isPresented: $isChangeConfirmationPresented
        ) {
            Button(role: .destructive) {
                authenticateAndPerformChange()
            } label: {
                if isRemovingPassword {
                    Text("Save Without Password")
                } else {
                    Text("Change Master Key")
                }
            }
            .accessibilityIdentifier("master-key.confirm-change")

            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("master-key.cancel-change")
        } message: {
            if isRemovingPassword {
                Text("This permanently re-encrypts the database file. It will open only with the new master key — if the new master password or key file is lost, the data in it cannot be recovered.")
                    + Text(verbatim: " ")
                    + Text("The database will require only the key file to unlock. Anyone with the key file can open it.")
            } else {
                Text("This permanently re-encrypts the database file. It will open only with the new master key — if the new master password or key file is lost, the data in it cannot be recovered.")
            }
        }
        .onDisappear {
            viewModel.cancelPendingChange()
        }
    }

    private var passwordSection: some View {
        Section {
            PasswordInputRow(
                title: String(localized: "Master password"),
                text: $viewModel.newPassword,
                isVisible: $isNewPasswordVisible,
                fieldAccessibilityIdentifier: "master-key.new-password-field",
                visibilityAccessibilityIdentifier: "master-key.new-password-visibility-button"
            )

            PasswordInputRow(
                title: String(localized: "Confirm password"),
                text: $viewModel.confirmPassword,
                isVisible: $isConfirmPasswordVisible,
                fieldAccessibilityIdentifier: "master-key.confirm-password-field",
                visibilityAccessibilityIdentifier: "master-key.confirm-password-visibility-button"
            )

            if let warning = viewModel.passwordStrengthWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Master Password")
        } footer: {
            Text("The new master key protects this database file from now on. Backups and copies made before the change still open with the previous master key.")
        }
    }

    private var keyFileSection: some View {
        Section {
            LabeledContent("Selected", value: viewModel.keyFileSummary)

            Button {
                isKeyFileImporterPresented = true
            } label: {
                Label("Select Key File", systemImage: "key")
            }
            .accessibilityIdentifier("master-key.keyfile.select")

            if viewModel.hasEffectiveKeyFile {
                Button("Clear Key File", role: .destructive) {
                    viewModel.clearKeyFile()
                }
                .accessibilityIdentifier("master-key.keyfile.clear")
            }
        } header: {
            Text("Key File")
        } footer: {
            if viewModel.hasEffectiveKeyFile {
                Text("The database requires this key file after the change. Clear it to unlock with the master password only.")
            } else {
                Text("No key file will be required after the change. The master password alone will unlock the database.")
            }
        }
    }

    private var isRemovingPassword: Bool {
        viewModel.newPassword.isEmpty
    }

    private func handleSaveTap() {
        guard viewModel.validate() else { return }
        isChangeConfirmationPresented = true
    }

    private func authenticateAndPerformChange() {
        guard isAuthenticating == false, viewModel.isWorking == false else { return }
        viewModel.isCancelled = false
        guard viewModel.validate() else { return }

        if BiometricService.canAuthenticateDeviceOwner {
            isAuthenticating = true
            Task {
                await MainActor.run {
                    BiometricService.isBiometricAuthInProgress = true
                }
                do {
                    _ = try await BiometricService.authenticateDeviceOwner(
                        reason: String(localized: "Change master key")
                    )
                    await performChange()
                } catch {
                    // A user-initiated cancel needs no explanation; anything
                    // else (system cancel, timeout) must not look like success.
                    if (error as? LAError)?.code != .userCancel {
                        await MainActor.run {
                            viewModel.changeError = String(localized: "Authentication didn't complete. The master key was not changed.")
                        }
                    }
                }
                await MainActor.run {
                    BiometricService.isBiometricAuthInProgress = false
                    isAuthenticating = false
                }
            }
        } else {
            Task {
                await performChange()
            }
        }
    }

    private func performChange() async {
        if await viewModel.performChange() {
            HapticService.success()
            dismiss()
        }
    }

    private func handleKeyFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try viewModel.selectKeyFile(url: url)
            } catch {
                selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
            }
        case .failure(let error):
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }
}

private struct MasterKeyErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("master-key.error")
    }
}
