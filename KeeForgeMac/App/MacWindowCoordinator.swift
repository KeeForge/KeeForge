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
        // performClose only beeps while a sheet disables the close button; the guard must still decide.
        guard window.attachedSheet != nil else {
            window.performClose(nil)
            return
        }
        if window.delegate?.windowShouldClose?(window) ?? true { window.close() }
    }
}

/// Owns the Databases window and one window per open database, and turns
/// `MacApplicationRouting` decisions into window effects.
///
/// A database's UUID names both its session and its window. Opening a
/// database never closes, locks or retires another one; a committed close
/// retires exactly that window's session.
///
/// It is also the only writer of the window topology in
/// `MacWindowRestorationStore`: restored windows come back locked and marked
/// as restoring, and a quit settles every window's unsaved work before the
/// pre-quit topology is kept.
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

    @ObservationIgnored private let restorationStore: MacWindowRestorationStore?
    @ObservationIgnored private let restoresWindows: Bool
    @ObservationIgnored private let screenFrames: @MainActor () -> [CGRect]
    @ObservationIgnored private let terminationPrompt: MacWindowCloseGuard.UnsavedWorkPrompt
    @ObservationIgnored private let removalPrompt: MacRemoveFromListAlert.Present
    @ObservationIgnored private let databaseWindowContentSize: NSSize
    @ObservationIgnored private var restorationPlan: MacWindowRestorationStore.Plan?
    /// Off until the recorded windows are back, so launch never overwrites them.
    @ObservationIgnored private(set) var isRecordingTopology = false
    /// Open database windows, back to front.
    @ObservationIgnored private var windowOrder: [UUID] = []
    /// The last frame outside full screen, which is what the next launch should restore.
    @ObservationIgnored private var normalFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var isDatabasesWindowOpen = false
    @ObservationIgnored private var databasesWindowFrame: CGRect?
    @ObservationIgnored private var collectsLaunchOpens = false
    @ObservationIgnored private var launchOpenIDs: [UUID] = []
    @ObservationIgnored private var knownDatabaseIDs: Set<UUID>?
    @ObservationIgnored private let databaseListObservation = MacObservation()
    @ObservationIgnored private var terminationTask: Task<Void, Never>?

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
        restorationStore: MacWindowRestorationStore? = nil,
        restoresWindows: Bool = true,
        screenFrames: @escaping @MainActor () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
        terminationPrompt: @escaping MacWindowCloseGuard.UnsavedWorkPrompt = MacWindowCloseGuard.presentQuitUnsavedWorkAlert,
        removalPrompt: @escaping MacRemoveFromListAlert.Present = MacRemoveFromListAlert.present,
        databaseWindowContentSize: NSSize = DatabaseWindow.defaultContentSize,
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
        self.restorationStore = restorationStore
        self.restoresWindows = restoresWindows && restorationStore != nil
        self.screenFrames = screenFrames
        self.terminationPrompt = terminationPrompt
        self.removalPrompt = removalPrompt
        self.databaseWindowContentSize = databaseWindowContentSize
        self.notificationCenter = notificationCenter
        self.deferredPresentationDelay = deferredPresentationDelay
        launcher = MacDatabasesLauncherViewModel(references: { listViewModel.databases })
        launcher.list = listViewModel
        launcher.status = { listViewModel.status(for: $0) }
        launcher.lastOpenedDescription = { DatabaseListViewModel.lastOpenedDescription(for: $0) }
        launcher.hasWindow = { [weak self] in self?.databaseWindows[$0] != nil }
        launcher.isUnlocked = { [weak self] in self?.isUnlocked($0) ?? false }
        launcher.openDatabase = { [weak self] in self?.open($0) }
        launcher.openCreatedDatabase = { [weak self] in self?.openCreated($0) }
        launcher.hasUnsavedWork = { [weak self] databaseID in
            self?.sessionStore.session(for: databaseID).map(Self.hasUnsavedWork) ?? false
        }
        launcher.removeDatabase = { [weak self] reference in
            guard let self else { return }
            if let session = self.sessionStore.session(for: reference.id) {
                guard !Self.hasUnsavedWork(session) else { self.launcher.refusedRemoval = reference; return }
                session.lockForDatabaseTransition()
                guard session.state == .locked else { self.launcher.refusedRemoval = reference; return }
            }
            let outcome = await listViewModel.removeDatabase(reference)
            switch outcome {
            case .removed, .alreadyMissing: break
            case .revokedRecoveryRequired, .revokedRegistryNotPublished:
                self.launcher.sheet = .details(reference.id)
            case .rejected, .notPublished, .revocationUnconfirmed, .visibleUnconfirmed:
                self.launcher.selectionAlert = .init(title: String(localized: "Databases"), message: CocoaError(.fileWriteUnknown).localizedDescription)
            }
        }
        launcher.chooseEnrollmentDestinationHandler = { [weak self] in self?.chooseEnrollmentDestination($0) }
        launcher.cancelEnrollmentDestinationHandler = { [weak self] in self?.enrollment.discardEnrollment() }
        quickAccess.showDatabaseWindow = { [weak self] in self?.showDatabaseWindow($0) ?? false }
        quickAccess.showDatabaseList = { [weak self] in self?.showDatabasesWindow() }
        observeApplication()
        observeDatabaseList()
    }

    static func enrollmentSession(for session: DatabaseViewModel) -> TOTPEnrollmentCoordinator.Session {
        TOTPEnrollmentCoordinator.Session(databaseID: session.databaseReference.id, identity: ObjectIdentifier(session),
            lockCycleID: session.lockCycleID, isUnlocked: session.state == .unlocked)
    }

    private var openDatabaseIDs: Set<UUID> { Set(databaseWindows.keys) }

    /// A database window open on its unlocked session.
    func isUnlocked(_ databaseID: UUID) -> Bool {
        databaseWindows[databaseID]?.session.state == .unlocked
    }

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
        collectsLaunchOpens = true
        for url in urls { handleOpenURL(url) }
        collectsLaunchOpens = false
        let quickLaunchID = transitionNotice ? nil : automaticOpenID
        let plan = makeRestorationPlan(quickLaunchDatabaseID: quickLaunchID)
        restorationPlan = plan
        databasesWindowFrame = plan?.databasesWindowFrame
        var effects = routing.beginStartup(transitionNotice: transitionNotice, whatsNew: release != nil,
            restoresWindows: plan != nil, automaticOpen: plan.map(\.quickLaunchDatabaseID) ?? quickLaunchID)
        effects += routing.becomeReady(openDatabaseIDs: openDatabaseIDs)
        apply(effects)
        ensureVisibleWindow()
    }

    private func makeRestorationPlan(quickLaunchDatabaseID: UUID?) -> MacWindowRestorationStore.Plan? {
        guard restoresWindows, let restorationStore else { return nil }
        let screens = screenFrames()
        let launcherSize = Self.frameSize(content: DatabasesWindowController.contentSize, style: DatabasesWindowController.styleMask)
        let defaultLauncherFrame = screens.first.map {
            CGRect(x: $0.midX - launcherSize.width / 2, y: $0.midY - launcherSize.height / 2,
                width: launcherSize.width, height: launcherSize.height)
        } ?? CGRect(origin: .zero, size: launcherSize)
        return restorationStore.restorationPlan(
            knownDatabases: listViewModel.databases,
            screens: screens,
            databaseWindowMinimumSize: Self.frameSize(content: DatabaseWindow.minimumContentSize, style: DatabaseWindow.styleMask),
            databasesWindowMinimumSize: launcherSize,
            defaultDatabasesWindowFrame: defaultLauncherFrame,
            quickLaunchDatabaseID: quickLaunchDatabaseID,
            explicitOpenRequests: launchOpenIDs
        )
    }

    private static func frameSize(content: NSSize, style: NSWindow.StyleMask) -> CGSize {
        NSWindow.frameRect(forContentRect: CGRect(origin: .zero, size: content), styleMask: style).size
    }

    /// Recreates the recorded windows locked and marked as restoring, so no
    /// automatic Touch ID prompt fires until the user turns to one of them.
    private func restoreWindows() {
        guard let plan = restorationPlan else { return }
        restorationPlan = nil
        for restored in plan.databaseWindows {
            let databaseID = restored.databaseID
            // A session that already exists is not a restoration; its own open path owns it.
            guard databaseWindows[databaseID] == nil, sessionStore.session(for: databaseID) == nil,
                  let reference = listViewModel.databases.first(where: { $0.id == databaseID }),
                  MacDatabasesLauncherViewModel.isAvailable(reference) else { continue }
            makeWindow(for: sessionStore.open(reference), restoredFrame: restored.frame)
        }
        if plan.showDatabasesWindow { showDatabasesWindow() }
        if let front = plan.frontmostDatabaseID, let controller = databaseWindows[front] { present(controller) }
        isRecordingTopology = true
        recordTopology()
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
        apply(routing.ensureVisibleWindow(hasVisibleWindows: isDatabasesWindowOpen || !databaseWindows.isEmpty))
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

    /// An explicit request to show this database: it also counts as the user
    /// turning to a restored window.
    @discardableResult
    func showDatabaseWindow(_ databaseID: UUID) -> Bool {
        guard let controller = databaseWindows[databaseID], controller.window != nil else { return false }
        noteDeliberateFocus(databaseID)
        present(controller)
        return true
    }

    func showDatabasesWindow() {
        let controller = databasesWindowController ?? makeDatabasesWindow()
        guard let window = controller.window else { return }
        isDatabasesWindowOpen = true
        presenter.show(window)
        recordTopology()
    }

    var databasesWindow: NSWindow? { databasesWindowController?.window }

    private func makeDatabasesWindow() -> DatabasesWindowController {
        let controller = DatabasesWindowController(coordinator: self)
        if let window = controller.window {
            if let databasesWindowFrame { window.setFrame(databasesWindowFrame, display: false) }
            prepareWindow(window)
        }
        controller.onWillClose = { [weak self] in
            self?.isDatabasesWindowOpen = false
            self?.recordTopology()
        }
        databasesWindowController = controller
        return controller
    }

    private func present(_ controller: DatabaseWindowController) {
        guard let window = controller.window else { return }
        presenter.show(window)
        bringToFront(controller.databaseID)
    }

    /// A click or key press in a database window, or an explicit request to
    /// show it, ends its restoration and asks for the automatic unlock it held back.
    func noteDeliberateFocus(_ databaseID: UUID) {
        guard let window = databaseWindows[databaseID]?.window,
              let registration = registry.registration(for: window), registration.window === window,
              registration.isRestoring else { return }
        registration.isRestoring = false
        notificationCenter.post(name: MacBiometricAutoUnlockController.restorationEndedNotification, object: window)
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

    private func makeWindow(for session: DatabaseViewModel, restoredFrame: CGRect? = nil) {
        let databaseID = session.databaseReference.id
        guard databaseWindows[databaseID] == nil else {
            showDatabaseWindow(databaseID)
            return
        }
        let presenter = self.presenter
        let controller = DatabaseWindowController(session: session, windowRegistry: registry, enrollment: enrollment,
            persistsLayout: persistsLayout, initialContentSize: databaseWindowContentSize,
            requestClose: { presenter.requestClose($0) })
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
        controller.onRemoveFromList = { [weak self] in self?.removeFromList(databaseID: databaseID) }
        controller.onWillClose = { [weak self] in self?.windowWillClose($0) }
        controller.workspacePresentation.pendingUploads = .list(listViewModel)
        controller.loadWindow()
        guard let window = controller.window else { return }
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else if let previous = windowOrder.last.flatMap({ databaseWindows[$0]?.window }) {
            // A new window cascades from the frontmost one instead of covering it.
            let next = window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
            window.cascadeTopLeft(from: next)
        }
        prepareWindow(window)
        databaseWindows[databaseID] = controller
        registry.register(window, databaseID: databaseID, isRestoring: restoredFrame != nil)
        startObservingSessions()
        present(controller)
    }

    /// Remove from List on a locked window's recovery page: the Databases
    /// window's rule and cleanup, asked in that window. The removal retires the
    /// session, which closes the window.
    func removeFromList(databaseID: UUID) {
        guard let controller = databaseWindows[databaseID], let window = controller.window,
              let reference = listViewModel.databases.first(where: { $0.id == databaseID }) else { return }
        guard launcher.canRemove(reference) else {
            removalPrompt(.refused, reference, window) { _ in }
            return
        }
        removalPrompt(.confirm, reference, window) { [weak self, weak controller] confirmed in
            guard confirmed, let self, let controller, self.databaseWindows[databaseID] === controller else { return }
            guard self.launcher.canRemove(reference) else {
                self.removalPrompt(.refused, reference, window) { _ in }
                return
            }
            Task {
                await self.launcher.remove(reference)
                self.showDatabasesWindow()
            }
        }
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
        windowOrder.removeAll { $0 == databaseID }
        normalFrames[databaseID] = nil
        recordTopology()
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

    /// Database ▸ Lock All Databases.
    var canLockAllDatabases: Bool {
        databaseWindows.keys.contains(where: isUnlocked)
    }

    /// Each unlocked window locks through its own path, so unsaved work asks there as it would for Lock.
    func lockAllDatabases() {
        for controller in databaseWindows.values where controller.session.state == .unlocked {
            DatabaseCommands(session: controller.session).lock()
        }
    }

    /// Whether a Window-menu window is a database window, and if so whether it is unlocked.
    func lockState(of window: NSWindow) -> Bool? {
        databaseWindows.values.first { $0.window === window }.map { $0.session.state == .unlocked }
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
            if collectsLaunchOpens { launchOpenIDs.append(reference.id) }
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
            case .restoreWindows:
                restoreWindows()
            }
        }
    }

    // MARK: - Observation

    private func observeApplication() {
        observe(NSWindow.didBecomeKeyNotification) { coordinator, window in
            guard let window, let controller = coordinator.databaseWindows.values.first(where: { $0.window === window }) else { return }
            coordinator.lastFocusedDatabaseID = controller.databaseID
            coordinator.quickAccess.focusedDatabaseID = controller.databaseID
            coordinator.bringToFront(controller.databaseID)
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didExitFullScreenNotification] {
            observe(name) { coordinator, window in
                // A live resize is recorded once, when it ends.
                guard let window, name != NSWindow.didResizeNotification || !window.inLiveResize else { return }
                coordinator.windowGeometryDidChange(window)
            }
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

    // MARK: - Restoration record

    private func bringToFront(_ databaseID: UUID) {
        guard databaseWindows[databaseID] != nil, windowOrder.last != databaseID else { return }
        windowOrder.removeAll { $0 == databaseID }
        windowOrder.append(databaseID)
        recordTopology()
    }

    private func windowGeometryDidChange(_ window: NSWindow) {
        guard window === databasesWindow || databaseWindows.values.contains(where: { $0.window === window }) else { return }
        recordTopology()
    }

    /// What a relaunch would restore right now: identities and frames only.
    func currentTopology() -> MacWindowRestorationStore.Topology {
        let knownIDs = Set(listViewModel.databases.map(\.id))
        let windows = windowOrder.compactMap { databaseID -> MacWindowRestorationStore.DatabaseWindow? in
            guard knownIDs.contains(databaseID), let window = databaseWindows[databaseID]?.window else { return nil }
            if !window.styleMask.contains(.fullScreen) { normalFrames[databaseID] = window.frame }
            return .init(databaseID: databaseID, frame: normalFrames[databaseID] ?? window.frame)
        }
        if let window = databasesWindow, !window.styleMask.contains(.fullScreen) { databasesWindowFrame = window.frame }
        return .init(databaseWindows: windows, databasesWindowOpen: isDatabasesWindowOpen,
            databasesWindowFrame: databasesWindowFrame ?? .zero, frontmostDatabaseID: windows.last?.databaseID)
    }

    private func recordTopology() {
        guard isRecordingTopology, let restorationStore else { return }
        restorationStore.recordTopology(currentTopology())
    }

    /// A database removed from the list leaves no split geometry or window record behind.
    private func observeDatabaseList() {
        databaseListObservation.start(reading: { [weak self] in
            Set(self?.listViewModel.databases.map(\.id) ?? [])
        }, onChange: { [weak self] ids in
            guard let self else { return }
            defer { self.knownDatabaseIDs = ids }
            guard let previous = self.knownDatabaseIDs else { return }
            let removed = previous.subtracting(ids)
            guard !removed.isEmpty else { return }
            for databaseID in removed {
                self.restorationStore?.removeSavedGeometry(for: databaseID)
                self.windowOrder.removeAll { $0 == databaseID }
                self.normalFrames[databaseID] = nil
            }
            self.recordTopology()
        })
    }

    // MARK: - Termination

    /// Whether quitting now would lose something: a write in flight, locked or
    /// not, or an unlocked session with a failed write or an editor holding fields.
    var hasUnsavedWork: Bool {
        databaseWindows.values.contains { Self.hasUnsavedWork($0.session) }
    }

    private static func hasUnsavedWork(_ session: DatabaseViewModel) -> Bool {
        session.isSaving || (session.state == .unlocked && (session.isDirty || session.hasUnsavedEditor))
    }

    /// `applicationShouldTerminate(_:)`. Settles each window's unsaved work
    /// one at a time; any Cancel or failed save cancels the quit with every
    /// window and session as it was. Only a quit that goes ahead stops recording,
    /// after keeping the pre-quit topology.
    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateCancel }
        guard hasUnsavedWork else {
            prepareForTermination()
            return .terminateNow
        }
        let failures = Dictionary(databaseWindows.values.map {
            (ObjectIdentifier($0.session), $0.session.failedSettingsWriteCount)
        }, uniquingKeysWith: { first, _ in first })
        terminationTask = Task { @MainActor [weak self] in
            let settled = await self?.settleUnsavedWork(failures: failures) ?? false
            if settled { self?.prepareForTermination() }
            self?.terminationTask = nil
            reply(settled)
        }
        return .terminateLater
    }

    /// Also removes the plaintext attachment previews and KeeForge's clipboard copy: a quit does
    /// not close the windows or lock the sessions, so neither cleanup would otherwise run, and the
    /// clear timer dies with the process.
    private func prepareForTermination() {
        recordTopology()
        restorationStore?.beginTermination()
        for controller in databaseWindows.values { controller.attachmentPreview.windowClosed() }
        AttachmentPreviewFileStore.removeAll()
        ClipboardService.clearOwnedContents()
    }

    /// Every answer is collected before anything is written, so a later
    /// Cancel leaves earlier windows untouched. Don't Save needs no action:
    /// the draft goes with the process. A session asked about offers no SSH
    /// keys until the quit ends; one that does not go ahead releases it.
    private func settleUnsavedWork(failures: [ObjectIdentifier: Int]) async -> Bool {
        var held: [DatabaseViewModel] = []
        let settled = await settleUnsavedWork(failures: failures, holding: &held)
        if !settled {
            for session in held { session.releaseQuitHold() }
        }
        return settled
    }

    private func settleUnsavedWork(failures: [ObjectIdentifier: Int], holding held: inout [DatabaseViewModel]) async -> Bool {
        let controllers = windowOrder.reversed().compactMap { databaseWindows[$0] }
        // Only the editor can settle its own fields, so it is asked as a window close asks it.
        for editing in controllers where editing.session.state == .unlocked && editing.session.hasUnsavedEditor {
            present(editing)
            guard await settleEditor(in: editing.session), isCurrent(editing) else { return false }
        }
        var saves: [DatabaseWindowController] = []
        // Don't Save covers the draft as it was when answered, not work added to it later.
        var discardedRevisions: [ObjectIdentifier: Int] = [:]
        for controller in controllers {
            let session = controller.session
            await session.waitForInFlightSave()
            guard isCurrent(controller) else { return false }
            // A failed key or settings change is only reported in its window.
            guard session.failedSettingsWriteCount == failures[ObjectIdentifier(session)] ?? session.failedSettingsWriteCount else {
                present(controller)
                return false
            }
            guard session.state == .unlocked, session.isDirty else { continue }
            session.holdForQuitPrompt()
            held.append(session)
            present(controller)
            let choice = await terminationPrompt(controller.window, !session.isReadOnly)
            guard isCurrent(controller), session.state == .unlocked else { return false }
            switch choice {
            case .cancel: return false
            case .save: saves.append(controller)
            case .discard: discardedRevisions[ObjectIdentifier(session)] = session.contentRevision
            }
        }
        for controller in saves {
            await controller.session.saveHandlingError()
            guard isCurrent(controller), !controller.session.isDirty, controller.session.saveError == nil else {
                if isCurrent(controller) { present(controller) }
                return false
            }
        }
        // Work that became unsaved while the prompts were up also stops the quit.
        return !databaseWindows.values.contains { controller in
            let session = controller.session
            guard Self.hasUnsavedWork(session) else { return false }
            return session.isSaving || session.hasUnsavedEditor
                || discardedRevisions[ObjectIdentifier(session)] != session.contentRevision
        }
    }

    /// Raises the editor's Save, Discard or Keep Editing prompt as a lock request and waits for the
    /// lock. Keep Editing, or a save that fails, leaves the session unlocked and stops the quit.
    private func settleEditor(in session: DatabaseViewModel) async -> Bool {
        session.lockRequest(manuallyTriggered: true)
        while session.state == .unlocked {
            guard session.pendingLockRequest != nil || session.isSavingBeforeLock || session.isSaving else { return false }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = (session.state, session.pendingLockRequest, session.isSavingBeforeLock, session.isSaving)
                } onChange: {
                    Task { @MainActor in continuation.resume() }
                }
            }
        }
        return true
    }

    private func isCurrent(_ controller: DatabaseWindowController) -> Bool {
        databaseWindows[controller.databaseID] === controller
            && sessionStore.session(for: controller.databaseID) === controller.session
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

/// Launch arguments that change window restoration, honored only with `-ui-testing`.
/// UI tests start with no restored windows and record nothing; they choose the
/// database window size with `-ui-testing-database-window-size <width>x<height>`.
struct MacWindowLaunchOptions: Equatable {
    static let databaseWindowSizeArgument = "-ui-testing-database-window-size"
    private(set) var restoresWindows = true
    private(set) var databaseWindowContentSize = DatabaseWindow.defaultContentSize

    init(arguments: [String]) {
        guard arguments.contains("-ui-testing") else { return }
        restoresWindows = false
        guard let index = arguments.firstIndex(of: Self.databaseWindowSizeArgument), index + 1 < arguments.count else { return }
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        databaseWindowContentSize = NSSize(width: parts[0], height: parts[1])
    }
}
