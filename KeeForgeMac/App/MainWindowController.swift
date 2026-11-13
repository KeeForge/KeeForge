import AppKit
#if !KEEFORGE_DIRECT_DOWNLOAD
import StoreKit
#endif
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSMenuItemValidation {
    let windowRegistry: MacDatabaseWindowRegistry
    let sessionStore: DatabaseSessionStore
    let workspacePresentation = MacWorkspacePresentation()
    private lazy var workspace = MacWindowWorkspace(presentation: workspacePresentation)
    private let contentObservation = MacObservation()
    private let listViewModel: DatabaseListViewModel
    private let routing: AppRoutingCoordinator
    private let quickAccess: MacQuickAccessController
    private let sshAgent: MacSSHAgentController
    private let passwordCopyAction: EntrySecretAction
    private var pendingURLs: [URL] = []
    private var isRootReady = false
    private var setRootToolbarBridging: (@MainActor (Bool) -> Void)?

    var workspaceSplitViewController: MacWorkspaceSplitViewController? { workspace.splitViewController }
    var workspaceToolbar: MacWorkspaceToolbar? { workspace.toolbar }

    var session: DatabaseViewModel? { sessionStore.activeSession }
    private var commands: DatabaseCommands {
        DatabaseCommands(session: session, passwordCopyAction: passwordCopyAction)
    }

    init(
        listViewModel: DatabaseListViewModel,
        sessionStore: DatabaseSessionStore,
        routing: AppRoutingCoordinator,
        quickAccess: MacQuickAccessController,
        sshAgent: MacSSHAgentController,
        passwordCopyAction: EntrySecretAction = EntrySecretAction(),
        windowRegistry: MacDatabaseWindowRegistry? = nil
    ) {
        self.windowRegistry = windowRegistry ?? MacDatabaseWindowRegistry(sessionStore: sessionStore)
        self.listViewModel = listViewModel
        self.sessionStore = sessionStore
        self.routing = routing
        self.quickAccess = quickAccess
        self.sshAgent = sshAgent
        self.passwordCopyAction = passwordCopyAction
        super.init(window: nil)
        sessionStore.onActiveSessionChanged = { [weak self] in self?.updateWindowRegistration() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var root: AppRootView {
        AppRootView(listViewModel: listViewModel, sessionStore: sessionStore, routing: routing)
    }

    override func loadWindow() {
        guard window == nil else { return }
        let content = MacMainRoot(
            listViewModel: listViewModel,
            sessionStore: sessionStore,
            routing: routing,
            onReadyForURLs: { [weak self] in self?.rootDidBecomeReady() }
        )
        let hosting = NSHostingController(rootView: content
            .environment(windowRegistry)
            .environment(sessionStore)
            .environment(workspacePresentation)
            .environment(workspace)
            .environment(quickAccess)
            .environment(sshAgent)
            .modifier(MacHostingAppearance()))
        // AppKit owns the size limits; hosted toolbar safe areas must not raise them.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        setRootToolbarBridging = { [weak hosting] bridges in
            hosting?.sceneBridgingOptions = bridges ? [.toolbars] : []
        }
        let window = MainWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "KeeForge"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.isReleasedWhenClosed = false
        window.contentMinSize = MainWindow.minimumContentSize
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.center()
        window.setFrameAutosaveName("main-AppWindow-1")
        self.window = window
        updateWindowRegistration()
        contentObservation.start(reading: { [weak self] in
            let session = self?.session
            let unlocked = session?.state == .unlocked ? session : nil
            return (unlocked, unlocked?.databaseDisplayName ?? "KeeForge", MacWindowWorkspace.subtitle(for: unlocked))
        }, onChange: { [weak self] session, title, subtitle in
            guard let self else { return }
            self.workspace.show(session)
            self.installToolbar()
            self.window?.title = title
            self.window?.subtitle = subtitle
        })
        #if !KEEFORGE_DIRECT_DOWNLOAD
        ReviewPromptService.requestReviewHandler = { [weak hosting] in
            guard let hosting else { return }
            AppStore.requestReview(in: hosting)
        }
        #endif
    }

    /// The locked screens keep the root's bridged SwiftUI toolbar; the unlocked
    /// workspace replaces it with its own, so exactly one source owns the bar.
    private func installToolbar() {
        guard let window else { return }
        if let toolbar = workspace.toolbar?.toolbar {
            guard window.toolbar !== toolbar else { return }
            setRootToolbarBridging?(false)
            window.toolbar = toolbar
        } else if window.toolbar?.identifier == MacWorkspaceToolbar.identifier {
            window.toolbar = nil
            setRootToolbarBridging?(true)
        }
    }

    func handleOpenURL(_ url: URL) {
        guard isRootReady else {
            pendingURLs.append(url)
            return
        }
        root.handleOpenURL(url)
    }

    func rootDidBecomeReady() {
        guard !isRootReady else { return }
        isRootReady = true
        for url in pendingURLs { root.handleOpenURL(url) }
        pendingURLs.removeAll()
    }

    private func updateWindowRegistration() {
        guard let window else { return }
        if let id = session?.databaseReference.id {
            windowRegistry.register(window, databaseID: id)
        } else {
            windowRegistry.unregister(window)
        }
    }

    /// Fronts the main window when it shows `databaseID`, and reports whether it does.
    @discardableResult
    func showWindow(forDatabase databaseID: UUID) -> Bool {
        guard session?.databaseReference.id == databaseID else { return false }
        showMainWindow()
        return true
    }

    func showMainWindow() {
        if window == nil { loadWindow() }
        updateWindowRegistration()
        if NSApp.isHidden { NSApp.unhide(nil) }
        showWindow(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        workspace.splitViewController?.toggleSidebar(sender)
    }

    @objc func newEntry(_ sender: Any?) { commands.newEntry() }
    @objc func newGroup(_ sender: Any?) { commands.newGroup() }
    @objc func saveDatabase(_ sender: Any?) { commands.save() }
    @objc func closeDatabase(_ sender: Any?) {
        routing.requestDatabaseTransition(to: .close, from: session)
    }
    @objc func copyUsername(_ sender: Any?) { commands.copyUsername() }
    @objc func copyPassword(_ sender: Any?) {
        commands.copyPassword(activeSession: { [weak self] in self?.session })
    }
    @objc func copyURL(_ sender: Any?) { commands.copyURL() }
    @objc func copyVerificationCode(_ sender: Any?) { commands.copyVerificationCode() }
    @objc func editEntry(_ sender: Any?) { commands.editEntry() }
    @objc func deleteSelection(_ sender: Any?) { commands.deleteSelection() }
    @objc func findEntry(_ sender: Any?) { workspace.toolbar?.focusSearch() }
    @objc func lockDatabase(_ sender: Any?) { commands.lock() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar): return workspace.splitViewController != nil
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

private struct MacMainRoot: View {
    let listViewModel: DatabaseListViewModel
    let sessionStore: DatabaseSessionStore
    let routing: AppRoutingCoordinator
    let onReadyForURLs: () -> Void

    var body: some View { content }

    private var root: AppRootView {
        AppRootView(listViewModel: listViewModel, sessionStore: sessionStore, routing: routing, onReadyForURLs: onReadyForURLs)
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if AutoFillStoreInspectorView.isPresentationRequested {
            AutoFillStoreInspectorView()
        } else if AutoFillPickerHarnessView.isPresentationRequested {
            AutoFillPickerHarnessView()
        } else {
            root
        }
        #else
        root
        #endif
    }
}

private final class MainWindow: NSWindow {
    static let minimumContentSize = NSSize(width: 900, height: 620)

    // Hosting resets this during layout even when its sizing options are empty.
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = Self.minimumContentSize }
    }
}
