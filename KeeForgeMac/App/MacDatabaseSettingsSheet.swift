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
            Group {
                switch model.selection {
                case .general: MacDatabaseGeneralTab(model: model, showIcons: { icons = true })
                case .security: MacDatabaseSecurityTab(model: model, changeMasterKey: changeMasterKey, changeEncryption: changeEncryption)
                case .sync: MacDatabaseSyncTab(model: model)
                case .autoFill: MacDatabaseAutoFillTab(model: model, window: window)
                case .backups: MacDatabaseBackupsTab(model: model, export: exportDatabaseCopy)
                }
            }
            // With the shell's 20 pt margin this matches the Settings window's insets.
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
        MacSettingsForm {
            MacSettingsRow("Custom name:") {
                TextField("Custom Name", text: $model.nickname, prompt: Text("Use filename")).labelsHidden().frame(maxWidth: 280)
                    .focused($editingName)
                    .onSubmit { model.commitNickname() }
                    .onChange(of: editingName) { _, focused in if !focused { model.commitNickname() } }
                    .accessibilityIdentifier("database-details.nickname-field")
                settingsCaption("Filename: \(model.current.filename)")
            }
            MacSettingsRow("Opening:") {
                Toggle("Quick Launch", isOn: Binding(get: { model.current.isQuickLaunch }, set: { value in
                    if value != model.current.isQuickLaunch { model.list.toggleQuickLaunch(for: model.current) }
                })).accessibilityIdentifier("database-details.quick-launch-toggle")
                settingsCaption("Quick Launch opens this database automatically on app launch.", indented: true)
            }
            MacSettingsSeparator()
            MacSettingsRow("Editing:") {
                Toggle("Read-Only", isOn: Binding(get: { model.isReadOnly }, set: model.setReadOnly))
                    .disabled(model.fixedReadOnly || model.isLoading)
                    .accessibilityIdentifier("database-row.read-only-toggle")
                noteCaption(model.readOnlyCaption, indented: true)
                    .accessibilityIdentifier("database-details.read-only-footer")
                if model.session != nil {
                    Button("Manage Custom Icons…", action: showIcons)
                        .disabled(model.session?.state != .unlocked || model.session?.isSaving == true)
                        .accessibilityIdentifier("database-details.custom-icons")
                        .padding(.top, 4)
                }
            }
            MacSettingsSeparator()
            MacSettingsRow("Database file:") {
                if model.isLoading { ProgressView("Reading database file…").controlSize(.small) }
                else if model.facts.isEmpty { Text("File details are unavailable.") }
                else { Text(model.facts).textSelection(.enabled).accessibilityIdentifier("database-details.file-format") }
                noteCaption(model.cachedCopyCaption)
                noteCaption(model.history)
            }
        }
    }
}

private struct MacDatabaseSecurityTab: View {
    let model: MacDatabaseSettingsModel
    let changeMasterKey: @MainActor () -> Void
    let changeEncryption: @MainActor () -> Void
    var body: some View {
        MacSettingsForm {
            MacSettingsRow("Master key:") {
                Text(model.masterKeySummary)
                if let changed = model.masterKeyChangedText { noteCaption(changed) }
                Button("Change Master Key…", action: changeMasterKey).disabled(!model.canChangeSecurity)
                    .accessibilityIdentifier("database-details.change-master-key")
                    .padding(.top, 4)
            }
            MacSettingsSeparator()
            MacSettingsRow("Encryption:") {
                if let summary = model.fileInfo?.summary {
                    Text(DatabaseSettingsSummary.encryption(summary) ?? "")
                    noteCaption(SettingsSummaryText.joined([summary.keyDerivationDetailText, summary.compressionDisplayName]))
                } else { Text("File details are unavailable.") }
                Button("Change Encryption Settings…", action: changeEncryption)
                    .disabled(!model.canChangeSecurity || model.fileInfo?.summary == nil)
                    .accessibilityIdentifier("database-details.change-encryption-settings")
                    .padding(.top, 4)
                settingsCaption("Most databases never need this; the wrong values can make a database slow to open on your other devices.")
            }
        }
    }
}

private struct MacDatabaseSyncTab: View {
    let model: MacDatabaseSettingsModel
    var body: some View {
        if let metadata = model.current.cloudSyncMetadata, let state = model.list.cloudState(for: model.current) {
            let status = model.syncStatus
            MacSettingsForm {
                MacSettingsRow("Provider:") { Text(state.providerName) }
                MacSettingsRow("Account:") { Text(state.accountLabel).textSelection(.enabled) }
                MacSettingsRow("Path:") {
                    // Wraps rather than truncates, so the whole path stays readable and selectable.
                    Text(metadata.displayPath)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(metadata.displayPath)
                        .accessibilityIdentifier("database-details.sync-path")
                }
                MacSettingsSeparator()
                MacSettingsRow("Status:") {
                    HStack(spacing: 6) {
                        Circle().fill(status.tone.color).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(status.text).accessibilityIdentifier("database-details.sync-status")
                    }
                    if let action = status.action {
                        Button(action.title) { model.performStatusAction?(action) }
                            .disabled(!status.isActionEnabled)
                            .accessibilityIdentifier("database-details.sync-status-action")
                    }
                }
                if let date = metadata.lastSyncedAt {
                    MacSettingsRow("Last sync:") { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
                if let date = metadata.remoteModifiedAt {
                    MacSettingsRow("Remote modified:") { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
                MacSettingsSeparator()
                MacSettingsRow("When opening:") {
                    MacSettingsHelpRow(help: MacSettingsHelpButton(label: "Sync When Opening Help",
                        text: "Saving still checks the server's copy first and stops if it changed. AutoFill uses the cached copy only.",
                        identifier: "database-details.sync-policy.help")) {
                        Toggle("Sync When Opening", isOn: Binding(get: { model.current.cloudSyncPolicy == .onOpen }, set: { model.setSyncOnOpen($0) }))
                            .accessibilityIdentifier("database-details.sync-on-open-toggle")
                    }
                    if !state.isConnected {
                        settingsCaption("This account is disconnected, so KeeForge keeps the cached copy until you remove the database.", indented: true)
                    } else if model.current.cloudSyncPolicy == .manual {
                        settingsCaption("KeeForge opens the copy on this Mac without checking the server; use Sync Now to get newer changes.", indented: true)
                    } else {
                        settingsCaption("KeeForge refreshes the cached copy whenever you open the database; AutoFill uses the cached copy only.", indented: true)
                    }
                }
                MacSettingsRow {
                    HStack(spacing: 8) {
                        Button("Sync Now") { Task { await model.syncNow() } }
                            .disabled(!model.canSyncNow)
                            .accessibilityIdentifier("database-details.sync-now")
                        if model.isSyncing {
                            ProgressView().controlSize(.small)
                            Text("Syncing…").foregroundStyle(.secondary)
                        }
                    }
                    if let note = model.syncNowNote { noteCaption(note) }
                }
            }
        }
    }
}

private extension MacDatabaseSettingsModel.SyncStatus.Tone {
    var color: Color {
        switch self {
        case .healthy: .green
        case .neutral: .secondary
        case .warning: .orange
        }
    }
}

private struct MacDatabaseAutoFillTab: View {
    let model: MacDatabaseSettingsModel
    let window: @MainActor () -> NSWindow?
    @State private var picker: MacFormSheetController?
    @Environment(\.macSheetCancellationScope) private var cancellationScope
    var body: some View {
        MacSettingsForm {
            MacSettingsRow("AutoFill:") {
                Toggle("Include in AutoFill", isOn: Binding(get: { model.current.autoFillEnabled }, set: model.setAutoFillEnabled))
                    .accessibilityIdentifier("database-details.autofill-toggle")
                settingsCaption("When off, AutoFill offers nothing from this database; turned back on, it suggests again after the next unlock.", indented: true)
            }
            if model.hasDestination, let session = model.session, let group = session.autoFillDestinationGroup {
                MacSettingsSeparator()
                MacSettingsRow("Save new entries to:") {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(group.name, systemImage: "folder")
                        Button("Select Group…") { selectGroup(session) }
                            .disabled(model.isReadOnly || session.isSaving)
                            .accessibilityIdentifier("database-details.autofill-destination")
                            .onDisappear { picker?.end(); picker = nil }
                    }
                    settingsCaption("Passwords and passkeys saved from AutoFill go into this group.")
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
        MacSettingsForm {
            MacSettingsRow("Export:") {
                Button("Export Copy…") { export(.currentCopy(model.current)) }
                    .accessibilityIdentifier("database-details.export-copy")
                settingsCaption("Saves KeeForge's cached copy, for example to merge a stuck upload in another KeePass app.")
            }
            MacSettingsSeparator()
            MacSettingsRow("Backups:") {
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
                settingsCaption("KeeForge keeps the last five backups it made before saving or replacing this database on this device.")
            }
        }
    }
}

@MainActor
private func noteCaption(_ text: String, indented: Bool = false) -> some View {
    settingsCaption(verbatim: text, indented: indented)
}
