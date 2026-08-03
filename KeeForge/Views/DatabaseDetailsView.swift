import SwiftUI

/// Per-database settings and file facts, shared by the two places that show
/// them: the database list (long-press → Database Details) and the unlocked
/// database's toolbar gear button.
///
/// The two contexts differ only in what they can reach. The list owns the
/// app's `DatabaseListViewModel` and its own key-file importer; the unlocked
/// database owns a `DatabaseViewModel` session and has no App Settings entry
/// point of its own. Everything else — identity, editing, AutoFill, key file,
/// metadata, file header, cloud sync — is identical, which is why this view
/// exists instead of two that drift apart.
struct DatabaseDetailsView: View {
    let reference: DatabaseReference
    /// Non-nil only when opened from an unlocked database. Nickname and
    /// read-only changes route through it so the open session refreshes its
    /// own copy of the reference, and its presence adds the App Settings link.
    var sessionViewModel: DatabaseViewModel?
    /// Supplied by the database list, which owns the key-file importer so the
    /// picker is not presented from inside this sheet. When nil this view
    /// presents its own.
    var onSelectKeyFile: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var listViewModel: DatabaseListViewModel
    @State private var nickname = ""
    @State private var isQuickLaunch = false
    @State private var fileInfo: DatabaseFileInfo?
    @State private var isLoadingFileInfo = true
    @State private var showKeyFilePicker = false
    @State private var showAppSettings = false

    /// True when this view created its own `DatabaseListViewModel` because the
    /// caller could not reach the app's, and therefore has to install the
    /// AutoFill republish bridge itself.
    private let ownsListViewModel: Bool

    init(
        reference: DatabaseReference,
        listViewModel: DatabaseListViewModel? = nil,
        sessionViewModel: DatabaseViewModel? = nil,
        onSelectKeyFile: (() -> Void)? = nil
    ) {
        self.reference = reference
        self.sessionViewModel = sessionViewModel
        self.onSelectKeyFile = onSelectKeyFile
        self.ownsListViewModel = listViewModel == nil
        _listViewModel = State(initialValue: listViewModel ?? DatabaseListViewModel())
    }

    private var currentReference: DatabaseReference {
        listViewModel.databases.first(where: { $0.id == reference.id }) ?? reference
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                editingSection
                autoFillSection
                keyFileSection
                masterKeySection
                metadataSection
                databaseFileSection
                cloudSyncSection
                appSettingsSection
            }
            .navigationTitle(currentReference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                fileInfo = await DatabaseFileInfoLoader.load(for: currentReference)
                isLoadingFileInfo = false
            }
            .onAppear {
                installAutoFillBridgeIfNeeded()
                syncFormStateFromCurrentReference()
            }
            .onChange(of: currentReference.nickname) { _, _ in
                syncFormStateFromCurrentReference()
            }
            .onChange(of: nickname) { _, _ in
                saveNickname()
            }
            .onChange(of: currentReference.isQuickLaunch) { _, newValue in
                isQuickLaunch = newValue
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        saveNickname()
                        dismiss()
                    }
                    .accessibilityIdentifier("database-details.close")
                }
            }
            .fileImporter(
                isPresented: $showKeyFilePicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    try? listViewModel.setKeyFile(url: url, for: reference)
                }
            }
            .sheet(isPresented: $showAppSettings) {
                SettingsView(viewModel: sessionViewModel, listViewModel: listViewModel)
            }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            LabeledContent("Name", value: currentDisplayName)

            LabeledContent("Custom Name") {
                TextField("Use filename", text: $nickname)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .onSubmit(saveNickname)
                    .accessibilityIdentifier("database-details.nickname-field")
            }

            LabeledContent("Filename", value: currentReference.filename)

            Toggle("Quick Launch", isOn: $isQuickLaunch)
                .onChange(of: isQuickLaunch) { _, newValue in
                    guard newValue != currentReference.isQuickLaunch else { return }
                    listViewModel.toggleQuickLaunch(for: reference)
                    isQuickLaunch = currentReference.isQuickLaunch
                }
                .accessibilityIdentifier("database-details.quick-launch-toggle")
        } header: {
            Text("Identity")
        } footer: {
            Text("Quick Launch opens this database automatically on app launch.")
        }
    }

    private var editingSection: some View {
        Section {
            Toggle(
                "Read-only",
                isOn: Binding(
                    get: { isReadOnly },
                    set: { setReadOnly($0) }
                )
            )
            .disabled(isFormatReadOnly)
            .accessibilityIdentifier("database-row.read-only-toggle")
        } header: {
            Text("Editing")
        } footer: {
            Text(
                isFormatReadOnly
                    ? "Legacy KDBX 3.1 databases can be opened, but KeeForge intentionally keeps them read-only."
                    : "You can still open this database, but create, edit, and delete actions stay blocked until you turn editing back on."
            )
            .accessibilityIdentifier("database-details.read-only-footer")
        }
    }

    private var autoFillSection: some View {
        Section {
            Toggle(
                "Include in AutoFill",
                isOn: Binding(
                    get: { currentReference.autoFillEnabled },
                    set: { listViewModel.setAutoFillEnabled($0, for: reference) }
                )
            )
            .accessibilityIdentifier("database-details.autofill-toggle")
        } header: {
            Text("AutoFill")
        } footer: {
            Text("When off, passwords, passkeys, and verification codes from this database are neither suggested nor available in AutoFill. After you turn it back on, suggestions return the next time you unlock this database.")
        }
    }

    private var keyFileSection: some View {
        Section {
            LabeledContent("Associated File", value: currentReference.keyFileFilename ?? "None")

            Button("Select Key File") {
                if let onSelectKeyFile {
                    onSelectKeyFile()
                } else {
                    showKeyFilePicker = true
                }
            }
            .accessibilityIdentifier("database-details.key-file-select")

            if currentReference.keyFileFilename != nil {
                Button("Clear Key File", role: .destructive) {
                    try? listViewModel.setKeyFile(url: nil, for: reference)
                }
            }
        } header: {
            Text("Key File")
        } footer: {
            Text("KeeForge remembers this key file and prefills it when unlocking. To change the key file the database requires, change the master key.")
        }
    }

    @ViewBuilder
    private var masterKeySection: some View {
        if let sessionViewModel {
            Section {
                NavigationLink {
                    MasterKeyChangeView(sessionViewModel: sessionViewModel)
                } label: {
                    Text("Change Master Key…")
                }
                .disabled(isReadOnly)
                .accessibilityIdentifier("database-details.change-master-key")
            } header: {
                Text("Master Key")
            } footer: {
                Text("Changing the master key re-encrypts this database file with a new master password and/or key file.")
            }
        }
    }

    private var metadataSection: some View {
        Section("Metadata") {
            LabeledContent("Added", value: dateText(currentReference.addedAt))

            if let lastOpenedAt = currentReference.lastOpenedAt {
                LabeledContent("Last Opened", value: dateText(lastOpenedAt))
            }
        }
    }

    private var databaseFileSection: some View {
        Section {
            databaseFileRows
        } header: {
            Text("Database File")
        } footer: {
            if currentReference.isCloudBacked {
                Text("Values reflect the locally cached copy of this database.")
            }
        }
    }

    @ViewBuilder
    private var cloudSyncSection: some View {
        if let cloudState = listViewModel.cloudState(for: reference),
           let metadata = currentReference.cloudSyncMetadata {
            Section {
                LabeledContent("Provider") {
                    HStack(spacing: 6) {
                        CloudProviderIcon(provider: metadata.providerKind)
                        Text(cloudState.providerName)
                    }
                    .lineLimit(1)
                }

                LabeledContent("Account") {
                    Text(cloudState.accountLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("Path") {
                    Text(metadata.displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                }

                if let remoteModifiedAt = metadata.remoteModifiedAt {
                    LabeledContent("Remote Modified", value: dateText(remoteModifiedAt))
                }

                if let lastSyncedAt = metadata.lastSyncedAt {
                    LabeledContent("Last Sync", value: dateText(lastSyncedAt))
                }

                LabeledContent("Status", value: cloudState.warningText ?? "Healthy")
            } header: {
                Text("Cloud Sync")
            } footer: {
                if cloudState.isConnected {
                    Text("Cloud databases are cached locally and refreshed whenever you open them in the main app. AutoFill uses the cached copy only.")
                } else {
                    Text("This account is disconnected. KeeForge keeps the cached copy until you remove the database.")
                }
            }
        }
    }

    /// Only the unlocked database needs this: the database list reaches App
    /// Settings from its own toolbar.
    @ViewBuilder
    private var appSettingsSection: some View {
        if sessionViewModel != nil {
            Section {
                #if os(macOS)
                SettingsLink {
                    Text("App Settings")
                }
                #else
                Button("App Settings") {
                    showAppSettings = true
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private var databaseFileRows: some View {
        if let fileInfo {
            if let summary = fileInfo.summary {
                LabeledContent("Format", value: summary.formatDisplayName)
                    .accessibilityIdentifier("database-details.file-format")
            }

            if let sizeBytes = fileInfo.fileSizeBytes {
                LabeledContent("Size", value: sizeBytes.formatted(.byteCount(style: .file)))
                    .accessibilityIdentifier("database-details.file-size")
            }

            if let modifiedAt = fileInfo.modifiedAt {
                LabeledContent("Modified", value: dateText(modifiedAt))
            }

            if let summary = fileInfo.summary {
                LabeledContent("Encryption", value: summary.cipherDisplayName)
                    .accessibilityIdentifier("database-details.encryption")

                LabeledContent("Key Derivation") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(summary.keyDerivationDisplayName)
                        if let detail = summary.keyDerivationDetailText {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("database-details.key-derivation")

                LabeledContent("Compression", value: summary.compressionDisplayName)
                    .accessibilityIdentifier("database-details.compression")
            }
        } else if isLoadingFileInfo {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading database file…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("File details are unavailable.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Read-only

    /// KDBX 3.1 is read-only whatever the stored flag says. An open session
    /// knows this from the parsed header; from the list the plaintext header
    /// summary reports the same format version, so both contexts can disable
    /// the toggle rather than offering an edit mode that the savers reject.
    private var isFormatReadOnly: Bool {
        if let sessionViewModel {
            return sessionViewModel.isFormatReadOnly
        }
        return fileInfo?.summary?.formatVersion.requiresReadOnlyMode ?? false
    }

    private var isReadOnly: Bool {
        currentReference.isReadOnly || isFormatReadOnly
    }

    private func setReadOnly(_ newValue: Bool) {
        if let sessionViewModel {
            sessionViewModel.setReadOnly(newValue)
            listViewModel.reload()
        } else {
            listViewModel.setReadOnly(newValue, for: reference)
        }
    }

    // MARK: - Helpers

    /// Mirrors the bridge `AppRootView` installs on the app's shared list view
    /// model, so enabling AutoFill for the database that is currently unlocked
    /// republishes its identities immediately instead of waiting for the next
    /// unlock.
    private func installAutoFillBridgeIfNeeded() {
        guard ownsListViewModel, listViewModel.autoFillEnabledRefreshHandler == nil else { return }
        let sessionViewModel = sessionViewModel
        listViewModel.autoFillEnabledRefreshHandler = { databaseID in
            guard let sessionViewModel,
                  sessionViewModel.databaseReference.id == databaseID else { return }
            sessionViewModel.populateCredentialStoreIfUnlocked()
        }
    }

    private func syncFormStateFromCurrentReference() {
        nickname = currentReference.nickname ?? ""
        isQuickLaunch = currentReference.isQuickLaunch
    }

    private func saveNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNickname = trimmed.isEmpty ? nil : trimmed
        guard newNickname != currentReference.nickname else { return }

        if let sessionViewModel {
            sessionViewModel.setNickname(newNickname)
            listViewModel.reload()
        } else {
            listViewModel.setNickname(newNickname, for: reference)
        }
    }

    private var currentDisplayName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return currentReference.displayName
        }
        return trimmed
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
