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
    private lazy var workspace = MacWindowWorkspace(
        presentation: workspacePresentation,
        splitAutosaveName: splitAutosaveName,
        currentSession: { [weak self] in self?.currentSession() }
    )
    private let titleObservation = MacObservation()
    private let windowRegistry: MacDatabaseWindowRegistry
    private let enrollment: TOTPEnrollmentCoordinator
    private let passwordCopyAction: EntrySecretAction
    private let requestClose: @MainActor (NSWindow) -> Void
    private var setRootToolbarBridging: (@MainActor (Bool) -> Void)?
    private var closeObserver: NSObjectProtocol?

    /// Menu validation and dispatch act only while this is the command target; set by the coordinator.
    var isCommandTarget: @MainActor () -> Bool = { true }
    /// Whether this controller still owns its database's window, rechecked after authentication.
    var isCurrent: @MainActor () -> Bool = { true }
    /// The unlock screen's way back: closes this window and shows the Databases window.
    var onReturnToDatabases: (@MainActor () -> Void)?
    var onWillClose: (@MainActor (DatabaseWindowController) -> Void)?

    var databaseID: UUID { session.databaseReference.id }
    var workspaceSplitViewController: MacWorkspaceSplitViewController? { workspace.splitViewController }
    var workspaceToolbar: MacWorkspaceToolbar? { workspace.toolbar }

    static func windowIdentifier(for databaseID: UUID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("database.\(databaseID.uuidString)")
    }

    private var commands: DatabaseCommands {
        DatabaseCommands(session: isCommandTarget() ? session : nil, passwordCopyAction: passwordCopyAction)
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
        requestClose: @escaping @MainActor (NSWindow) -> Void = { $0.performClose(nil) }
    ) {
        self.session = session
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
        let content = MacDatabaseRootView(session: session, enrollment: enrollment, onClose: { [weak self] in
            self?.onReturnToDatabases?()
        })
        let hosting = NSHostingController(rootView: content
            .environment(windowRegistry)
            .environment(workspacePresentation)
            .environment(workspace)
            .modifier(MacHostingAppearance()))
        // AppKit owns the size limits; hosted toolbar safe areas must not raise them.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        setRootToolbarBridging = { [weak hosting] bridges in
            hosting?.sceneBridgingOptions = bridges ? [.toolbars] : []
        }
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
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onWillClose?(self)
            }
        }
        titleObservation.start(reading: { [weak self] () -> (DatabaseViewModel?, String, String) in
            guard let session = self?.session else { return (nil, "", "") }
            let unlocked = session.state == .unlocked ? session : nil
            return (unlocked, session.databaseDisplayName, MacWindowWorkspace.subtitle(for: unlocked))
        }, onChange: { [weak self] unlocked, title, subtitle in
            guard let self else { return }
            self.workspace.show(unlocked)
            self.installToolbar()
            self.window?.title = title
            self.window?.subtitle = subtitle
        })
    }

    /// Stops observing once the window has closed for good.
    func invalidate() {
        titleObservation.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        onWillClose = nil
        onReturnToDatabases = nil
        workspace.show(nil)
    }

    /// The locked screens keep the root's bridged SwiftUI toolbar; the unlocked
    /// workspace replaces it with its own, so exactly one source owns the bar.
    /// The workspace hides the title, which its list header shows instead.
    private func installToolbar() {
        guard let window else { return }
        if let toolbar = workspace.toolbar?.toolbar {
            guard window.toolbar !== toolbar else { return }
            setRootToolbarBridging?(false)
            window.toolbar = toolbar
            window.titleVisibility = .hidden
        } else if window.toolbar?.identifier == MacWorkspaceToolbar.identifier {
            window.toolbar = nil
            window.titleVisibility = .visible
            setRootToolbarBridging?(true)
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
    @objc func saveDatabase(_ sender: Any?) { commands.save() }
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
        isCommandTarget() ? session.workspace.commandEntryID : nil
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
    @objc func showDatabaseSettings(_ sender: Any?) { workspaceCommands.showDatabaseSettings() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar):
            item.title = workspacePresentation.isSidebarCollapsed ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar")
            return isCommandTarget() && workspace.splitViewController != nil
        case #selector(newEntry): return commands.canNewEntry
        case #selector(newGroup): return commands.canNewGroup
        case #selector(saveDatabase): return commands.canSave
        case #selector(closeDatabase): return commands.canCloseDatabase
        case #selector(copyUsername): return commands.canCopyUsername
        case #selector(copyPassword): return commands.canCopyPassword
        case #selector(copyURL): return commands.canCopyURL
        case #selector(copyVerificationCode): return commands.canCopyVerificationCode
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
