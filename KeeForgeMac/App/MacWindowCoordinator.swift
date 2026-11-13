import AppKit
import Observation
import OneTimeCodes

/// Window effects the coordinator asks AppKit for; tests record them instead
/// of showing or closing windows.
@MainActor
protocol MacWindowPresenting: AnyObject {
    func show(_ window: NSWindow)
    /// The guarded close a click on the close button would start.
    func requestClose(_ window: NSWindow)
}

@MainActor
final class MacSystemWindowPresenter: MacWindowPresenting {
    func show(_ window: NSWindow) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func requestClose(_ window: NSWindow) {
        window.performClose(nil)
    }
}

/// Owns the Databases window and one window per open database, and turns
/// `MacApplicationRouting` decisions into window effects.
///
/// A database's UUID names both its session and its window. Opening a
/// database never closes, locks or retires another one; a committed close
/// retires exactly that window's session.
@MainActor @Observable
final class MacWindowCoordinator {
    @ObservationIgnored let listViewModel: DatabaseListViewModel
    @ObservationIgnored let sessionStore: DatabaseSessionStore
    @ObservationIgnored let registry: MacDatabaseWindowRegistry
    @ObservationIgnored let routing = MacApplicationRouting()
    @ObservationIgnored let enrollment = TOTPEnrollmentCoordinator()
    @ObservationIgnored let launcher: MacDatabasesLauncherViewModel
    private(set) var databaseWindows: [UUID: DatabaseWindowController] = [:]
    /// The database window the user last focused; Settings, the Databases window and panels never replace it.
    private(set) var lastFocusedDatabaseID: UUID?

    @ObservationIgnored private let quickAccess: MacQuickAccessController
    @ObservationIgnored private let presenter: MacWindowPresenting
    @ObservationIgnored private let keyWindow: @MainActor () -> NSWindow?
    @ObservationIgnored private let mainWindow: @MainActor () -> NSWindow?
    @ObservationIgnored private let prepareWindow: @MainActor (NSWindow) -> Void
    @ObservationIgnored private let persistsLayout: Bool
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let deferredPresentationDelay: Duration
    @ObservationIgnored private var databasesWindowController: DatabasesWindowController?
    @ObservationIgnored private let sessionObservation = MacObservation()
    @ObservationIgnored private let deferredPresentationObservation = MacObservation()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var didStart = false

    init(
        listViewModel: DatabaseListViewModel,
        sessionStore: DatabaseSessionStore,
        registry: MacDatabaseWindowRegistry,
        quickAccess: MacQuickAccessController,
        presenter: MacWindowPresenting = MacSystemWindowPresenter(),
        keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
        mainWindow: @escaping @MainActor () -> NSWindow? = { NSApp.mainWindow },
        prepareWindow: @escaping @MainActor (NSWindow) -> Void = { _ in },
        persistsLayout: Bool = true,
        notificationCenter: NotificationCenter = .default,
        deferredPresentationDelay: Duration = .milliseconds(450)
    ) {
        self.listViewModel = listViewModel
        self.sessionStore = sessionStore
        self.registry = registry
        self.quickAccess = quickAccess
        self.presenter = presenter
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
        self.prepareWindow = prepareWindow
        self.persistsLayout = persistsLayout
        self.notificationCenter = notificationCenter
        self.deferredPresentationDelay = deferredPresentationDelay
        launcher = MacDatabasesLauncherViewModel(references: { listViewModel.databases })
        launcher.hasWindow = { [weak self] in self?.databaseWindows[$0] != nil }
        launcher.openDatabase = { [weak self] in self?.open($0) }
        launcher.openCreatedDatabase = { [weak self] in self?.openCreated($0) }
        launcher.chooseEnrollmentDestinationHandler = { [weak self] in self?.chooseEnrollmentDestination($0) }
        launcher.cancelEnrollmentDestinationHandler = { [weak self] in self?.enrollment.discardEnrollment() }
        quickAccess.showDatabaseWindow = { [weak self] in self?.showDatabaseWindow($0) ?? false }
        quickAccess.showDatabaseList = { [weak self] in self?.showDatabasesWindow() }
        observeApplication()
    }

    static func enrollmentSession(for session: DatabaseViewModel) -> TOTPEnrollmentCoordinator.Session {
        TOTPEnrollmentCoordinator.Session(databaseID: session.databaseReference.id, identity: ObjectIdentifier(session),
            lockCycleID: session.lockCycleID, isUnlocked: session.state == .unlocked)
    }

    private var openDatabaseIDs: Set<UUID> { Set(databaseWindows.keys) }

    // MARK: - Startup

    /// Launch presentations come first; URL and automatic opens wait for them.
    func start(transitionNotice: Bool, whatsNewRelease: WhatsNewRelease?, automaticOpenID: UUID?) {
        guard !didStart else { return }
        didStart = true
        let release = transitionNotice ? nil : whatsNewRelease
        launcher.whatsNewRelease = release
        enrollment.isLaunchPresentationPending = transitionNotice || release != nil
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls { handleOpenURL(url) }
        var effects = routing.beginStartup(transitionNotice: transitionNotice, whatsNew: release != nil,
            automaticOpen: transitionNotice ? nil : automaticOpenID)
        effects += routing.becomeReady(openDatabaseIDs: openDatabaseIDs)
        apply(effects)
        ensureVisibleWindow()
    }

    func finishLaunchPresentation(_ presentation: MacApplicationRouting.LaunchPresentation) {
        guard routing.launchPresentation == presentation else { return }
        if presentation == .whatsNew { launcher.whatsNewRelease = nil }
        apply(routing.finishLaunchPresentation(presentation, openDatabaseIDs: openDatabaseIDs))
        guard routing.launchPresentation == nil, enrollment.isLaunchPresentationPending else { return }
        enrollment.isLaunchPresentationPending = false
        // A link with no destination yet waits for the chooser instead.
        if enrollment.destinationDatabaseID != nil {
            enrollment.resumeEnrollmentAfterLaunchPresentation()
        }
    }

    func dockReopen(hasVisibleWindows: Bool) {
        apply(routing.dockReopen(hasVisibleWindows: hasVisibleWindows))
    }

    private func ensureVisibleWindow() {
        let launcherVisible = databasesWindowController?.window?.isVisible == true
        apply(routing.ensureVisibleWindow(hasVisibleWindows: launcherVisible || !databaseWindows.isEmpty))
    }

    // MARK: - Opening

    /// Opens the database's window, or fronts the one already open.
    func open(_ reference: DatabaseReference) {
        apply(routing.requestOpen(.database(reference.id), openDatabaseIDs: openDatabaseIDs))
    }

    func openCreated(_ createdDatabase: CreatedDatabase) {
        listViewModel.reload()
        let session = sessionStore.adopt(DatabaseViewModel(createdDatabase: createdDatabase))
        makeWindow(for: session)
    }

    @discardableResult
    func showDatabaseWindow(_ databaseID: UUID) -> Bool {
        guard let window = databaseWindows[databaseID]?.window else { return false }
        presenter.show(window)
        return true
    }

    func showDatabasesWindow() {
        let controller = databasesWindowController ?? makeDatabasesWindow()
        guard let window = controller.window else { return }
        presenter.show(window)
    }

    var databasesWindow: NSWindow? { databasesWindowController?.window }

    private func makeDatabasesWindow() -> DatabasesWindowController {
        let controller = DatabasesWindowController(coordinator: self)
        if let window = controller.window { prepareWindow(window) }
        databasesWindowController = controller
        return controller
    }

    private func reference(for databaseID: UUID) -> DatabaseReference? {
        if let reference = listViewModel.databases.first(where: { $0.id == databaseID }) { return reference }
        listViewModel.reload()
        return listViewModel.databases.first { $0.id == databaseID }
    }

    private func openWindow(databaseID: UUID) {
        if showDatabaseWindow(databaseID) { return }
        guard let reference = reference(for: databaseID), MacDatabasesLauncherViewModel.isAvailable(reference) else { return }
        makeWindow(for: sessionStore.open(reference))
    }

    private func makeWindow(for session: DatabaseViewModel) {
        let databaseID = session.databaseReference.id
        guard databaseWindows[databaseID] == nil else {
            showDatabaseWindow(databaseID)
            return
        }
        let presenter = self.presenter
        let controller = DatabaseWindowController(session: session, windowRegistry: registry, enrollment: enrollment,
            persistsLayout: persistsLayout, requestClose: { presenter.requestClose($0) })
        controller.isCommandTarget = { [weak self, weak controller] in
            guard let self, let controller else { return false }
            return self.commandTarget() === controller
        }
        controller.isCurrent = { [weak self, weak controller] in
            guard let self, let controller else { return false }
            return self.databaseWindows[databaseID] === controller
                && self.sessionStore.session(for: databaseID) === controller.session
        }
        controller.onReturnToDatabases = { [weak self, weak controller] in
            guard let self, let controller, self.databaseWindows[databaseID] === controller else { return }
            self.showDatabasesWindow()
            controller.requestGuardedClose()
        }
        controller.onWillClose = { [weak self] in self?.windowWillClose($0) }
        controller.loadWindow()
        guard let window = controller.window else { return }
        prepareWindow(window)
        databaseWindows[databaseID] = controller
        registry.register(window, databaseID: databaseID)
        startObservingSessions()
        presenter.show(window)
    }

    // MARK: - Closing

    /// A committed close: the close guard has settled unsaved work, so only
    /// this window's session is locked and retired.
    func windowWillClose(_ controller: DatabaseWindowController) {
        let databaseID = controller.databaseID
        guard databaseWindows[databaseID] === controller else { return }
        databaseWindows[databaseID] = nil
        if let window = controller.window { registry.unregister(window) }
        if lastFocusedDatabaseID == databaseID {
            lastFocusedDatabaseID = nil
            quickAccess.focusedDatabaseID = nil
        }
        if enrollment.destinationDatabaseID == databaseID {
            enrollment.updateSession(nil)
        }
        if sessionStore.session(for: databaseID) === controller.session {
            sessionStore.retire(databaseID, force: true)
        }
        controller.invalidate()
    }

    /// A session retired elsewhere (removed from the list) takes its window with it.
    private func startObservingSessions() {
        sessionObservation.start(reading: { [weak self] in
            self?.sessionStore.openSessions.map(ObjectIdentifier.init) ?? []
        }, onChange: { [weak self] _ in
            guard let self else { return }
            for (databaseID, controller) in self.databaseWindows
            where self.sessionStore.session(for: databaseID) !== controller.session {
                controller.window?.close()
                self.windowWillClose(controller)
            }
        })
    }

    // MARK: - Commands

    /// The database window a menu command acts on right now.
    func commandTarget() -> DatabaseWindowController? {
        MacDatabaseCommandTargetResolver(
            keyWindow: keyWindow(),
            mainWindow: mainWindow(),
            launcherWindow: databasesWindowController?.window,
            target: { [weak self] window in
                self?.databaseWindows.values.first { $0.window === window }
            }
        ).resolve()
    }

    // MARK: - Incoming URLs

    func handleOpenURL(_ url: URL) {
        guard didStart else {
            pendingURLs.append(url)
            return
        }
        if CloudProviderRegistry.handleOpenURL(url) { return }
        switch AppRoutingCoordinator.classify(url) {
        case .enrollment(let uri):
            receiveEnrollment(uri)
        case .invalidEnrollment(let alert):
            enrollment.enrollmentAlert = alert
            showEnrollmentAlertHost()
        case .database:
            guard let reference = databaseReference(forIncoming: url) else { return }
            apply(routing.requestOpen(.file(url, databaseID: reference.id), openDatabaseIDs: openDatabaseIDs))
        }
    }

    private func databaseReference(forIncoming url: URL) -> DatabaseReference? {
        do {
            return try listViewModel.addDatabase(from: url)
        } catch DatabaseListStore.AddDatabaseError.duplicateFile(let existingReferenceID, _) {
            return listViewModel.databases.first { $0.id == existingReferenceID }
        } catch {
            return listViewModel.databases.first { $0.filename == url.lastPathComponent }
        }
    }

    // MARK: - Enrollment

    /// Binds to the database window targeted when the link arrives; without
    /// one, the Databases window asks. Focus changes later never retarget it.
    private func receiveEnrollment(_ uri: OTPAuthURI) {
        let target = commandTarget()
        let effects = routing.receiveEnrollment(targetDatabaseID: target?.databaseID)
        if let target {
            enrollment.receiveEnrollment(uri, destination: Self.enrollmentSession(for: target.session))
        } else {
            enrollment.receiveEnrollment(uri, destination: nil)
            enrollment.enrollmentAlert = nil
        }
        apply(effects)
    }

    private func chooseEnrollmentDestination(_ databaseID: UUID) {
        apply(routing.chooseEnrollmentDestination(databaseID))
    }

    private func bindEnrollment(to databaseID: UUID) {
        openWindow(databaseID: databaseID)
        guard let controller = databaseWindows[databaseID] else {
            enrollment.discardEnrollment()
            return
        }
        if enrollment.destinationDatabaseID != databaseID {
            enrollment.selectDestination(Self.enrollmentSession(for: controller.session))
        }
    }

    /// Alerts belong to the destination's window while it is open, otherwise to the Databases window.
    var launcherHostsEnrollmentAlert: Bool {
        guard let destination = enrollment.destinationDatabaseID else { return true }
        return databaseWindows[destination] == nil
    }

    private func showEnrollmentAlertHost() {
        if let destination = enrollment.destinationDatabaseID, showDatabaseWindow(destination) { return }
        showDatabasesWindow()
    }

    // MARK: - Effects

    func apply(_ effects: [MacApplicationRouting.Effect]) {
        for effect in effects {
            switch effect {
            case .present, .showLauncher:
                showDatabasesWindow()
            case .open(let request):
                openWindow(databaseID: request.databaseID)
            case .front(let databaseID):
                openWindow(databaseID: databaseID)
            case .bindEnrollment(let databaseID):
                bindEnrollment(to: databaseID)
            case .askEnrollmentDestination:
                launcher.isChoosingEnrollmentDestination = true
            }
        }
    }

    // MARK: - Observation

    private func observeApplication() {
        observe(NSWindow.didBecomeKeyNotification) { coordinator, window in
            guard let window, let controller = coordinator.databaseWindows.values.first(where: { $0.window === window }) else { return }
            coordinator.lastFocusedDatabaseID = controller.databaseID
            coordinator.quickAccess.focusedDatabaseID = controller.databaseID
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observe(name) { coordinator, _ in coordinator.enrollment.discardExpiredEnrollment() }
        }
        let delay = deferredPresentationDelay
        deferredPresentationObservation.start(reading: { [weak self] in
            self?.enrollment.deferredPresentation?.id
        }, onChange: { [weak self] requestID in
            guard let requestID else { return }
            // SwiftUI drops a presentation raised while another sheet is dismissing.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                self?.enrollment.completeDeferredPresentation(id: requestID)
            }
        })
    }

    private func observe(_ name: Notification.Name, handler: @escaping @MainActor (MacWindowCoordinator, NSWindow?) -> Void) {
        let token = notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
            guard Thread.isMainThread else { return }
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, window)
            }
        }
        observers.append(token)
    }
}
