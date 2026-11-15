import AppKit
import SwiftUI

/// One database's window. It owns that session for its whole life and never
/// looks another one up: content, title, toolbar, commands and close all act on
/// `session`.
@MainActor
final class DatabaseWindowController: NSWindowController, NSMenuItemValidation {
    let session: DatabaseViewModel
    let workspacePresentation = MacWorkspacePresentation()
    let splitAutosaveName: NSSplitView.AutosaveName?
    private let initialContentSize: NSSize
    private(set) lazy var attachmentPreview = MacAttachmentPreviewController(
        database: session,
        previews: AttachmentPreviewSession(currentSession: { [weak self] in self?.currentSession() }),
        panel: previewPanel
    )
    private let previewPanel: any MacPreviewPanelPresenting
    let largeType: MacLargeTypePanelController
    private lazy var workspace = MacWindowWorkspace(
        presentation: workspacePresentation,
        attachmentPreview: attachmentPreview,
        largeType: largeType,
        splitAutosaveName: splitAutosaveName,
        currentSession: { [weak self] in self?.currentSession() }
    )
    private(set) lazy var workspaceSheets = MacWorkspaceSheets(session: session, presentation: workspacePresentation) { [weak self] in self?.window }
    private(set) lazy var workspaceAlerts = MacWorkspaceAlerts(session: session, presentation: workspacePresentation) { [weak self] in self?.window }
    private lazy var reconnectSheet = MacServerReconnectSheet(prompt: workspacePresentation.serverCredentialPrompt) { [weak self] in self?.window }
    private let titleObservation = MacObservation()
    private let unlockFormObservation = MacObservation()
    private let lockedPageObservation = MacObservation()
    let filePanels: MacFilePanels
    /// The locked pages' form, kept across the locked, opening and error pages.
    private(set) lazy var unlockForm = MacUnlockFormModel(session: session, filePicker: filePanels)
    private let windowRegistry: MacDatabaseWindowRegistry
    private let enrollment: TOTPEnrollmentCoordinator
    private let passwordCopyAction: EntrySecretAction
    private let requestClose: @MainActor (NSWindow) -> Void
    private var closeObserver: NSObjectProtocol?
    private var databaseExportTask: Task<Void, Never>?

    /// Menu validation and dispatch act only while this is the command target; set by the coordinator.
    var isCommandTarget: @MainActor () -> Bool = { true }
    /// Whether this controller still owns its database's window, rechecked after authentication.
    var isCurrent: @MainActor () -> Bool = { true }
    /// The unlock screen's way back: closes this window and shows the Databases window.
    var onReturnToDatabases: (@MainActor () -> Void)?
    /// A recovery page's Remove from List; the coordinator asks and removes.
    var onRemoveFromList: (@MainActor () -> Void)?
    var onWillClose: (@MainActor (DatabaseWindowController) -> Void)?

    var databaseID: UUID { session.databaseReference.id }
    var workspaceSplitViewController: MacWorkspaceSplitViewController? { workspace.splitViewController }
    var workspaceToolbar: MacWorkspaceToolbar? { workspace.toolbar }

    static func windowIdentifier(for databaseID: UUID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("database.\(databaseID.uuidString)")
    }

    private var commands: DatabaseCommands {
        DatabaseCommands(session: isCommandTarget() ? session : nil, passwordCopyAction: passwordCopyAction,
                         openEditor: workspacePresentation.openEditor(in: session))
    }

    private var workspaceCommands: MacWorkspaceCommands {
        MacWorkspaceCommands(session: isCommandTarget() ? session : nil, presentation: workspacePresentation)
    }

    /// `persistsLayout` off keeps tests from writing split geometry into the host app's defaults.
    /// The window's frame belongs to `MacWindowRestorationStore`, never to AppKit autosave.
    init(
        session: DatabaseViewModel,
        windowRegistry: MacDatabaseWindowRegistry,
        enrollment: TOTPEnrollmentCoordinator,
        persistsLayout: Bool = true,
        initialContentSize: NSSize = DatabaseWindow.defaultContentSize,
        passwordCopyAction: EntrySecretAction = EntrySecretAction(),
        previewPanel: any MacPreviewPanelPresenting = MacSystemPreviewPanel(),
        largeType: MacLargeTypePanelController = .shared,
        filePanels: MacFilePanels = MacFilePanels(),
        requestClose: @escaping @MainActor (NSWindow) -> Void = { $0.performClose(nil) }
    ) {
        self.session = session
        self.filePanels = filePanels
        self.previewPanel = previewPanel
        self.largeType = largeType
        self.windowRegistry = windowRegistry
        self.enrollment = enrollment
        self.passwordCopyAction = passwordCopyAction
        self.requestClose = requestClose
        self.initialContentSize = initialContentSize
        let databaseID = session.databaseReference.id
        splitAutosaveName = persistsLayout ? MacWindowRestorationStore.splitViewAutosaveName(for: databaseID) : nil
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadWindow() {
        guard window == nil else { return }
        let actions = MacLockedWindowActions(
            close: { [weak self] in self?.onReturnToDatabases?() },
            reconnect: { [weak self] in self?.reconnectFromRecoveryPage() },
            removeFromList: { [weak self] in self?.onRemoveFromList?() }
        )
        let content = MacDatabaseRootView(session: session, enrollment: enrollment, unlockForm: unlockForm,
                                          actions: actions)
        let hosting = NSHostingController(rootView: content
            .environment(windowRegistry)
            .environment(workspacePresentation)
            .environment(workspace)
            .modifier(MacHostingAppearance()))
        // AppKit owns the size limits; hosted toolbar safe areas must not raise them.
        hosting.sizingOptions = []
        // The workspace installs its own AppKit toolbar, and a locked window has none.
        hosting.sceneBridgingOptions = []
        let window = DatabaseWindow(contentViewController: hosting)
        window.styleMask = DatabaseWindow.styleMask
        window.title = session.databaseDisplayName
        window.identifier = Self.windowIdentifier(for: databaseID)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.restorationClass = nil
        window.contentMinSize = DatabaseWindow.minimumContentSize
        window.setContentSize(NSSize(width: max(initialContentSize.width, DatabaseWindow.minimumContentSize.width),
            height: max(initialContentSize.height, DatabaseWindow.minimumContentSize.height)))
        window.center()
        self.window = window
        filePanels.window = window
        reconnectSheet.start()
        workspaceSheets.start()
        workspaceAlerts.start()
        attachmentPreview.install(in: window)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.workspaceAlerts.invalidate()
                self.workspaceSheets.invalidate()
                self.databaseExportTask?.cancel()
                self.reconnectSheet.invalidate()
                self.filePanels.cancel()
                self.attachmentPreview.windowClosed()
                self.onWillClose?(self)
            }
        }
        titleObservation.start(reading: { [weak self] () -> (DatabaseViewModel?, String, String) in
            guard let session = self?.session else { return (nil, "", "") }
            let unlocked = session.state == .unlocked ? session : nil
            return (unlocked, session.databaseDisplayName, MacWindowWorkspace.subtitle(for: unlocked))
        }, onChange: { [weak self] unlocked, title, subtitle in
            guard let self else { return }
            if unlocked == nil { self.workspacePresentation.closeEntryEditor() }
            self.workspace.show(unlocked)
            self.installToolbar()
            self.window?.title = title
            self.window?.subtitle = subtitle
        })
        unlockFormObservation.start(reading: { [weak self] () -> (Bool, Int) in
            guard let session = self?.session else { return (false, 0) }
            return (session.state == .unlocked, session.lockCycleID)
        }, onChange: { [weak self] isUnlocked, lockCycleID in
            guard let self else { return }
            guard isUnlocked || lockCycleID != self.clearedFormLockCycle else { return }
            self.clearedFormLockCycle = lockCycleID
            self.filePanels.cancel()
            self.unlockForm.clearSecrets()
            // The page may stay mounted across a lock, so its own load would not run again.
            guard isUnlocked == false else { return }
            self.workspacePresentation.serverCredentialPrompt.finish(connected: false)
            let form = self.unlockForm
            Task { await form.loadAssociatedKeyFileIfNeeded() }
        })
        lockedPageObservation.start(reading: { [weak self] () -> (MacDatabaseOpenPage?, MacKeyFileAssociation?) in
            guard let session = self?.session else { return (nil, nil) }
            return (MacDatabaseOpenPage.make(for: session), session.keyFileAssociation)
        }, onChange: { [weak self] page, _ in
            guard let form = self?.unlockForm else { return }
            form.windowDidShow(page)
            Task { await form.reconcileKeyFileAssociation() }
        })
    }

    private var clearedFormLockCycle = 0

    /// Reconnect on a recovery page: the server's credentials again, then back to the form.
    func reconnectFromRecoveryPage() {
        guard let reconnect = MacServerReconnect(reference: session.databaseReference) else { return }
        let form = unlockForm
        let prompt = workspacePresentation.serverCredentialPrompt
        Task {
            await form.reconnect { try await reconnect.run(present: prompt.present) }
        }
    }

    /// Stops observing once the window has closed for good.
    func invalidate() {
        workspaceAlerts.invalidate()
        workspaceSheets.invalidate()
        databaseExportTask?.cancel()
        reconnectSheet.invalidate()
        filePanels.cancel()
        titleObservation.cancel()
        unlockFormObservation.cancel()
        lockedPageObservation.cancel()
        unlockForm.clearSecrets()
        workspacePresentation.serverCredentialPrompt.finish(connected: false)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        onWillClose = nil
        onReturnToDatabases = nil
        onRemoveFromList = nil
        workspace.show(nil)
    }

    /// Only the unlocked workspace has a toolbar; it hides the title, which its
    /// list header shows instead. A locked window shows just its name.
    private func installToolbar() {
        guard let window else { return }
        if let toolbar = workspace.toolbar?.toolbar {
            guard window.toolbar !== toolbar else { return }
            window.toolbar = toolbar
            window.titleVisibility = .hidden
        } else if window.toolbar != nil {
            window.toolbar = nil
            window.titleVisibility = .visible
        }
    }

    /// Close Window and Close Database both go through the window's guarded close.
    func requestGuardedClose() {
        guard let window else { return }
        requestClose(window)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        guard isCommandTarget() else { return }
        workspace.splitViewController?.toggleSidebar(sender)
    }

    @objc func newEntry(_ sender: Any?) { commands.newEntry() }
    @objc func newGroup(_ sender: Any?) { commands.newGroup() }
    @objc func saveDatabase(_ sender: Any?) { workspaceCommands.save() }
    @objc func closeDatabase(_ sender: Any?) {
        guard commands.canCloseDatabase else { return }
        requestGuardedClose()
    }
    @objc func copyUsername(_ sender: Any?) {
        guard let entryID = commandEntryID else { return }
        commands.copyUsername(entryID: entryID, currentSession: { [weak self] in self?.currentSession() },
                              copy: copyFeedback.recording(.username, for: entryID))
    }
    @objc func copyPassword(_ sender: Any?) {
        guard let entryID = commandEntryID else { return }
        commands.copyPassword(entryID: entryID, currentSession: { [weak self] in self?.currentSession() },
                              copy: copyFeedback.recording(.password, for: entryID))
    }

    /// The menu-bar copies act on `commandEntryID` and leave the tick on its row.
    private var commandEntryID: UUID? {
        commands.commandEntryID
    }
    private var copyFeedback: MacCopyFeedback { workspacePresentation.copyFeedback }

    /// The session a gated copy may still disclose into after authentication.
    private func currentSession() -> DatabaseViewModel? {
        isCurrent() ? session : nil
    }
    @objc func copyURL(_ sender: Any?) {
        guard let entryID = commandEntryID else { return }
        commands.copyURL(entryID: entryID, currentSession: { [weak self] in self?.currentSession() },
                         copy: copyFeedback.recording(.url, for: entryID))
    }
    @objc func copyVerificationCode(_ sender: Any?) {
        guard let entryID = commandEntryID else { return }
        commands.copyVerificationCode(entryID: entryID, copy: copyFeedback.recording(.verificationCode, for: entryID))
    }
    /// The password through the reveal gate and its rechecks, then the app's Large Type panel over this window.
    @objc func showInLargeType(_ sender: Any?) {
        guard let entryID = commandEntryID else { return }
        commands.showPasswordInLargeType(entryID: entryID, currentSession: { [weak self] in self?.currentSession() },
                                         present: { [weak self] password in
            guard let self, let window = self.window else { return }
            self.largeType.showPassword(password, ofEntry: entryID, in: self.session, over: window)
        })
    }
    @objc func editEntry(_ sender: Any?) { commands.editEntry() }
    @objc func deleteSelection(_ sender: Any?) { commands.deleteSelection() }
    @objc func findEntry(_ sender: Any?) {
        guard commands.canFind else { return }
        workspace.toolbar?.focusSearch()
    }
    @objc func lockDatabase(_ sender: Any?) { commands.lock() }
    @objc func duplicateSelectedEntry(_ sender: Any?) { workspaceCommands.duplicate() }
    @objc func moveSelectedEntries(_ sender: Any?) { workspaceCommands.moveToGroup() }
    @objc func showAllEntries(_ sender: Any?) { workspaceCommands.show(.allEntries) }
    @objc func showVerificationCodes(_ sender: Any?) { workspaceCommands.show(.verificationCodes) }
    @objc func showPasskeys(_ sender: Any?) { workspaceCommands.show(.passkeys) }
    @objc func chooseSortOrder(_ sender: NSMenuItem) {
        guard let order = (sender.representedObject as? String).flatMap(DatabaseViewModel.SortOrder.init(rawValue:)) else {
            return
        }
        workspaceCommands.setSortOrder(order)
    }
    @objc func chooseSortDirection(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool else { return }
        workspaceCommands.setSortAscending(ascending)
    }
    @objc func expandAllGroups(_ sender: Any?) { workspaceCommands.expandAllGroups() }
    @objc func collapseAllGroups(_ sender: Any?) { workspaceCommands.collapseAllGroups() }
    @objc func syncNow(_ sender: Any?) { workspaceCommands.syncNow() }
    @objc func importPasswords(_ sender: Any?) { workspaceCommands.importPasswords() }
    @objc func exportDatabase(_ sender: Any?) {
        guard workspaceCommands.canExportDatabase, databaseExportTask == nil else { return }
        let exporter = MacDatabaseExporter(panels: filePanels) { [weak self] in
            MacDatabaseExporter.showError($0, on: self?.window)
        }
        let request = DatabaseExportRequest.currentCopy(session.databaseReference)
        databaseExportTask = Task { [weak self] in
            await exporter.export(request)
            self?.databaseExportTask = nil
        }
    }
    @objc func showDatabaseSettings(_ sender: Any?) { workspaceCommands.showDatabaseSettings() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar):
            item.title = workspacePresentation.isSidebarCollapsed ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar")
            return isCommandTarget() && workspace.splitViewController != nil
        case #selector(newEntry): return commands.canNewEntry
        case #selector(newGroup): return commands.canNewGroup
        case #selector(saveDatabase): return workspaceCommands.canSave
        case #selector(closeDatabase): return commands.canCloseDatabase
        case #selector(copyUsername): return commands.canCopyUsername
        case #selector(copyPassword): return commands.canCopyPassword
        case #selector(copyURL): return commands.canCopyURL
        case #selector(copyVerificationCode): return commands.canCopyVerificationCode
        case #selector(showInLargeType): return commands.canShowPasswordInLargeType
        case #selector(editEntry): return commands.canEditEntry
        case #selector(deleteSelection):
            item.title = commands.deletesPermanently ? String(localized: "Delete Permanently") : String(localized: "Delete")
            return commands.canDelete
        case #selector(findEntry): return commands.canFind
        case #selector(lockDatabase): return commands.canLock
        case #selector(duplicateSelectedEntry): return workspaceCommands.canDuplicate
        case #selector(moveSelectedEntries): return workspaceCommands.canMoveToGroup
        case #selector(showAllEntries):
            item.state = workspaceCommands.isShowing(.allEntries) ? .on : .off
            return workspaceCommands.canShowCollection
        case #selector(showVerificationCodes):
            item.state = workspaceCommands.isShowing(.verificationCodes) ? .on : .off
            return workspaceCommands.canShowCollection
        case #selector(showPasskeys):
            item.state = workspaceCommands.isShowing(.passkeys) ? .on : .off
            return workspaceCommands.canShowCollection
        case #selector(chooseSortOrder):
            item.state = isCommandTarget() && item.representedObject as? String == session.sortOrder.rawValue ? .on : .off
            return workspaceCommands.canSort
        case #selector(chooseSortDirection):
            item.state = isCommandTarget() && item.representedObject as? Bool == session.sortAscending ? .on : .off
            return workspaceCommands.canSort
        case #selector(expandAllGroups): return workspaceCommands.canExpandAllGroups
        case #selector(collapseAllGroups): return workspaceCommands.canCollapseAllGroups
        case #selector(syncNow): return workspaceCommands.canSyncNow
        case #selector(importPasswords): return workspaceCommands.canImportPasswords
        case #selector(exportDatabase): return workspaceCommands.canExportDatabase
        case #selector(showDatabaseSettings): return workspaceCommands.canShowDatabaseSettings
        default: return false
        }
    }
}

struct MacHostingAppearance: ViewModifier {
    @AppStorage(SettingsService.appearanceModeDefaultsKey) private var appearance = SettingsService.AppearanceMode.system.rawValue
    @AppStorage(SettingsService.appAccentColorDefaultsKey) private var accent = ""

    func body(content: Content) -> some View {
        content
            .tint(SettingsService.AppAccentColor(rawValue: accent)?.color ?? Color("AccentColor"))
            .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch SettingsService.AppearanceMode(rawValue: appearance) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

final class DatabaseWindow: NSWindow {
    static let minimumContentSize = NSSize(width: 900, height: 620)
    nonisolated static let defaultContentSize = NSSize(width: 1080, height: 700)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    // Hosting resets this during layout even when its sizing options are empty.
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = Self.minimumContentSize }
    }
}
