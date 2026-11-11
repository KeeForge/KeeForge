import SwiftUI

struct DatabaseCreationView: View {
    @Bindable var viewModel: DatabaseCreationViewModel
    let onCreated: (CreatedDatabase) -> Void
    var onRecovered: (DatabaseReference) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var isDestinationExporterPresented = false
    @State private var isCloudFolderPickerPresented = false
    @State private var isKeyFileImporterPresented = false
    @State private var newKeyFile: KeyFileExportDocument?
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var exportDocument = KDBXExportDocument(data: Data())
    @State private var isMasterPasswordVisible = false
    @State private var isConfirmPasswordVisible = false

    var body: some View {
        NavigationStack {
            formContent
            .navigationTitle("New Database")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(viewModel.isCreating)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let errorMessage = viewModel.validationError ?? viewModel.creationError {
                    CreationErrorBanner(message: errorMessage)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }
            }
            .overlay {
                if viewModel.isCreating {
                    ProgressView("Creating Database")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelPendingCreation()
                        dismiss()
                    }
                    .disabled(viewModel.isCreating)
                    .accessibilityIdentifier("database-create.cancel-button")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        switch viewModel.destinationChoice {
                        case .files:
                            Task {
                                if await viewModel.prepareForExport() {
                                    if let uiTestingExportURL {
                                        completeUITestingExport(to: uiTestingExportURL)
                                    } else {
                                        exportDocument = KDBXExportDocument(data: viewModel.preparedEncryptedBytes)
                                        isDestinationExporterPresented = true
                                    }
                                }
                            }
                        case .dropbox, .oneDrive, .googleDrive, .webDAV, .ftp:
                            if viewModel.validateForDestinationSelection() {
                                isCloudFolderPickerPresented = true
                            }
                        }
                    }
                    .disabled(viewModel.isCreating || viewModel.isRecovering)
                    .accessibilityIdentifier("database-create.create-button")
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isCreating)
        .task { await viewModel.refreshPendingCreations() }
        .onDisappear {
            viewModel.cancelPendingCreation()
        }
        .fileExporter(
            isPresented: $isDestinationExporterPresented,
            document: exportDocument,
            contentType: DocumentPickerService.databaseContentType,
            defaultFilename: viewModel.preparedFilename,
            onCompletion: handleDestinationSelection
        )
        .fileImporter(
            isPresented: $isKeyFileImporterPresented,
            allowedContentTypes: DocumentPickerService.keyFilePickerContentTypes,
            onCompletion: handleKeyFileSelection
        )
        .sheet(
            isPresented: $isCloudFolderPickerPresented
        ) {
            CloudFolderPickerView(
                providerID: selectedCloudProvider?.rawValue ?? CloudProviderKind.dropbox.rawValue,
                onSelect: handleCloudFolderSelection,
                onFailure: { error in
                    let provider = selectedCloudProvider ?? .dropbox
                    selectionAlert = DocumentPickerService.SelectionAlert(
                        title: String(localized: "Couldn’t Open \(provider.displayName)"),
                        message: error.localizedDescription
                    )
                }
            )
        }
        .alert(item: $selectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var formContent: some View {
        Form {
            if !viewModel.pendingCreations.isEmpty || viewModel.recoveryMessage != nil {
                Section {
                    ForEach(viewModel.pendingCreations) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.filename)
                            Text(item.destination)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let issue = item.issue {
                                Text(issue).font(.caption)
                            }
                            if item.isPaused {
                                Text("Creation paused. Encrypted data is retained until the remote result is known.")
                                    .font(.caption)
                            }
                            Button("Resume Creation") {
                                Task {
                                    if let reference = await viewModel.resumeCreation(item) {
                                        onRecovered(reference)
                                        dismiss()
                                    }
                                }
                            }
                            .disabled(viewModel.isRecovering)
                            .accessibilityIdentifier("database-create.pending.resume")
                            Button("Cancel Creation", role: .destructive) {
                                Task { await viewModel.cancelCreation(item) }
                            }
                            .disabled(viewModel.isRecovering && viewModel.recoveringOperationID != item.id)
                            .accessibilityIdentifier("database-create.pending.cancel")
                        }
                    }
                    if let message = viewModel.recoveryMessage { Text(message) }
                } header: {
                    Text("Pending Cloud Creations")
                } footer: {
                    Text("Resuming registers the original encrypted database. Open it from the database list with its original password and key file.")
                }
            }
            Section {
                if PlatformDesign.followsIOSDesign {
                    LabeledContent("Database name") {
                        TextField("Database name", text: $viewModel.databaseName, prompt: Text("Required"))
                            .textInputAutocapitalization(.words)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Theme.labelSecondary)
                            .accessibilityIdentifier("database-create.name-field")
                    }
                } else {
                    macLabeledField(String(localized: "Database name")) {
                        TextField("Database name", text: $viewModel.databaseName)
                            .accessibilityIdentifier("database-create.name-field")
                    }
                }

                // A menu, not segments: five destinations truncate as segments on iPhone.
                Picker("Save To", selection: $viewModel.destinationChoice) {
                    ForEach(DatabaseCreationDestinationChoice.availableChoices) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .pickerStyle(.menu)
                #if os(iOS)
                .tint(Theme.labelSecondary)
                #endif
                .accessibilityIdentifier("database-create.destination-picker")
            } header: {
                Text("Database")
            } footer: {
                if let filename = viewModel.filenamePreview {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Filename: \(filename)")
                            .accessibilityIdentifier("database-create.filename")
                        if viewModel.showsFilenameReplacementExplanation {
                            Text("Unsupported filename characters are replaced with _.")
                                .accessibilityIdentifier("database-create.filename-explanation")
                        }
                    }
                }
            }

            Section {
                passwordRow(
                    String(localized: "Master password"),
                    text: $viewModel.password,
                    isVisible: $isMasterPasswordVisible,
                    identifierPrefix: "database-create.password"
                )

                passwordRow(
                    String(localized: "Confirm password"),
                    text: $viewModel.confirmPassword,
                    isVisible: $isConfirmPasswordVisible,
                    identifierPrefix: "database-create.confirm-password"
                )

                if viewModel.password.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        PasswordStrengthIndicator(password: viewModel.password, caption: .passwordStrength)
                        if let warning = viewModel.passwordStrengthWarning {
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(Theme.State.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Master Password")
            } footer: {
                Text("Choose a long, unique master password: it protects the entire database and cannot be recovered if forgotten.")
            }

            Section {
                if let keyFileFilename = viewModel.keyFileFilename {
                    LabeledContent("Selected", value: keyFileFilename)
                }

                Button {
                    isKeyFileImporterPresented = true
                } label: {
                    Label(viewModel.keyFileFilename == nil ? "Select Key File" : "Change Key File", systemImage: "key.horizontal")
                }
                .accessibilityIdentifier("database-create.keyfile.select")

                Button {
                    createKeyFile()
                } label: {
                    Label("Create Key File", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("database-create.keyfile.create")

                if viewModel.keyFileFilename != nil {
                    Button("Clear Key File", role: .destructive) {
                        viewModel.clearKeyFile()
                    }
                    .accessibilityIdentifier("database-create.keyfile.clear")
                }
            } header: {
                Text("Key File")
            } footer: {
                Text("Create Key File saves a new key file where you choose. Keep a copy somewhere safe: without the key file, the database can’t be opened.")
            }
            .fileExporter(
                isPresented: Binding(
                    get: { newKeyFile != nil },
                    set: { if $0 == false { newKeyFile = nil } }
                ),
                document: newKeyFile,
                contentType: KeyFileExportDocument.contentType,
                defaultFilename: KeyFileExportDocument.defaultFilename(forDatabaseFilename: viewModel.suggestedFilename),
                onCompletion: handleKeyFileCreation
            )

            Section {
                Picker("Encryption", selection: $viewModel.cipher) {
                    ForEach(DatabaseCreationCipher.allCases) { cipher in
                        Text(cipher.displayName).tag(cipher)
                    }
                }
                .pickerStyle(.menu)
                #if os(iOS)
                .tint(Theme.labelSecondary)
                #endif
                .accessibilityIdentifier("database-create.cipher-picker")

                Picker("Key Derivation", selection: $viewModel.kdfPreset) {
                    ForEach(DatabaseCreationKDFPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                #if os(iOS)
                .tint(Theme.labelSecondary)
                #endif
                .accessibilityIdentifier("database-create.kdf-preset-picker")
            } header: {
                Text("Advanced")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(advancedFooter)
                    Text(destinationFooter)
                }
            }
        }
        .macGroupedForm()
    }

    @ViewBuilder
    private func passwordRow(
        _ title: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        identifierPrefix: String
    ) -> some View {
        let row = PasswordInputRow(
            title: title,
            text: text,
            isVisible: isVisible,
            fieldAccessibilityIdentifier: "\(identifierPrefix)-field",
            visibilityAccessibilityIdentifier: "\(identifierPrefix)-visibility-button",
            usesPasswordAutoFill: false
        )
        if PlatformDesign.followsIOSDesign {
            row.tint(Theme.labelSecondary)
        } else {
            macLabeledField(title) { row }
        }
    }

    // A macOS grouped form hides a field's own label, so the title sits above a bordered field.
    private func macLabeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
                .macLabelsHidden()
                .macFormFieldStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var advancedFooter: String {
        let cipherName = viewModel.cipher.displayName
        let kdfSummary = viewModel.kdfPreset.parameterSummary
        #if os(macOS)
        return String(localized: "KeeForge creates KDBX 4 databases encrypted with \(cipherName) and Argon2id key derivation (\(kdfSummary)). Stronger settings take longer to unlock.")
        #else
        return String(localized: "KeeForge creates KDBX 4 databases encrypted with \(cipherName) and Argon2id key derivation (\(kdfSummary)). Stronger settings take longer to unlock and may exceed AutoFill's memory limit on some devices.")
        #endif
    }

    private var destinationFooter: String {
        switch viewModel.destinationChoice {
        case .files:
            #if os(macOS)
            return String(localized: "After you click Create, KeeForge asks where to save the encrypted .kdbx database.")
            #else
            return String(localized: "After you tap Create, Files will ask where to save the encrypted .kdbx database.")
            #endif
        case .dropbox, .oneDrive, .googleDrive, .webDAV, .ftp:
            let providerName = selectedCloudProvider?.displayName ?? String(localized: "cloud")
            #if os(macOS)
            return String(localized: "After you click Create, choose the \(providerName) folder for the encrypted .kdbx database.")
            #else
            return String(localized: "After you tap Create, choose the \(providerName) folder for the encrypted .kdbx database.")
            #endif
        }
    }

    private func handleDestinationSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let created = try viewModel.completeExport(to: url)
                onCreated(created)
                dismiss()
            } catch {
                viewModel.creationError = error.localizedDescription
            }
        case .failure(let error):
            viewModel.clearPreparedDatabase()
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }

    private var uiTestingExportURL: URL? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return nil }
        guard let rawValue = ProcessInfo.processInfo.environment["UI_TEST_DATABASE_CREATION_EXPORT_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            rawValue.isEmpty == false
        else {
            return nil
        }

        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue)
        }

        return FileManager.default.temporaryDirectory
            .appendingPathComponent(rawValue, isDirectory: false)
        #else
        return nil
        #endif
    }

    private func completeUITestingExport(to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try viewModel.preparedEncryptedBytes.write(to: url, options: .atomic)
            let created = try viewModel.completeExport(to: url)
            onCreated(created)
            dismiss()
        } catch {
            viewModel.clearPreparedDatabase()
            viewModel.creationError = error.localizedDescription
        }
    }

    private func handleCloudFolderSelection(_ selection: CloudFolderSelection) {
        Task {
            if let created = await viewModel.createInCloud(
                provider: selection.provider,
                accountID: selection.account.id,
                folderPath: selection.folderPath
            ) {
                onCreated(created)
                dismiss()
            }
        }
    }

    private var selectedCloudProvider: CloudProviderKind? {
        viewModel.destinationChoice.cloudProviderKind
    }

    private func createKeyFile() {
        do {
            newKeyFile = try KeyFileExportDocument.generate()
        } catch {
            selectionAlert = KeyFileExportDocument.creationFailureAlert(for: error)
        }
    }

    private func handleKeyFileCreation(_ result: Result<URL, Error>) {
        newKeyFile = nil
        switch result {
        case .success(let url):
            handleKeyFileSelection(.success(url))
        case .failure(let error):
            selectionAlert = KeyFileExportDocument.creationFailureAlert(for: error)
        }
    }

    private func handleKeyFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try viewModel.selectKeyFile(url: url)
            } catch {
                selectionAlert = DocumentPickerService.fileAccessFailureAlert(for: error)
            }
        case .failure(let error):
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }
}

private struct CreationErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(Theme.State.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.State.dangerSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.State.danger.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("database-create.error")
    }
}
