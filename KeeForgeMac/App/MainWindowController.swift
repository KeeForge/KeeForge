import AppKit
#if !KEEFORGE_DIRECT_DOWNLOAD
import StoreKit
#endif
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSMenuItemValidation {
    let sessionStore: DatabaseSessionStore
    private let listViewModel: DatabaseListViewModel
    private let routing: AppRoutingCoordinator
    private let quickAccess: MacQuickAccessController
    private let sshAgent: MacSSHAgentController
    private let passwordCopyAction: EntrySecretAction
    private var pendingURLs: [URL] = []
    private var isRootReady = false

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
        passwordCopyAction: EntrySecretAction = EntrySecretAction()
    ) {
        self.listViewModel = listViewModel
        self.sessionStore = sessionStore
        self.routing = routing
        self.quickAccess = quickAccess
        self.sshAgent = sshAgent
        self.passwordCopyAction = passwordCopyAction
        super.init(window: nil)
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
            quickAccess: quickAccess,
            sshAgent: sshAgent,
            onReadyForURLs: { [weak self] in self?.rootDidBecomeReady() }
        )
        let hosting = NSHostingController(rootView: content
            .environment(sessionStore)
            .environment(quickAccess)
            .environment(sshAgent)
            .modifier(MacHostingAppearance()))
        // AppKit owns the size limits; hosted toolbar safe areas must not raise them.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars, .title]
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
        quickAccess.mainWindow = window
        #if !KEEFORGE_DIRECT_DOWNLOAD
        ReviewPromptService.requestReviewHandler = { [weak hosting] in
            guard let hosting else { return }
            AppStore.requestReview(in: hosting)
        }
        #endif
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

    func showMainWindow() {
        if window == nil { loadWindow() }
        if NSApp.isHidden { NSApp.unhide(nil) }
        showWindow(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
    @objc func findEntry(_ sender: Any?) { commands.find() }
    @objc func lockDatabase(_ sender: Any?) { commands.lock() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
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
    let quickAccess: MacQuickAccessController
    let sshAgent: MacSSHAgentController
    let onReadyForURLs: () -> Void

    var body: some View {
        content.modifier(MacQuickAccessMainWindowHookup(controller: quickAccess, sshAgent: sshAgent, activeSession: sessionStore.activeSession))
    }

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
