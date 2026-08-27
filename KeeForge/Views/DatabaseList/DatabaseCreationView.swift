import SwiftUI

struct DatabaseCreationView: View {
    @Bindable var viewModel: DatabaseCreationViewModel
    let onCreated: (CreatedDatabase) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDestinationExporterPresented = false
    @State private var isCloudFolderPickerPresented = false
    @State private var isKeyFileImporterPresented = false
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var exportDocument = KDBXExportDocument(data: Data())
    @State private var isMasterPasswordVisible = false
    @State private var isConfirmPasswordVisible = false
    @State private var isAdvancedExpanded = false

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
                        viewModel.clearSecrets()
                        viewModel.clearPreparedDatabase()
                        dismiss()
                    }
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
                        case .dropbox, .oneDrive, .webDAV:
                            if viewModel.validateForDestinationSelection() {
                                isCloudFolderPickerPresented = true
                            }
                        }
                    }
                    .disabled(viewModel.isCreating)
                    .accessibilityIdentifier("database-create.create-button")
                }
            }
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
            isPresented: $isCloudFolderPickerPresented,
            onDismiss: cancelPendingCloudAuthentication
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
            Section {
                labeledField(String(localized: "Database name")) {
                    TextField("Database name", text: $viewModel.databaseName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("database-create.name-field")
                }
            } header: {
                Text("Database")
            } footer: {
                Text(destinationFooter)
            }

            Section {
                labeledField(String(localized: "Save To")) {
                    Picker("Save To", selection: $viewModel.destinationChoice) {
                        ForEach(DatabaseCreationDestinationChoice.availableChoices) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("database-create.destination-picker")
                }
            }

            Section {
                labeledField(String(localized: "Master password")) {
                    PasswordInputRow(
                        title: String(localized: "Master password"),
                        text: $viewModel.password,
                        isVisible: $isMasterPasswordVisible,
                        fieldAccessibilityIdentifier: "database-create.password-field",
                        visibilityAccessibilityIdentifier: "database-create.password-visibility-button",
                        usesPasswordAutoFill: false
                    )
                }

                labeledField(String(localized: "Confirm password")) {
                    PasswordInputRow(
                        title: String(localized: "Confirm password"),
                        text: $viewModel.confirmPassword,
                        isVisible: $isConfirmPasswordVisible,
                        fieldAccessibilityIdentifier: "database-create.confirm-password-field",
                        visibilityAccessibilityIdentifier: "database-create.confirm-password-visibility-button",
                        usesPasswordAutoFill: false
                    )
                }

                if let warning = viewModel.passwordStrengthWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Master Password")
            } footer: {
                Text("Choose a long, unique master password: it protects the entire database and cannot be recovered if forgotten.")
            }

            Section {
                labeledField(String(localized: "Selected")) {
                    Text(viewModel.keyFileSummary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    isKeyFileImporterPresented = true
                } label: {
                    Label("Select Key File", systemImage: "key")
                }
                .accessibilityIdentifier("database-create.keyfile.select")

                if viewModel.keyFileFilename != nil {
                    Button("Clear Key File", role: .destructive) {
                        viewModel.clearKeyFile()
                    }
                    .accessibilityIdentifier("database-create.keyfile.clear")
                }
            } header: {
                Text("Key File")
            }

            Section {
                DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                    Picker("Encryption", selection: $viewModel.cipher) {
                        ForEach(DatabaseCreationCipher.allCases) { cipher in
                            Text(cipher.displayName).tag(cipher)
                        }
                    }
                    .accessibilityIdentifier("database-create.cipher-picker")

                    Picker("Key Derivation", selection: $viewModel.kdfPreset) {
                        ForEach(DatabaseCreationKDFPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .accessibilityIdentifier("database-create.kdf-preset-picker")
                } label: {
                    Text("Advanced")
                }
                .accessibilityIdentifier("database-create.advanced-disclosure")
            } footer: {
                Text(advancedFooter)
            }
        }
        .macGroupedForm()
    }

    /// Top-aligned caption over its field, matching the entry/group editors.
    /// `macLabelsHidden` drops the field's own label so macOS does not reserve a
    /// leading label column that pushes multi-control rows off the sheet.
    private func labeledField<Content: View>(
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
        case .dropbox, .oneDrive, .webDAV:
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

    @MainActor
    private func cancelPendingCloudAuthentication() {
        for providerKind in CloudProviderRegistry.availableProviders {
            CloudProviderRegistry.provider(for: providerKind.rawValue)?.cancelPendingAuthentication()
        }
    }

    private var selectedCloudProvider: CloudProviderKind? {
        viewModel.destinationChoice.cloudProviderKind
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
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("database-create.error")
    }
}
