#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

/// Window effects go through a recording presenter: nothing is shown, and
/// `persistsLayout: false` keeps frames and split state out of the host app's defaults.
@MainActor
final class MacWindowCoordinatorTests: XCTestCase {
    @MainActor
    private final class Presenter: MacWindowPresenting {
        var shown: [NSWindow] = []
        var closeRequests: [NSWindow] = []
        func show(_ window: NSWindow) { shown.append(window) }
        func requestClose(_ window: NSWindow) { closeRequests.append(window) }
    }

    @MainActor
    private final class Focus {
        var key: NSWindow?
        var main: NSWindow?
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    private var presenter: Presenter!
    private var focus: Focus!
    private var center: NotificationCenter!
    private var list: DatabaseListViewModel!
    private var store: DatabaseSessionStore!
    private var registry: MacDatabaseWindowRegistry!
    private var quickAccess: MacQuickAccessController!
    private var coordinator: MacWindowCoordinator!
    private var prepared: [NSWindow] = []
    private var references: [DatabaseReference] = []
    private var fileURLs: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        fileURLs = try (0..<3).map { try temporaryCopyOfFixture(named: "coordinator-\($0).kdbx") }
        references = try fileURLs.map { try DatabaseListStore.add(url: $0) }
        presenter = Presenter()
        focus = Focus()
        center = NotificationCenter()
        prepared = []
        list = DatabaseListViewModel()
        list.reload()
        store = DatabaseSessionStore(makeSession: {
            DatabaseViewModel(databaseReference: $0,
                quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        })
        store.installListHooks(on: list)
        registry = MacDatabaseWindowRegistry(sessionStore: store)
        quickAccess = MacQuickAccessController(presenter: QuickSearchPresenterStub(), hotKey: HotKeyStub())
        let focus = self.focus!
        coordinator = MacWindowCoordinator(listViewModel: list, sessionStore: store, registry: registry,
            quickAccess: quickAccess, presenter: presenter,
            keyWindow: { focus.key }, mainWindow: { focus.main },
            prepareWindow: { [weak self] in self?.prepared.append($0) },
            persistsLayout: false, notificationCenter: center, deferredPresentationDelay: .zero)
    }

    override func tearDown() async throws {
        for controller in coordinator.databaseWindows.values {
            controller.session.lockRequest(force: true)
            controller.window?.close()
        }
        coordinator.databasesWindow?.close()
        coordinator = nil
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    // MARK: - Opening

    func testOpeningSeveralDatabasesKeepsEachSessionAndADuplicateOpenFrontsTheSameWindow() async throws {
        start()
        XCTAssertTrue(presenter.shown.last === coordinator.databasesWindow, "No database window: Databases shows")
        let (a, b, c) = (references[0], references[1], references[2])
        coordinator.open(a)
        let controllerA = try XCTUnwrap(coordinator.databaseWindows[a.id])
        let windowA = try XCTUnwrap(controllerA.window)
        XCTAssertTrue(presenter.shown.last === windowA)
        XCTAssertTrue(prepared.contains { $0 === windowA }, "Capture policy applies before the window is shown")
        XCTAssertTrue(registry.session(for: windowA) === controllerA.session)
        XCTAssertTrue(store.session(for: a.id) === controllerA.session)
        await controllerA.session.unlock(password: "testpassword123")
        let rootA = try XCTUnwrap(controllerA.session.rootGroup)
        try controllerA.session.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: rootA),
            draft: EntryDraftPayload(title: "Unsaved in A")))

        coordinator.open(b)
        let controllerB = try XCTUnwrap(coordinator.databaseWindows[b.id])
        XCTAssertTrue(presenter.shown.last === controllerB.window)
        XCTAssertEqual(controllerA.session.state, .unlocked, "Opening B never locks A")
        XCTAssertTrue(controllerA.session.isDirty)
        XCTAssertTrue(store.session(for: a.id) === controllerA.session)
        XCTAssertFalse(controllerA.session === controllerB.session)

        let shownBefore = presenter.shown.count
        coordinator.open(a)
        XCTAssertTrue(coordinator.databaseWindows[a.id] === controllerA)
        XCTAssertEqual(coordinator.databaseWindows.count, 2)
        XCTAssertEqual(presenter.shown.count, shownBefore + 1)
        XCTAssertTrue(presenter.shown.last === windowA)

        XCTAssertEqual(coordinator.launcher.openAction(for: a), .front)
        XCTAssertEqual(coordinator.launcher.openAction(for: c), .open)
        coordinator.launcher.selectedDatabaseID = c.id
        coordinator.launcher.openSelection()
        XCTAssertNotNil(coordinator.databaseWindows[c.id])
        XCTAssertEqual(coordinator.databaseWindows.count, 3)
    }

    func testOpenAndNewDatabaseStayAvailableWhileAnotherDatabaseSaves() async throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        start()
        coordinator.open(references[0])
        let session = try XCTUnwrap(coordinator.databaseWindows[references[0].id]?.session)
        await session.unlock(password: "testpassword123")
        let root = try XCTUnwrap(session.rootGroup)
        try session.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: root),
            draft: EntryDraftPayload(title: "Saving")))
        let save = Task { await session.saveHandlingError() }
        await Task.yield()
        for selector in ["openDatabase:", "newDatabase:"] {
            XCTAssertTrue(delegate.validateMenuItem(item(selector)), selector)
        }
        XCTAssertEqual(coordinator.launcher.openAction(for: references[1]), .open)
        coordinator.launcher.open(references[1])
        XCTAssertNotNil(coordinator.databaseWindows[references[1].id])
        await save.value
    }

    // MARK: - Closing

    func testCommittedCloseRetiresOnlyItsSessionAndReleasesItsController() async throws {
        start()
        coordinator.open(references[0])
        coordinator.open(references[1])
        weak var released: DatabaseWindowController?
        let sessionA = try XCTUnwrap(coordinator.databaseWindows[references[0].id]?.session)
        let sessionB = try XCTUnwrap(coordinator.databaseWindows[references[1].id]?.session)
        await sessionA.unlock(password: "testpassword123")
        await sessionB.unlock(password: "testpassword123")
        let windowA = try XCTUnwrap(coordinator.databaseWindows[references[0].id]?.window)
        center.post(name: NSWindow.didBecomeKeyNotification, object: windowA)
        XCTAssertEqual(quickAccess.focusedDatabaseID, references[0].id)
        autoreleasepool {
            released = coordinator.databaseWindows[references[0].id]
            windowA.close()
        }
        XCTAssertNil(coordinator.databaseWindows[references[0].id])
        XCTAssertNil(released, "The closed window's controller is released")
        XCTAssertNil(store.session(for: references[0].id))
        XCTAssertEqual(sessionA.state, .locked)
        XCTAssertNil(registry.registration(for: windowA))
        XCTAssertNil(quickAccess.focusedDatabaseID)
        XCTAssertTrue(store.session(for: references[1].id) === sessionB)
        XCTAssertEqual(sessionB.state, .unlocked)
        XCTAssertNotNil(coordinator.databaseWindows[references[1].id])
    }

    func testCancelledCloseKeepsTheWindowAndItsUnsavedSession() async throws {
        start()
        coordinator.open(references[0])
        let controller = try XCTUnwrap(coordinator.databaseWindows[references[0].id])
        let window = try XCTUnwrap(controller.window)
        let session = controller.session
        await session.unlock(password: "testpassword123")
        let root = try XCTUnwrap(session.rootGroup)
        try session.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: root),
            draft: EntryDraftPayload(title: "Keep me")))
        let prompts = Counter()
        let closes = Counter()
        let closeGuard = MacWindowCloseGuard(registry: registry, prompt: { _, _ in
            prompts.value += 1
            return .cancel
        }, closeWindow: { _ in closes.value += 1 }, notificationCenter: center)
        defer { closeGuard.stop() }

        XCTAssertFalse(closeGuard.windowShouldClose(window))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(prompts.value, 1)
        XCTAssertEqual(closes.value, 0)
        XCTAssertTrue(coordinator.databaseWindows[references[0].id] === controller)
        XCTAssertTrue(store.session(for: references[0].id) === session)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(registry.session(for: window) === session)

        controller.closeDatabase(nil)
        XCTAssertTrue(presenter.closeRequests.isEmpty, "Not the command target: Close Database does nothing")
        focus.key = window
        controller.closeDatabase(nil)
        XCTAssertTrue(presenter.closeRequests.last === window, "Close Database goes through the guarded close")
        XCTAssertNotNil(coordinator.databaseWindows[references[0].id])
    }

    func testSessionRetiredElsewhereTakesItsWindowWithIt() async throws {
        start()
        coordinator.open(references[0])
        coordinator.open(references[1])
        list.removeDatabase(references[0])
        await Task { @MainActor in }.value
        XCTAssertNil(coordinator.databaseWindows[references[0].id])
        XCTAssertNotNil(coordinator.databaseWindows[references[1].id])
    }

    // MARK: - Commands

    func testCommandTargetFollowsKeyAndMainDatabaseWindowsAndNeverTheLauncher() async throws {
        start()
        coordinator.open(references[0])
        coordinator.open(references[1])
        let a = try XCTUnwrap(coordinator.databaseWindows[references[0].id])
        let b = try XCTUnwrap(coordinator.databaseWindows[references[1].id])
        await a.session.unlock(password: "testpassword123")
        await b.session.unlock(password: "testpassword123")
        let newEntry = item("newEntry:")

        focus.key = a.window
        focus.main = a.window
        XCTAssertTrue(coordinator.commandTarget() === a)
        XCTAssertTrue(a.validateMenuItem(newEntry))
        XCTAssertFalse(b.validateMenuItem(newEntry))

        let sheet = CoordinatorSheetWindow()
        sheet.owner = b.window
        focus.key = sheet
        XCTAssertTrue(coordinator.commandTarget() === b)

        focus.key = NSWindow()
        focus.main = b.window
        XCTAssertTrue(coordinator.commandTarget() === b, "Settings key: the main database window")

        focus.key = coordinator.databasesWindow
        XCTAssertNil(coordinator.commandTarget(), "The Databases window disables database commands")
        XCTAssertFalse(a.validateMenuItem(newEntry))
        XCTAssertFalse(b.validateMenuItem(newEntry))
        b.lockDatabase(nil)
        XCTAssertEqual(b.session.state, .unlocked)
    }

    // MARK: - Routing

    func testLaunchPresentationQueuesOpensUntilItIsDismissed() throws {
        let url = fileURLs[1]
        coordinator.handleOpenURL(url)
        XCTAssertTrue(coordinator.databaseWindows.isEmpty, "URLs wait for startup")
        coordinator.start(transitionNotice: true, whatsNewRelease: nil, automaticOpenID: references[0].id)
        XCTAssertEqual(coordinator.routing.launchPresentation, .transitionNotice)
        XCTAssertTrue(presenter.shown.contains { $0 === coordinator.databasesWindow })
        XCTAssertTrue(coordinator.databaseWindows.isEmpty, "Nothing opens behind a launch presentation")
        coordinator.finishLaunchPresentation(.transitionNotice)
        XCTAssertNil(coordinator.routing.launchPresentation)
        XCTAssertNotNil(coordinator.databaseWindows[references[1].id])
        XCTAssertNil(coordinator.databaseWindows[references[0].id], "The notice suppresses the automatic open")
        coordinator.handleOpenURL(url)
        XCTAssertEqual(coordinator.databaseWindows.count, 1, "A repeated URL fronts the open window")
        XCTAssertTrue(presenter.shown.last === coordinator.databaseWindows[references[1].id]?.window)
    }

    func testAutomaticOpenShowsOnlyTheDatabaseAndDockReopenShowsDatabases() {
        coordinator.start(transitionNotice: false, whatsNewRelease: nil, automaticOpenID: references[0].id)
        XCTAssertNotNil(coordinator.databaseWindows[references[0].id])
        XCTAssertNil(coordinator.databasesWindow)
        coordinator.dockReopen(hasVisibleWindows: true)
        XCTAssertNil(coordinator.databasesWindow)
        coordinator.dockReopen(hasVisibleWindows: false)
        XCTAssertTrue(presenter.shown.last === coordinator.databasesWindow)
    }

    func testEnrollmentBindsToTheTargetedWindowOrAsksForADestination() async throws {
        start()
        coordinator.open(references[0])
        let a = try XCTUnwrap(coordinator.databaseWindows[references[0].id])
        await a.session.unlock(password: "testpassword123")
        let link = try XCTUnwrap(URL(string: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example"))

        focus.key = a.window
        coordinator.handleOpenURL(link)
        XCTAssertEqual(coordinator.enrollment.destinationDatabaseID, references[0].id)
        XCTAssertNotNil(coordinator.enrollment.presentedEnrollment)
        XCTAssertFalse(coordinator.launcherHostsEnrollmentAlert)
        focus.key = nil
        XCTAssertEqual(coordinator.enrollment.destinationDatabaseID, references[0].id, "Focus never retargets")

        focus.key = coordinator.databasesWindow
        coordinator.handleOpenURL(link)
        XCTAssertNil(coordinator.enrollment.destinationDatabaseID)
        XCTAssertNil(coordinator.enrollment.enrollmentAlert)
        XCTAssertTrue(coordinator.launcher.isChoosingEnrollmentDestination)
        coordinator.launcher.chooseEnrollmentDestination(references[1].id)
        XCTAssertFalse(coordinator.launcher.isChoosingEnrollmentDestination)
        XCTAssertNotNil(coordinator.databaseWindows[references[1].id])
        XCTAssertEqual(coordinator.enrollment.destinationDatabaseID, references[1].id)
        XCTAssertNil(coordinator.enrollment.presentedEnrollment, "A locked destination waits for unlock")

        coordinator.databaseWindows[references[1].id]?.window?.close()
        XCTAssertNil(coordinator.enrollment.destinationDatabaseID, "Closing the destination discards the link")

        let invalid = try XCTUnwrap(URL(string: "otpauth://totp/Test"))
        coordinator.handleOpenURL(invalid)
        XCTAssertEqual(coordinator.enrollment.enrollmentAlert, .invalidLink)
        XCTAssertTrue(coordinator.launcherHostsEnrollmentAlert)
    }

    // MARK: - Helpers

    private func start() {
        coordinator.start(transitionNotice: false, whatsNewRelease: nil, automaticOpenID: nil)
    }

    private func item(_ selector: String) -> NSMenuItem {
        NSMenuItem(title: "", action: NSSelectorFromString(selector), keyEquivalent: "")
    }

    private func temporaryCopyOfFixture(named name: String) throws -> URL {
        let source = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

@MainActor
private final class CoordinatorSheetWindow: NSWindow {
    weak var owner: NSWindow?
    override var sheetParent: NSWindow? { owner }
}

@MainActor
private final class QuickSearchPresenterStub: MacQuickSearchPanelPresenting {
    var isPanelVisible = false
    var onToggleRequested: (() -> Void)?
    func setStatusItemVisible(_ visible: Bool) {}
    func showPanel() {}
    func hidePanel(restoringPreviousApp: Bool) {}
}

@MainActor
private final class HotKeyStub: MacHotKeyRegistering {
    var onPressed: (() -> Void)?
    func register(_ hotKey: SettingsService.MacHotKey) -> Bool { true }
    func unregister() {}
}
#endif
