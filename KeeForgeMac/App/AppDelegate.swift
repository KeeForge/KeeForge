import AppKit
#if !KEEFORGE_DIRECT_DOWNLOAD
import StoreKit
#endif

@MainActor
final class AppDelegate: NSResponder, NSApplicationDelegate, NSMenuItemValidation {
    let listViewModel = DatabaseListViewModel()
    let sessionStore = DatabaseSessionStore()
    private let pendingUploadDrainer = PendingUploadDrainer()
    private let screenProtectionService = ScreenProtectionService()
    private let macLockMonitor = MacLockMonitor()
    lazy var databaseWindowRegistry = MacDatabaseWindowRegistry(sessionStore: sessionStore)
    private lazy var macWindowCloseGuard = MacWindowCloseGuard(registry: databaseWindowRegistry)
    private let macQuickAccess = MacQuickAccessController()
    private let macBrowserBridge = MacBrowserBridgeController()
    private var browserBridgePrompts: MacBrowserBridgePrompts?
    private let browserHostRepairObservation = MacObservation()
    private lazy var browserHosts = BrowserHostInstaller { [weak self] request in
        await MacFilePanels.presentAsSheet(MacFilePanels.makeBrowserFolderPanel(for: request),
                                           on: self?.settingsWindowController?.window)
    }
    private let macSSHAgent = MacSSHAgentController()
    private let appAppearance = MacAppAppearance()
    private(set) lazy var windowCoordinator: MacWindowCoordinator = {
        let options = MacWindowLaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        // A unit-test host never reads or writes the app's own window record.
        let restorationStore = AppGroupContainer.isRedirectedForTesting ? nil : MacWindowRestorationStore(defaults: .standard)
        return MacWindowCoordinator(listViewModel: listViewModel, sessionStore: sessionStore,
            registry: databaseWindowRegistry, quickAccess: macQuickAccess,
            prepareWindow: { [screenProtectionService] in screenProtectionService.applyCapturePolicy(to: $0) },
            restorationStore: restorationStore, restoresWindows: options.restoresWindows,
            databaseWindowContentSize: options.databaseWindowContentSize)
    }()
    private var settingsWindowController: SettingsWindowController?
    private(set) lazy var passwordGenerator = MacPasswordGeneratorPanelController { [sessionStore] in
        sessionStore.openSessions.contains { $0.state == .unlocked }
    }
    private lazy var windowMenuDecorator = MacWindowMenuDecorator { [weak self] in
        self?.windowCoordinator.lockState(of: $0)
    }
    private var didLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didLaunch else { return }
        didLaunch = true
        appAppearance.start()
        AutoFillDiagnostics.migrateLegacyLogLocation()
        screenProtectionService.update(sceneIsActive: NSApp.isActive)
        AttachmentPreviewFileStore.purgeOrphanedFiles()
        DatabaseExportService.purgeShareFiles()
        #if !KEEFORGE_DIRECT_DOWNLOAD
        StoreKitManager.shared.start()
        let windowCoordinator = self.windowCoordinator
        ReviewPromptService.requestReviewHandler = {
            MainActor.assumeIsolated {
                guard let content = windowCoordinator.commandTarget()?.window?.contentViewController else { return }
                AppStore.requestReview(in: content)
            }
        }
        #endif
        pendingUploadDrainer.startObserving { [listViewModel] in
            Task { await listViewModel.drainPendingUploadsOnAppActive() }
        }
        let sessionStore = self.sessionStore
        let listViewModel = self.listViewModel
        sessionStore.installListHooks(on: listViewModel)
        macLockMonitor.onLockTriggered = { _ in
            NotificationCenter.default.post(name: MacBiometricAutoUnlockController.lockRequestedNotification, object: nil)
            sessionStore.handleAppDidEnterBackground()
        }
        macLockMonitor.onDidBecomeActive = {
            sessionStore.handleAppDidBecomeActive()
            Task { await listViewModel.drainPendingUploadsOnAppActive() }
        }
        macLockMonitor.hasSessionsToLock = { sessionStore.openSessions.contains { $0.state == .unlocked || $0.state == .unlocking } }
        macLockMonitor.windowRegistry = databaseWindowRegistry
        let coordinator = self.windowCoordinator
        macLockMonitor.onUserActivity = {
            sessionStore.resetInactivityTimer(for: $0)
            coordinator.noteDeliberateFocus($0)
        }
        macLockMonitor.start()
        macWindowCloseGuard.start()
        macQuickAccess.sessionForDatabase = { sessionStore.session(for: $0) }
        macQuickAccess.start()
        macSSHAgent.sessionsProvider = { sessionStore.openSessions }
        macSSHAgent.start()
        macBrowserBridge.sessionsProvider = { sessionStore.openSessions }
        let browserBridgePrompts = MacBrowserBridgePrompts(source: macBrowserBridge,
                                                           shell: MacBrowserBridgeWindowShell(coordinator: coordinator))
        self.browserBridgePrompts = browserBridgePrompts
        macBrowserBridge.reveal = { [weak browserBridgePrompts] in browserBridgePrompts?.reveal(entryID: $0, databaseID: $1) }
        macBrowserBridge.unlock = { [weak browserBridgePrompts] in browserBridgePrompts?.unlock(databaseID: $0) }
        macBrowserBridge.start()
        repairBrowserHostsOnceListening()
        // Database commands resolve through the coordinator while another window has focus.
        nextResponder = NSApp.nextResponder
        NSApp.nextResponder = self
        MainMenu.install(MainMenu.build())
        NSApp.windowsMenu?.delegate = windowMenuDecorator
        let transitionNotice = MacTransitionNoticeService.claimPresentation()
        windowCoordinator.start(
            transitionNotice: transitionNotice,
            whatsNewRelease: transitionNotice ? nil : WhatsNewPresentationService.releaseToPresent(),
            automaticOpenID: transitionNotice ? nil : listViewModel.databaseToAutoOpenOnLaunch()?.id
        )
    }

    /// A moved or updated app rewrites its manifests from the folder access it already has, once per
    /// launch when its bridge first listens; this never prompts.
    private func repairBrowserHostsOnceListening() {
        browserHostRepairObservation.start(reading: { [macBrowserBridge] in macBrowserBridge.isListening }) { [weak self] listening in
            guard let self, listening else { return }
            browserHostRepairObservation.cancel()
            guard BrowserHostInstaller.mayRepairAtLaunch(appBundle: Bundle.main.bundleURL,
                                                         home: BrowserHostInstaller.realHomeDirectory(),
                                                         bridgeListening: listening) else { return }
            browserHosts.repairAll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        macBrowserBridge.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Logout and restart arrive here too.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowCoordinator.requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowCoordinator.dockReopen(hasVisibleWindows: flag)
        return true
    }

    // Queued by the coordinator until the launch presentations are done.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { windowCoordinator.handleOpenURL(url) }
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let target = windowCoordinator.commandTarget(), target.responds(to: action) {
            return target
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    @objc func showDatabasesWindow(_ sender: Any?) { windowCoordinator.showDatabasesWindow() }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(listViewModel: listViewModel, sessionStore: sessionStore,
                quickAccess: macQuickAccess, sshAgent: macSSHAgent,
                browserBridge: macBrowserBridge, browserHosts: browserHosts,
                prepareWindow: { [screenProtectionService] in screenProtectionService.applyCapturePolicy(to: $0) })
        }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newDatabase(_ sender: Any?) {
        guard windowCoordinator.launcher.canCreateDatabase else { return }
        windowCoordinator.showDatabasesWindow()
        windowCoordinator.launcher.requestNewDatabase()
    }

    @objc func lockAllDatabases(_ sender: Any?) { windowCoordinator.lockAllDatabases() }

    @objc func showPasswordGenerator(_ sender: Any?) {
        guard canShowPasswordGenerator else { return }
        passwordGenerator.show()
    }

    /// While the database a menu command would act on is unlocked.
    private var canShowPasswordGenerator: Bool {
        windowCoordinator.commandTarget()?.session.state == .unlocked
    }

    @objc func showCloudRecovery(_ sender: Any?) {
        guard !windowCoordinator.launcher.isSheetBusy() else { return }
        windowCoordinator.showDatabasesWindow()
        windowCoordinator.launcher.requestCloudRecovery()
    }

    @objc func connectToServer(_ sender: Any?) {
        guard windowCoordinator.launcher.canRequestConnect else { return }
        windowCoordinator.showDatabasesWindow()
        windowCoordinator.launcher.requestConnect()
    }

    @objc func showHelp(_ sender: Any?) { open("https://github.com/KeeForge/KeeForge#readme") }
    @objc func reportBug(_ sender: Any?) { open("https://github.com/KeeForge/KeeForge/issues") }

    #if KEEFORGE_DIRECT_DOWNLOAD
    @objc func checkForUpdates(_ sender: Any?) { SoftwareUpdateService.shared.checkForUpdates() }
    #endif

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(connectToServer): return windowCoordinator.launcher.canRequestConnect
        case #selector(showCloudRecovery): return !windowCoordinator.launcher.isSheetBusy()
        case #selector(newDatabase): return windowCoordinator.launcher.canCreateDatabase
        case #selector(lockAllDatabases): return windowCoordinator.canLockAllDatabases
        case #selector(showPasswordGenerator): return canShowPasswordGenerator
        #if KEEFORGE_DIRECT_DOWNLOAD
        case #selector(checkForUpdates): return SoftwareUpdateService.shared.canCheckForUpdates
        #endif
        default: return true
        }
    }

    @objc func openDatabase(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [DocumentPickerService.databaseContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a KeePass .kdbx database to open.")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let reference = try listViewModel.addDatabase(from: url)
            windowCoordinator.open(reference)
        } catch DatabaseListStore.AddDatabaseError.duplicateFile(let existingReferenceID, _) {
            guard let existing = listViewModel.databases.first(where: { $0.id == existingReferenceID }) else { return }
            windowCoordinator.open(existing)
        } catch {
            presentOpenFailure(error)
        }
    }

    private func presentOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t Open Database")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let commit = (bundle.object(forInfoDictionaryKey: "GITCommitHash") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationVersion: version]
        if let commit, commit.isEmpty == false {
            options[.version] = commit
        }

        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
