import AppKit
import SwiftUI

@MainActor
final class MacDatabaseSettingsSheet {
    let model: MacDatabaseSettingsModel
    let shell: MacFormSheetController
    let tabs: MacSheetTabBar
    private(set) var masterKeySheet: MacMasterKeySheet?
    private(set) var encryptionSheet: MacEncryptionSettingsSheet?
    var presentChild: @MainActor (MacFormSheetController, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void = {
        $0.begin(on: $1, completion: $2)
    }

    init(model: MacDatabaseSettingsModel) {
        self.model = model
        tabs = MacSheetTabBar(tabs: model.tabs.map { ($0.title, $0.symbol) }, identifier: "database-settings.tabs")
        let scope = MacSheetCancellationScope()
        let owner = MacDatabaseSettingsWindow()
        let host = NSHostingController(rootView: MacDatabaseSettingsContent(model: model, window: { owner.window },
            changeMasterKey: { owner.sheet?.showMasterKey() }, changeEncryption: { owner.sheet?.showEncryptionSettings() })
            .environment(\.macSheetCancellationScope, scope).modifier(MacHostingAppearance()))
        host.sizingOptions = []
        shell = MacFormSheetController(title: String(localized: "\(model.current.displayName) — Database Settings"),
            content: host, size: NSSize(width: 720, height: 540), defaultTitle: String(localized: "Done"),
            tabs: tabs, cancellationScope: scope)
        owner.window = shell.window
        shell.cancelButton.isHidden = true
        shell.window?.setAccessibilityIdentifier("database-settings.sheet")
        shell.defaultButton.setAccessibilityIdentifier("database-settings.done")
        tabs.onSelect = { [weak self] index in self?.changeTab(to: index) }
        owner.sheet = self
        scope.register { [weak self] in
            self?.masterKeySheet?.shell.end()
            self?.encryptionSheet?.shell.end()
        }
    }

    private func changeTab(to index: Int) {
        model.commitNickname()
        guard model.tabs.indices.contains(index) else { return }
        model.selection = model.tabs[index]
    }

    /// Database ▸ Change Master Key… opens it without waiting for the file facts the Security tab shows.
    func showMasterKey(selectingSecurityTab: Bool = false) {
        guard let session = model.session, session.state == .unlocked, !model.isReadOnly, !session.isSaving,
              let parent = childParent() else { return }
        if selectingSecurityTab, let index = model.tabs.firstIndex(of: .security) {
            model.commitNickname()
            tabs.selectedIndex = index
            model.selection = .security
        }
        let child = MacMasterKeySheet(session: session)
        masterKeySheet = child
        presentChild(child.shell, parent) { [weak self, weak child] _ in
            if let self, self.masterKeySheet === child { self.masterKeySheet = nil }
        }
    }

    func showEncryptionSettings() {
        guard model.canChangeSecurity, let session = model.session, let summary = model.fileInfo?.summary,
              let parent = childParent() else { return }
        let child = MacEncryptionSettingsSheet(session: session, current: summary)
        encryptionSheet = child
        presentChild(child.shell, parent) { [weak self, weak child] _ in
            if let self, self.encryptionSheet === child { self.encryptionSheet = nil }
        }
    }

    private func childParent() -> NSWindow? {
        guard shell.isPresented, masterKeySheet == nil, encryptionSheet == nil,
              let window = shell.window, window.attachedSheet == nil else { return nil }
        return window
    }
}

@MainActor
private final class MacDatabaseSettingsWindow {
    weak var window: NSWindow?
    weak var sheet: MacDatabaseSettingsSheet?
}

private struct MacDatabaseSettingsContent: View {
    @Bindable var model: MacDatabaseSettingsModel
    let window: @MainActor () -> NSWindow?
    let changeMasterKey: @MainActor () -> Void
    let changeEncryption: @MainActor () -> Void
    @State private var icons = false
    @State private var exportRequest: DatabaseExportRequest?

    var body: some View {
        ScrollView {
            Form {
                switch model.selection {
                case .general: MacDatabaseGeneralTab(model: model, showIcons: { icons = true })
                case .security: MacDatabaseSecurityTab(model: model, changeMasterKey: changeMasterKey, changeEncryption: changeEncryption)
                case .sync: MacDatabaseSyncTab(model: model)
                case .autoFill: MacDatabaseAutoFillTab(model: model, window: window)
                case .backups: MacDatabaseBackupsTab(model: model, export: exportDatabaseCopy)
                }
            }
            .formStyle(.columns)
            .padding(20)
        }
        .task(id: model.session?.openTimeSHA512) { await model.refreshFactsIfNeeded() }
        .onDisappear { model.commitNickname() }
        .sheet(isPresented: $icons) {
            if let session = model.session {
                NavigationStack { CustomIconsView(viewModel: session) }.macSheetFrame()
            }
        }
        .databaseExporter(request: $exportRequest)
    }

    private func exportDatabaseCopy(_ request: DatabaseExportRequest) { exportRequest = request }
}

private struct MacDatabaseGeneralTab: View {
    @Bindable var model: MacDatabaseSettingsModel
    let showIcons: () -> Void
    @FocusState private var editingName: Bool
    var body: some View {
        LabeledContent("Custom name:") {
            VStack(alignment: .leading) {
                TextField("Custom Name", text: $model.nickname, prompt: Text("Use filename")).labelsHidden().frame(maxWidth: 280)
                    .focused($editingName)
                    .onSubmit { model.commitNickname() }
                    .accessibilityIdentifier("database-details.nickname-field")
                Text("Filename: \(model.current.filename)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: editingName) { _, focused in if !focused { model.commitNickname() } }
        LabeledContent("Opening:") {
            VStack(alignment: .leading) {
                Toggle("Quick Launch", isOn: Binding(get: { model.current.isQuickLaunch }, set: { value in
                    if value != model.current.isQuickLaunch { model.list.toggleQuickLaunch(for: model.current) }
                })).accessibilityIdentifier("database-details.quick-launch-toggle")
                caption("Quick Launch opens this database automatically on app launch.")
            }
        }
        Divider()
        LabeledContent("Editing:") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Read-Only", isOn: Binding(get: { model.isReadOnly }, set: model.setReadOnly))
                    .disabled(model.fixedReadOnly || model.isLoading)
                    .accessibilityIdentifier("database-row.read-only-toggle")
                Text(model.readOnlyCaption).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("database-details.read-only-footer")
                if model.session != nil {
                    Button("Manage Custom Icons…", action: showIcons)
                        .disabled(model.session?.state != .unlocked || model.session?.isSaving == true)
                        .accessibilityIdentifier("database-details.custom-icons")
                }
            }
        }
        Divider()
        LabeledContent("Database file:") {
            VStack(alignment: .leading, spacing: 6) {
                if model.isLoading { ProgressView("Reading database file…") }
                else if model.facts.isEmpty { Text("File details are unavailable.") }
                else { Text(model.facts).accessibilityIdentifier("database-details.file-format") }
                Text(model.cachedCopyCaption).font(.caption).foregroundStyle(.secondary)
                Text(model.history).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MacDatabaseSecurityTab: View {
    let model: MacDatabaseSettingsModel
    let changeMasterKey: @MainActor () -> Void
    let changeEncryption: @MainActor () -> Void
    var body: some View {
        LabeledContent("Master key:") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.masterKeySummary)
                if let changed = model.masterKeyChangedText { Text(changed).font(.caption).foregroundStyle(.secondary) }
                Button("Change Master Key…", action: changeMasterKey).disabled(!model.canChangeSecurity)
                    .accessibilityIdentifier("database-details.change-master-key")
            }
        }
        Divider()
        LabeledContent("Encryption:") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = model.fileInfo?.summary {
                    Text(DatabaseSettingsSummary.encryption(summary) ?? "")
                    Text(SettingsSummaryText.joined([summary.keyDerivationDetailText, summary.compressionDisplayName])).font(.caption).foregroundStyle(.secondary)
                } else { Text("File details are unavailable.") }
                Button("Change Encryption Settings…", action: changeEncryption)
                    .disabled(!model.canChangeSecurity || model.fileInfo?.summary == nil)
                    .accessibilityIdentifier("database-details.change-encryption-settings")
                caption("Most databases never need this. The wrong values can make a database slow to open on your other devices.")
            }
        }
    }
}

private struct MacDatabaseSyncTab: View {
    let model: MacDatabaseSettingsModel
    var body: some View {
        if let metadata = model.current.cloudSyncMetadata, let state = model.list.cloudState(for: model.current) {
            LabeledContent("Provider:", value: state.providerName)
            LabeledContent("Account:", value: state.accountLabel)
            LabeledContent("Path:", value: metadata.displayPath)
            if let date = metadata.remoteModifiedAt { LabeledContent("Remote modified:", value: date.formatted(date: .abbreviated, time: .shortened)) }
            if let date = metadata.lastSyncedAt { LabeledContent("Last sync:", value: date.formatted(date: .abbreviated, time: .shortened)) }
            LabeledContent("Status:") {
                HStack {
                    Circle().fill(state.warningText == nil ? Color.green : .orange).frame(width: 7, height: 7)
                    Text(state.warningText ?? String(localized: "Healthy"))
                }
            }
            Divider()
            LabeledContent("When opening:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Sync When Opening", isOn: Binding(get: { model.current.cloudSyncPolicy == .onOpen }, set: model.setSyncOnOpen))
                        .accessibilityIdentifier("database-details.sync-on-open-toggle")
                    if !state.isConnected {
                        caption("This account is disconnected. KeeForge keeps the cached copy until you remove the database.")
                    } else if model.current.cloudSyncPolicy == .manual {
                        caption("KeeForge opens the copy saved on this device without checking the cloud. Use Sync Now in the unlocked database to get newer changes. Saving still checks the cloud copy first and stops if it changed. AutoFill uses the cached copy only.")
                    } else {
                        caption("Cloud databases are cached locally and refreshed whenever you open them in the main app. AutoFill uses the cached copy only.")
                    }
                    Button("Sync Now") { Task { await model.syncNow() } }
                        .disabled(model.session?.canSyncCloudNow != true)
                        .accessibilityIdentifier("database-details.sync-now")
                    if let outcome = model.session?.cloudSyncOutcome { Text(outcome.message).font(.caption).foregroundStyle(.secondary) }
                    else if model.session?.isDirty == true || model.session?.hasUnsavedEditor == true { caption("Save your changes before syncing.") }
                }
            }
        }
    }
}

private struct MacDatabaseAutoFillTab: View {
    let model: MacDatabaseSettingsModel
    let window: @MainActor () -> NSWindow?
    @State private var picker: MacFormSheetController?
    @Environment(\.macSheetCancellationScope) private var cancellationScope
    var body: some View {
        LabeledContent("AutoFill:") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Include in AutoFill", isOn: Binding(get: { model.current.autoFillEnabled }, set: model.setAutoFillEnabled))
                    .accessibilityIdentifier("database-details.autofill-toggle")
                caption("When off, passwords, passkeys, and verification codes from this database are neither suggested nor available in AutoFill. After you turn it back on, suggestions return the next time you unlock this database.")
            }
        }
        if model.hasDestination, let session = model.session, let group = session.autoFillDestinationGroup {
            Divider()
            LabeledContent("Save new entries to:") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(group.name, systemImage: "folder")
                        Button("Select Group…") { selectGroup(session) }
                            .disabled(model.isReadOnly || session.isSaving)
                            .accessibilityIdentifier("database-details.autofill-destination")
                            .onDisappear { picker?.end(); picker = nil }
                    }
                    caption("Passwords and passkeys saved from AutoFill go into this group.")
                }
            }
        }
    }
    private func selectGroup(_ session: DatabaseViewModel) {
        guard let parent = window(), parent.attachedSheet == nil, picker == nil else { return }
        let cycle = session.lockCycleID
        let selection = MacGroupPickerModel(purpose: .autoFillDestination, database: session, current: session.autoFillDestinationGroup?.id)
        let outline = MacGroupPickerSheet(model: selection)
        let shell = MacFormSheetController(title: selection.title, content: outline, size: NSSize(width: 500, height: 460), defaultTitle: selection.confirmTitle)
        shell.canConfirm = false
        outline.onSelectionChange = { [weak shell] in shell?.canConfirm = selection.canConfirm }
        outline.onDoubleClick = { [weak shell] in shell?.performDefault() }
        picker = shell
        cancellationScope?.register { [weak shell] in shell?.end() }
        shell.begin(on: parent) { confirmed in
            picker = nil
            guard confirmed, session.state == .unlocked, session.lockCycleID == cycle, !session.isReadOnly,
                  !session.isSaving, selection.canConfirm, let id = selection.selection else { return }
            session.setAutoFillDestinationGroupID(id)
        }
    }
}

private struct MacDatabaseBackupsTab: View {
    let model: MacDatabaseSettingsModel
    let export: (DatabaseExportRequest) -> Void
    var body: some View {
        LabeledContent("Export:") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Export Copy…") { export(.currentCopy(model.current)) }
                    .accessibilityIdentifier("database-details.export-copy")
                caption("Saves the locally cached copy of the database as KeeForge currently has it. Use it to merge changes into your main file with another KeePass app when a cloud upload is stuck.")
            }
        }
        Divider()
        LabeledContent("Backups:") {
            VStack(alignment: .leading, spacing: 8) {
                if model.backups.isEmpty { Text("No backups on this device.").foregroundStyle(.secondary).accessibilityIdentifier("database-details.backups-empty") }
                else {
                    GroupBox {
                        ForEach(model.backups) { backup in
                            HStack {
                                Text(backup.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? backup.url.lastPathComponent)
                                Spacer()
                                Button("Export Copy…") { export(.backup(backup, model.current)) }
                            }.accessibilityIdentifier("database-details.backup-row")
                        }
                    }
                }
                caption("KeeForge keeps the last five backups it made before saving or replacing this database on this device.")
            }
        }
    }
}

private func caption(_ key: LocalizedStringKey) -> some View { Text(key).font(.caption).foregroundStyle(.secondary) }
