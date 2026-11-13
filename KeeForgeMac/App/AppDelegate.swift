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
    private let macSSHAgent = MacSSHAgentController()
    private(set) lazy var windowCoordinator = MacWindowCoordinator(listViewModel: listViewModel, sessionStore: sessionStore,
        registry: databaseWindowRegistry, quickAccess: macQuickAccess,
        prepareWindow: { [screenProtectionService] in screenProtectionService.applyCapturePolicy(to: $0) })
    private var settingsWindowController: SettingsWindowController?
    private var didLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didLaunch else { return }
        didLaunch = true
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
        macLockMonitor.windowRegistry = databaseWindowRegistry
        macLockMonitor.onUserActivity = { sessionStore.resetInactivityTimer(for: $0) }
        macLockMonitor.start()
        macWindowCloseGuard.start()
        macQuickAccess.sessionForDatabase = { sessionStore.session(for: $0) }
        macQuickAccess.start()
        macSSHAgent.sessionsProvider = { sessionStore.openSessions }
        macSSHAgent.start()
        // Database commands resolve through the coordinator while another window has focus.
        nextResponder = NSApp.nextResponder
        NSApp.nextResponder = self
        MainMenu.install(MainMenu.build())
        let transitionNotice = MacTransitionNoticeService.claimPresentation()
        windowCoordinator.start(
            transitionNotice: transitionNotice,
            whatsNewRelease: transitionNotice ? nil : WhatsNewPresentationService.releaseToPresent(),
            automaticOpenID: transitionNotice ? nil : listViewModel.databaseToAutoOpenOnLaunch()?.id
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
                quickAccess: macQuickAccess, sshAgent: macSSHAgent)
            if let window = settingsWindowController?.window { screenProtectionService.applyCapturePolicy(to: window) }
        }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newDatabase(_ sender: Any?) {
        windowCoordinator.showDatabasesWindow()
        listViewModel.requestNewDatabase()
    }

    @objc func connectToServer(_ sender: Any?) {
        guard let rawValue = (sender as? NSMenuItem)?.representedObject as? String,
              let provider = CloudProviderKind(rawValue: rawValue) else { return }
        windowCoordinator.showDatabasesWindow()
        windowCoordinator.launcher.requestConnect(provider)
    }

    @objc func showHelp(_ sender: Any?) { open("https://github.com/KeeForge/KeeForge#readme") }
    @objc func reportBug(_ sender: Any?) { open("https://github.com/KeeForge/KeeForge/issues") }

    #if KEEFORGE_DIRECT_DOWNLOAD
    @objc func checkForUpdates(_ sender: Any?) { SoftwareUpdateService.shared.checkForUpdates() }
    #endif

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(connectToServer):
            let rawValue = item.representedObject as? String
            return windowCoordinator.launcher.connectProviders.contains { $0.rawValue == rawValue }
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
        let credits = NSAttributedString(
            string: String(localized: "Open-source components and their licenses are listed in Settings › About › Acknowledgments."),
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .callout),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: version,
            .credits: credits,
        ]
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
