import SwiftUI

/// Per-database settings and file facts, shared by the two places that show
/// them: the database list (long-press → Database Details) and the unlocked
/// database's toolbar gear button.
///
/// The root is a hub: a header with the file facts, then one row per area
/// that says what is currently set and pushes that area's page.
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
    /// own copy of the reference, and its presence adds the App Settings link
    /// and the AutoFill save-group row.
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
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var showAppSettings = false
    @State private var showAutoFillDestinationPicker = false
    @State private var backups: [DatabaseExportService.Backup] = []
    @State private var exportRequest: DatabaseExportRequest?

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
                headerSection
                areasSection
                importSection
                appSettingsSection
            }
            .macGroupedForm()
            .navigationTitle("Database Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        saveNickname()
                        dismiss()
                    }
                    .accessibilityIdentifier("database-details.close")
                }
            }
        }
        // Everything below sits on the stack, not the hub. The hub leaves the
        // screen while a page is pushed over it, which would cancel its tasks
        // and leave it unable to present.
        // Every write through the open session replaces its open-time hash,
        // and each one changes the file and its backups.
        .task(id: sessionViewModel?.openTimeSHA512) {
            backups = DatabaseExportService.backups(for: currentReference)
            let loadedFileInfo = await DatabaseFileInfoLoader.load(for: currentReference)
            guard Task.isCancelled == false else { return }
            fileInfo = loadedFileInfo
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
        .fileImporter(
            isPresented: $showKeyFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try listViewModel.setKeyFile(url: url, for: reference)
                } catch {
                    selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
                }
            case .failure(let error):
                selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
            }
        }
        .alert(item: $selectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showAppSettings) {
            SettingsView(viewModel: sessionViewModel, listViewModel: listViewModel)
        }
        .sheet(isPresented: $showAutoFillDestinationPicker) {
            if let sessionViewModel {
                MoveToGroupPickerView(
                    options: sessionViewModel.groupDestinationOptions(
                        currentGroupID: sessionViewModel.databaseReference.autoFillDestinationGroupID
                    ),
                    navigationTitle: "Select Group"
                ) { groupID in
                    sessionViewModel.setAutoFillDestinationGroupID(groupID)
                    listViewModel.reload()
                }
            }
        }
        .databaseExporter(request: $exportRequest)
    }

    // MARK: - Hub

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentDisplayName)
                        .font(.title3.weight(.semibold))

                    Text(DatabaseSettingsSummary.header(filename: currentReference.filename, fileInfo: fileInfo))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("database-details.header")
        }
    }

    private var areasSection: some View {
        Section {
            NavigationLink {
                page("General") {
                    identitySection
                    editingSection
                    databaseFileSection
                    metadataSection
                }
            } label: {
                SettingsSummaryRow(
                    title: "General",
                    systemImage: "slider.horizontal.3",
                    summary: DatabaseSettingsSummary.general(
                        isQuickLaunch: currentReference.isQuickLaunch,
                        isReadOnly: isReadOnly
                    )
                )
            }
            .accessibilityIdentifier("database-details.general.link")

            NavigationLink {
                page("AutoFill") {
                    autoFillSection
                }
            } label: {
                SettingsSummaryRow(
                    title: "AutoFill",
                    systemImage: "text.cursor",
                    summary: DatabaseSettingsSummary.autoFill(
                        isEnabled: currentReference.autoFillEnabled,
                        destinationGroupName: sessionViewModel?.autoFillDestinationGroup?.name
                    )
                )
            }
            .accessibilityIdentifier("database-details.autofill.link")

            NavigationLink {
                page("Master Key") {
                    keyFileSection
                    masterKeySection
                }
            } label: {
                SettingsSummaryRow(
                    title: "Master Key",
                    systemImage: "key",
                    summary: DatabaseSettingsSummary.masterKey(
                        keyFileFilename: currentReference.keyFileFilename,
                        usesHardwareKey: isHardwareKeyReadOnly
                    )
                )
            }
            .accessibilityIdentifier("database-details.master-key.link")

            NavigationLink {
                page("Encryption") {
                    encryptionFactsSection
                    encryptionSection
                }
            } label: {
                SettingsSummaryRow(
                    title: "Encryption",
                    systemImage: "lock",
                    summary: DatabaseSettingsSummary.encryption(fileInfo?.summary)
                )
            }
            .accessibilityIdentifier("database-details.encryption.link")

            if let cloudState = listViewModel.cloudState(for: reference),
               let metadata = currentReference.cloudSyncMetadata {
                NavigationLink {
                    page("Cloud Sync") {
                        cloudSyncSection(cloudState, metadata: metadata)
                    }
                } label: {
                    HStack {
                        SettingsSummaryRow(
                            title: "Cloud Sync",
                            systemImage: "arrow.triangle.2.circlepath",
                            summary: DatabaseSettingsSummary.cloudSync(cloudState, lastSyncedAt: metadata.lastSyncedAt)
                        )

                        Spacer()

                        // The summary already says it in words.
                        Circle()
                            .fill(cloudState.warningText == nil ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("database-details.cloud-sync.link")
            }

            NavigationLink {
                page("Backups & Export") {
                    exportSection
                    backupsSection
                }
            } label: {
                SettingsSummaryRow(
                    title: "Backups & Export",
                    systemImage: "clock.arrow.circlepath",
                    summary: DatabaseSettingsSummary.backups(backups)
                )
            }
            .accessibilityIdentifier("database-details.backups.link")
        }
    }

    private func page(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        Form {
            content()
        }
        .macGroupedForm()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
                    .macLabelsHidden()
                    .macFormFieldStyle()
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
            .disabled(isFormatReadOnly || isHardwareKeyReadOnly)
            .accessibilityIdentifier("database-row.read-only-toggle")
        } header: {
            Text("Editing")
        } footer: {
            Text(readOnlyFooter)
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

            // Groups live inside the encrypted file, so this needs the unlocked session.
            if let destinationGroup = sessionViewModel?.autoFillDestinationGroup {
                autoFillDestinationRow(destinationGroup)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("When off, passwords, passkeys, and verification codes from this database are neither suggested nor available in AutoFill. After you turn it back on, suggestions return the next time you unlock this database.")
                if sessionViewModel?.autoFillDestinationGroup != nil {
                    Text("Passwords and passkeys saved from AutoFill go into this group.")
                }
            }
        }
    }

    private func autoFillDestinationRow(_ destinationGroup: KPGroup) -> some View {
        Button {
            showAutoFillDestinationPicker = true
        } label: {
            HStack {
                Text("Save New Entries To")

                Spacer()

                Label(destinationGroup.name, systemImage: "folder")
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("database-details.autofill-destination")
        .macHoverHighlight()
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
                        // A rekey updates the stored reference; re-read it so
                        // the Associated File row is fresh when this pops.
                        .onDisappear { listViewModel.reload() }
                } label: {
                    Text("Change Master Key…")
                }
                .disabled(isReadOnly)
                .accessibilityIdentifier("database-details.change-master-key")
            } footer: {
                Text("Changing the master key re-encrypts this database file with a new master password and/or key file.")
            }
        }
    }

    @ViewBuilder
    private var encryptionSection: some View {
        if let sessionViewModel {
            Section {
                NavigationLink {
                    if let summary = fileInfo?.summary {
                        EncryptionSettingsView(sessionViewModel: sessionViewModel, current: summary)
                    }
                } label: {
                    Text("Change Encryption Settings…")
                }
                .disabled(isReadOnly || fileInfo?.summary == nil)
                .accessibilityIdentifier("database-details.change-encryption-settings")
            } footer: {
                Text("Choose the cipher, key derivation, and compression this database file is saved with.")
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
            fileFactRows { fileInfo in
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
            }
        } header: {
            Text("Database File")
        } footer: {
            cachedCopyFooter
        }
    }

    private var encryptionFactsSection: some View {
        Section {
            fileFactRows { fileInfo in
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
                } else {
                    fileDetailsUnavailableRow
                }
            }
        } footer: {
            cachedCopyFooter
        }
    }

    @ViewBuilder
    private var cachedCopyFooter: some View {
        if currentReference.isCloudBacked {
            Text("Values reflect the locally cached copy of this database.")
        }
    }

    @ViewBuilder
    private var importSection: some View {
        if let sessionViewModel {
            Section {
                NavigationLink {
                    PasswordImportView(sessionViewModel: sessionViewModel)
                } label: {
                    Label("Import Passwords…", systemImage: "square.and.arrow.down")
                }
                .disabled(isReadOnly)
                .accessibilityIdentifier("database-details.import-passwords")
            } footer: {
                Text("Add logins from a password export file, such as the one the Passwords app creates.")
            }
        }
    }

    private var exportSection: some View {
        Section {
            Button("Export Copy…") {
                exportRequest = .currentCopy(currentReference)
            }
            .accessibilityIdentifier("database-details.export-copy")
        } header: {
            Text("Export")
        } footer: {
            if currentReference.isCloudBacked {
                Text("Saves the locally cached copy of the database as KeeForge currently has it. Use it to merge changes into your main file with another KeePass app when a cloud upload is stuck.")
            } else {
                Text("Saves a copy of the database as KeeForge currently has it. Use it to merge changes into your main file with another KeePass app when a cloud upload is stuck.")
            }
        }
    }

    private var backupsSection: some View {
        Section {
            if backups.isEmpty {
                Text("No backups on this device.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("database-details.backups-empty")
            } else {
                ForEach(backups) { backup in
                    Button {
                        exportRequest = .backup(backup, currentReference)
                    } label: {
                        if let createdAt = backup.createdAt {
                            Text(createdAt, format: .dateTime)
                        } else {
                            Text(backup.url.lastPathComponent)
                        }
                    }
                    .accessibilityIdentifier("database-details.backup-row")
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            Text("KeeForge keeps the last five backups it made before saving or replacing this database on this device.")
        }
    }

    private func cloudSyncSection(_ cloudState: CloudRowState, metadata: CloudSyncMetadata) -> some View {
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

            LabeledContent("Status", value: cloudState.warningText ?? String(localized: "Healthy"))

            Toggle(
                "Sync When Opening",
                isOn: Binding(
                    get: { currentReference.cloudSyncPolicy == .onOpen },
                    set: { setCloudSyncPolicy($0 ? .onOpen : .manual) }
                )
            )
            .accessibilityIdentifier("database-details.sync-on-open-toggle")

            // Replacing the open database needs the unlocked session.
            if let sessionViewModel {
                syncNowRow(sessionViewModel)
            }
        } footer: {
            if cloudState.isConnected == false {
                Text("This account is disconnected. KeeForge keeps the cached copy until you remove the database.")
            } else if currentReference.cloudSyncPolicy == .manual {
                Text("KeeForge opens the copy saved on this device without checking the cloud. Use Sync Now in the unlocked database to get newer changes. Saving still checks the cloud copy first and stops if it changed. AutoFill uses the cached copy only.")
            } else {
                Text("Cloud databases are cached locally and refreshed whenever you open them in the main app. AutoFill uses the cached copy only.")
            }
        }
    }

    private func syncNowRow(_ sessionViewModel: DatabaseViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Sync Now") {
                    Task {
                        await sessionViewModel.syncCloudNow()
                        // Last Sync and Status read the stored reference.
                        listViewModel.reload()
                    }
                }
                .disabled(sessionViewModel.canSyncCloudNow == false)
                .accessibilityIdentifier("database-details.sync-now")

                if sessionViewModel.isSyncingCloud {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let outcome = sessionViewModel.cloudSyncOutcome {
                Text(outcome.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("database-details.sync-outcome")
            } else if sessionViewModel.isDirty || sessionViewModel.hasUnsavedEditor {
                Text("Save your changes before syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setCloudSyncPolicy(_ policy: CloudSyncPolicy) {
        if let sessionViewModel {
            sessionViewModel.setCloudSyncPolicy(policy)
            listViewModel.reload()
        } else {
            listViewModel.setCloudSyncPolicy(policy, for: reference)
        }
    }

    /// Only the unlocked database needs this: the database list reaches App
    /// Settings from its own toolbar.
    @ViewBuilder
    private var appSettingsSection: some View {
        if sessionViewModel != nil {
            Section {
                Group {
                    #if os(macOS)
                    SettingsLink {
                        Label("App Settings", systemImage: "gearshape")
                    }
                    #else
                    Button {
                        showAppSettings = true
                    } label: {
                        Label("App Settings", systemImage: "gearshape")
                    }
                    #endif
                }
                .accessibilityIdentifier("database-details.app-settings")
            }
        }
    }

    /// The rows that depend on reading the file, or what stands in for them
    /// while it loads and when it cannot be read.
    @ViewBuilder
    private func fileFactRows(@ViewBuilder rows: (DatabaseFileInfo) -> some View) -> some View {
        if let fileInfo {
            rows(fileInfo)
        } else if isLoadingFileInfo {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading database file…")
                    .foregroundStyle(.secondary)
            }
        } else {
            fileDetailsUnavailableRow
        }
    }

    private var fileDetailsUnavailableRow: some View {
        Text("File details are unavailable.")
            .foregroundStyle(.secondary)
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

    /// Saving a YubiKey-protected database is not supported yet, so it is
    /// read-only while the hardware key is configured, like KDBX 3.1.
    private var isHardwareKeyReadOnly: Bool {
        sessionViewModel?.sessionUsesHardwareKey == true || currentReference.hardwareKey != nil
    }

    private var isReadOnly: Bool {
        currentReference.isReadOnly || isFormatReadOnly || isHardwareKeyReadOnly
    }

    private var readOnlyFooter: String {
        if isFormatReadOnly {
            return String(localized: "Legacy KDBX 3.1 databases can be opened, but KeeForge intentionally keeps them read-only.")
        }
        if isHardwareKeyReadOnly {
            return String(localized: "Databases unlocked with a YubiKey open read-only for now. Saving them is not supported yet.")
        }
        return String(localized: "You can still open this database, but create, edit, and delete actions stay blocked until you turn editing back on.")
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
