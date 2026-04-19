import SwiftUI

struct UnlockView: View {
    @Bindable var viewModel: DatabaseViewModel
    let onBackToDatabaseList: () -> Void

    @State private var password = ""
    @State private var showKeyFilePicker = false
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var keyFileData: Data?
    @State private var keyFileName: String?
    @State private var feedbackContext: FeedbackComposerContext?
    @State private var copiedErrorDetails = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                headerCard

                contentSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(UnlockViewBackground())
        .scrollIndicators(.hidden)
        .fileImporter(
            isPresented: $showKeyFilePicker,
            allowedContentTypes: DocumentPickerService.keyFilePickerContentTypes,
            onCompletion: handleKeyFileSelection
        )
        .sheet(item: $feedbackContext) { context in
            FeedbackComposerView(context: context)
        }
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
        }
        .onChange(of: viewModel.openFailure?.errorCode) { _, _ in
            copiedErrorDetails = false
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 64, height: 64)

                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Open Database")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(viewModel.databaseDisplayName)
                        .font(.title.bold())
                        .multilineTextAlignment(.leading)

                    if viewModel.databaseDisplayName != viewModel.databaseFilename {
                        Text(viewModel.databaseFilename)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            if keyFileName != nil || viewModel.canUseBiometrics {
                VStack(alignment: .leading, spacing: 8) {
                    if let keyFileName {
                        Label(keyFileName, systemImage: "key.fill")
                            .lineLimit(1)
                    }

                    if viewModel.canUseBiometrics {
                        Label("Biometric unlock", systemImage: viewModel.biometricIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var contentSection: some View {
        if let failure = viewModel.openFailure {
            failureSection(failure)

            if failure.isAuthenticationFailure {
                passwordSection
            }
        } else if viewModel.hasSavedFile {
            passwordSection
        } else {
            unavailableSection
        }
    }

    private var passwordSection: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Master Password")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                SecureField("Enter password", text: $password)
                    .focused($passwordFocused)
                    .submitLabel(.go)
                    .onSubmit(unlockWithPassword)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .accessibilityIdentifier("unlock.password.field")
            }

            keyFileRow

            Button(action: unlockWithPassword) {
                Label("Unlock Database", systemImage: "lock.open.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled((password.isEmpty && keyFileData == nil) || isUnlocking)
            .accessibilityIdentifier("unlock.button")

            if viewModel.canUseBiometrics {
                Button(action: unlockWithBiometrics) {
                    Label(viewModel.biometricLabel, systemImage: viewModel.biometricIcon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(isUnlocking)
            }

            Button("Choose Different File") {
                onBackToDatabaseList()
            }
            .font(.footnote.weight(.medium))
            .accessibilityIdentifier("unlock.choose-different")
        }
    }

    private func failureSection(_ failure: DatabaseOpenFailure) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: failure.isAuthenticationFailure ? "lock.slash.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(failure.isAuthenticationFailure ? .orange : .red)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.title)
                        .font(.headline)

                    Text(failure.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Error Code")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(failure.errorCode)
                    .font(.caption.monospaced())

                Text(failure.technicalDetails)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button(action: retryUnlock) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("unlock.retry.button")

                if failure.isAuthenticationFailure == false {
                    Button(failure.canChooseDifferentFile ? "Choose Different File" : "Back to Database List") {
                        onBackToDatabaseList()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("unlock.choose-different")
                }

                HStack(spacing: 10) {
                    Button("Copy Error Details") {
                        copyErrorDetails(failure)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("unlock.copy-error")

                    Button("Send Feedback") {
                        feedbackContext = .databaseOpenFailure(failure)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("unlock.send-feedback")
                }
            }

            Label(failure.privacyNote, systemImage: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)

            if copiedErrorDetails {
                Text("Error details copied.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.red.opacity(0.15), lineWidth: 1)
        )
        .accessibilityIdentifier("unlock.error.card")
    }

    private var keyFileRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Key File")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label {
                    if let keyFileName {
                        Text(keyFileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("None selected")
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
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .accessibilityIdentifier("unlock.keyfile.row")
    }

    private var unavailableSection: some View {
        VStack(spacing: 16) {
            Text("This database is unavailable. Return to the database list to remove it or refresh its bookmark.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Back to Database List") { onBackToDatabaseList() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var isUnlocking: Bool {
        if case .unlocking = viewModel.state { return true }
        return false
    }

    private func retryUnlock() {
        if password.isEmpty == false || keyFileData != nil {
            unlockWithPassword()
            return
        }

        if viewModel.canUseBiometrics {
            unlockWithBiometrics()
            return
        }

        passwordFocused = true
    }

    private func copyErrorDetails(_ failure: DatabaseOpenFailure) {
        ClipboardService.copy(failure.copyableDetails)
        copiedErrorDetails = true
        HapticService.success()
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
                keyFileData = try CoordinatedFileReader.readData(from: url)
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

struct DatabaseOpeningView: View {
    let databaseName: String
    let statusMessage: String
    var progress: Double? = nil

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "lock.open.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
            }

            VStack(spacing: 6) {
                Text("Opening \(databaseName)")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let progress {
                ProgressView(value: progress)
                    .controlSize(.large)
                    .padding(.horizontal, 40)
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(UnlockViewBackground())
    }
}

struct UnlockViewBackground: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }
}
