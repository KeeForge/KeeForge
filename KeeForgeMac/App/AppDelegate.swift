import AppKit
#if !KEEFORGE_DIRECT_DOWNLOAD
import StoreKit
#endif

@MainActor
final class AppDelegate: NSResponder, NSApplicationDelegate, NSMenuItemValidation {
    let listViewModel = DatabaseListViewModel()
    let sessionStore = DatabaseSessionStore()
    let routing = AppRoutingCoordinator()
    private let pendingUploadDrainer = PendingUploadDrainer()
    private let screenProtectionService = ScreenProtectionService()
    private let macLockMonitor = MacLockMonitor()
    private let macWindowCloseGuard = MacWindowCloseGuard()
    private let macQuickAccess = MacQuickAccessController()
    private let macSSHAgent = MacSSHAgentController()
    private(set) var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var pendingURLs: [URL] = []
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
        #endif
        pendingUploadDrainer.startObserving { [listViewModel] in
            Task { await listViewModel.drainPendingUploadsOnAppActive() }
        }
        let sessionStore = self.sessionStore
        let listViewModel = self.listViewModel
        macLockMonitor.onLockTriggered = { _ in
            NotificationCenter.default.post(name: MacBiometricAutoUnlockController.lockRequestedNotification, object: nil)
            sessionStore.handleAppDidEnterBackground()
        }
        macLockMonitor.onDidBecomeActive = {
            sessionStore.handleAppDidBecomeActive()
            Task { await listViewModel.drainPendingUploadsOnAppActive() }
        }
        macLockMonitor.onUserActivity = { sessionStore.resetInactivityTimers() }
        macLockMonitor.start()
        macWindowCloseGuard.vaultProvider = { sessionStore.activeSession }
        macWindowCloseGuard.start()
        macQuickAccess.openMainWindow = { [weak self] in self?.showMainWindow() }
        macQuickAccess.start()
        macSSHAgent.sessionProvider = { sessionStore.activeSession }
        macSSHAgent.start()
        let controller = MainWindowController(listViewModel: listViewModel, sessionStore: sessionStore,
            routing: routing, quickAccess: macQuickAccess, sshAgent: macSSHAgent)
        mainWindowController = controller
        // Keep database commands reachable while an auxiliary window has focus.
        nextResponder = NSApp.nextResponder
        NSApp.nextResponder = self
        MainMenu.install(MainMenu.build())
        showMainWindow()
        for url in pendingURLs { controller.handleOpenURL(url) }
        pendingURLs.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let mainWindowController else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        showMainWindow()
        for url in urls { mainWindowController.handleOpenURL(url) }
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let mainWindowController, mainWindowController.responds(to: action) {
            return mainWindowController
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func showMainWindow() { mainWindowController?.showMainWindow() }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(listViewModel: listViewModel, sessionStore: sessionStore,
                quickAccess: macQuickAccess, sshAgent: macSSHAgent)
        }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newDatabase(_ sender: Any?) {
        showMainWindow()
        listViewModel.requestNewDatabase()
    }

    @objc func showHelp(_ sender: Any?) { open("https://github.com/KeeForge/KeeForge#readme") }
    @objc func reportBug(_ sender: Any?) { open("https://github.com/KeeForge/KeeForge/issues") }

    #if KEEFORGE_DIRECT_DOWNLOAD
    @objc func checkForUpdates(_ sender: Any?) { SoftwareUpdateService.shared.checkForUpdates() }
    #endif

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newDatabase): return sessionStore.activeSession?.state != .unlocked
        case #selector(openDatabase): return sessionStore.activeSession?.isSaving != true
        #if KEEFORGE_DIRECT_DOWNLOAD
        case #selector(checkForUpdates): return SoftwareUpdateService.shared.canCheckForUpdates
        #endif
        default: return true
        }
    }

    @objc func openDatabase(_ sender: Any?) {
        showMainWindow()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [DocumentPickerService.databaseContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a KeePass .kdbx database to open.")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let reference = try listViewModel.addDatabase(from: url)
            openSession(reference)
        } catch DatabaseListStore.AddDatabaseError.duplicateFile(let existingReferenceID, _) {
            guard let existing = listViewModel.databases.first(where: { $0.id == existingReferenceID }) else { return }
            openSession(existing)
        } catch {
            presentOpenFailure(error)
        }
    }

    private func openSession(_ reference: DatabaseReference) {
        routing.requestDatabaseTransition(to: .open(reference), from: sessionStore.activeSession)
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
