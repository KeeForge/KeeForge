import SwiftUI
import UniformTypeIdentifiers

struct UnlockView: View {
    @Bindable var viewModel: DatabaseViewModel
    let onBackToDatabaseList: () -> Void

    @State private var password = ""
    @State private var showKeyFilePicker = false
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var keyFileData: Data?
    @State private var keyFileName: String?
    @State private var autoUnlockAttemptedLockCycle: Int?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text(viewModel.databaseDisplayName)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                if viewModel.databaseDisplayName != viewModel.databaseFilename {
                    Text(viewModel.databaseFilename)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.hasSavedFile {
                passwordSection
            } else {
                unavailableSection
            }

            if let errorMessage = unlockErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .accessibilityIdentifier("unlock.error.label")
            }

            Spacer()
        }
        .padding()
        .fileImporter(
            isPresented: $showKeyFilePicker,
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
        .onAppear {
            loadAssociatedKeyFileIfNeeded()
            loadUITestKeyFileIfNeeded()
            autoUnlockWithBiometricsIfNeeded()
        }
        .onChange(of: viewModel.lockCycleID) { _, _ in
            autoUnlockWithBiometricsIfNeeded()
        }
        .onChange(of: viewModel.canUseBiometrics) { _, _ in
            autoUnlockWithBiometricsIfNeeded()
        }
    }

    private var passwordSection: some View {
        VStack(spacing: 16) {
            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .submitLabel(.go)
                .onSubmit(unlockWithPassword)
                .padding(.horizontal)
                .accessibilityIdentifier("unlock.password.field")

            keyFileRow

            Button(action: unlockWithPassword) {
                Label("Unlock", systemImage: "lock.open.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled((password.isEmpty && keyFileData == nil) || isUnlocking)
            .padding(.horizontal)
            .accessibilityIdentifier("unlock.button")

            if viewModel.canUseBiometrics {
                Button(action: unlockWithBiometrics) {
                    Label(viewModel.biometricLabel, systemImage: viewModel.biometricIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isUnlocking)
                .padding(.horizontal)
            }

            Button("Back to Database List") {
                onBackToDatabaseList()
            }
            .font(.footnote)
            .accessibilityIdentifier("unlock.choose-different")

            if isUnlocking {
                ProgressView("Decrypting...")
            }
        }
    }

    private var keyFileRow: some View {
        HStack {
            Label {
                if let keyFileName {
                    Text(keyFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "key.fill")
            }

            Spacer()

            if keyFileData != nil {
                Button {
                    keyFileData = nil
                    keyFileName = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear key file")
                .accessibilityIdentifier("unlock.keyfile.clear")
            }

            Button("Select") {
                selectionAlert = nil
                showKeyFilePicker = true
            }
            .font(.subheadline)
            .accessibilityIdentifier("unlock.keyfile.select")
        }
        .padding(.horizontal)
        .accessibilityIdentifier("unlock.keyfile.row")
    }

    private var unavailableSection: some View {
        VStack(spacing: 16) {
            Text("This database is unavailable. Return to the database list to remove it or refresh its bookmark.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Back to Database List") {
                onBackToDatabaseList()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var unlockErrorMessage: String? {
        if case .error(let message) = viewModel.state {
            return message
        }

        return nil
    }

    private var isUnlocking: Bool {
        if case .unlocking = viewModel.state { return true }
        return false
    }

    private func unlockWithPassword() {
        let pwd = password.isEmpty ? nil : password
        guard pwd != nil || keyFileData != nil else { return }
        Task {
            await viewModel.unlock(password: password, keyFileData: keyFileData)
            if case .unlocked = viewModel.state {
                password = ""
            }
        }
    }

    private func unlockWithBiometrics() {
        Task {
            await viewModel.unlockWithBiometrics()
        }
    }

    private func autoUnlockWithBiometricsIfNeeded() {
        guard SettingsService.autoUnlockWithFaceID else { return }
        guard viewModel.hasSavedFile else { return }
        guard viewModel.canUseBiometrics else { return }
        guard case .locked = viewModel.state else { return }
        guard !viewModel.didManuallyLock else { return }
        guard autoUnlockAttemptedLockCycle != viewModel.lockCycleID else { return }

        autoUnlockAttemptedLockCycle = viewModel.lockCycleID
        unlockWithBiometrics()
    }

    private func loadAssociatedKeyFileIfNeeded() {
        guard keyFileData == nil else { return }
        guard let associatedKeyFile = viewModel.loadAssociatedKeyFile() else { return }
        keyFileData = associatedKeyFile.data
        keyFileName = associatedKeyFile.filename
    }

    private func loadUITestKeyFileIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return }
        guard keyFileData == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard let base64 = env["UI_TEST_KEYFILE_BASE64"], !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return }
        keyFileData = data
        keyFileName = env["UI_TEST_KEYFILE_FILENAME"] ?? "test.key"
    }

    private func handleKeyFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                keyFileData = try Data(contentsOf: url)
                keyFileName = url.lastPathComponent
            } catch {
                keyFileData = nil
                keyFileName = nil
            }
        case .failure(let error):
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }
}
