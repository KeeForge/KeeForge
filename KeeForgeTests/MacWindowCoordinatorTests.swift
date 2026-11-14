#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

/// Window effects go through a recording presenter: nothing is shown,
/// `persistsLayout: false` keeps split state out of the host app's defaults, and
/// the restoration record lives in a throwaway defaults suite.
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

    /// Answers quit prompts in order; an unexpected extra prompt cancels.
    @MainActor
    private final class PromptScript {
        var choices: [MacWindowCloseGuard.Choice] = []
        var windows: [NSWindow?] = []
        func next(_ window: NSWindow?) -> MacWindowCloseGuard.Choice {
            windows.append(window)
            return choices.isEmpty ? .cancel : choices.removeFirst()
        }
    }

    private static let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)

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
    private var restorationSuite = ""
    private var restorationDefaults: UserDefaults!
    private var restoration: MacWindowRestorationStore!
    private var prompts: PromptScript!

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
        restorationSuite = "MacWindowCoordinatorTests.\(UUID())"
        restorationDefaults = try XCTUnwrap(UserDefaults(suiteName: restorationSuite))
        restoration = MacWindowRestorationStore(defaults: restorationDefaults)
        prompts = PromptScript()
    }

    override func tearDown() async throws {
        for controller in coordinator.databaseWindows.values {
            controller.session.lockRequest(force: true)
            controller.window?.close()
        }
        coordinator.databasesWindow?.close()
        coordinator = nil
        restorationDefaults.removePersistentDomain(forName: restorationSuite)
        restorationDefaults = nil
        restoration = nil
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    // MARK: - Opening

    func testOpeningSeveralDatabasesKeepsEachSessionAndADuplicateOpenFrontsTheSameWindow() async throws {
        start()
        XCTAssertTrue(presenter.shown.last === coordinator.databasesWindow, "No database window: Databases shows")
        XCTAssertEqual(coordinator.databasesWindow?.isExcludedFromWindowsMenu, true, "Window > Databases is its only Window-menu entry")
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

    // MARK: - Restoration

    func testColdLaunchRestoresTwoDatabasesLockedWithTheirFramesAndTheRecordedFront() throws {
        let (a, b) = (references[0].id, references[1].id)
        let frameA = CGRect(x: 100, y: 120, width: 1100, height: 760)
        let frameB = CGRect(x: 900, y: 300, width: 1200, height: 800)
        record([(a, frameA), (b, frameB)], front: a)
        makeRestoringCoordinator()
        start()

        let windowA = try XCTUnwrap(coordinator.databaseWindows[a]?.window)
        let windowB = try XCTUnwrap(coordinator.databaseWindows[b]?.window)
        XCTAssertEqual(coordinator.databaseWindows.count, 2)
        XCTAssertEqual(windowA.frame, frameA)
        XCTAssertEqual(windowB.frame, frameB)
        XCTAssertEqual(store.session(for: a)?.state, .locked)
        XCTAssertEqual(store.session(for: b)?.state, .locked)
        XCTAssertTrue(presenter.shown.last === windowA, "The recorded front comes back in front")
        XCTAssertNil(coordinator.databasesWindow, "Databases was closed and a database window survived")
        let recorded = try recordedTopology()
        XCTAssertEqual(Set(recorded.databaseWindows.map(\.databaseID)), [a, b])
        XCTAssertEqual(recorded.frontmostDatabaseID, a)
        XCTAssertEqual(recorded.databaseWindows.first { $0.databaseID == b }?.frame, frameB)
        XCTAssertFalse(recorded.databasesWindowOpen)
    }

    func testRestoredWindowsAdmitNoAutomaticUnlockUntilTheUserTurnsToThem() throws {
        let (a, b) = (references[0].id, references[1].id)
        record([(a, frame(0)), (b, frame(1))], front: b)
        makeRestoringCoordinator()
        start()
        let controllerA = try XCTUnwrap(coordinator.databaseWindows[a])
        let controllerB = try XCTUnwrap(coordinator.databaseWindows[b])
        for controller in [controllerA, controllerB] {
            XCTAssertEqual(registry.registration(for: controller.window)?.isRestoring, true)
            XCTAssertFalse(registry.admitsAutomaticUnlock(for: controller.session, in: controller.window))
        }
        center.post(name: NSWindow.didBecomeKeyNotification, object: controllerB.window)
        XCTAssertFalse(registry.admitsAutomaticUnlock(for: controllerB.session, in: controllerB.window),
            "Becoming key during launch is not the user turning to the window")

        coordinator.noteDeliberateFocus(a)
        XCTAssertTrue(registry.admitsAutomaticUnlock(for: controllerA.session, in: controllerA.window))
        XCTAssertFalse(registry.admitsAutomaticUnlock(for: controllerB.session, in: controllerB.window))
        coordinator.launcher.open(references[1])
        XCTAssertTrue(registry.admitsAutomaticUnlock(for: controllerB.session, in: controllerB.window),
            "Opening it again from Databases is deliberate")
        XCTAssertEqual(controllerA.session.state, .locked)
        XCTAssertEqual(controllerB.session.state, .locked)

        coordinator.open(references[2])
        let opened = try XCTUnwrap(coordinator.databaseWindows[references[2].id])
        XCTAssertEqual(registry.registration(for: opened.window)?.isRestoring, false, "Only restored windows wait")
    }

    func testQueuedURLForARestoredDatabaseFrontsItAndMissingDatabasesAreSkipped() throws {
        let a = references[0].id
        let missing = UUID()
        record([(a, frame(0)), (missing, frame(1))], front: missing)
        makeRestoringCoordinator()
        coordinator.handleOpenURL(fileURLs[0])
        start(automaticOpenID: references[2].id)
        XCTAssertEqual(Array(coordinator.databaseWindows.keys), [a], "No second window and no Quick Launch")
        let window = try XCTUnwrap(coordinator.databaseWindows[a]?.window)
        XCTAssertTrue(presenter.shown.last === window)
        XCTAssertEqual(store.session(for: a)?.state, .locked)
        XCTAssertEqual(try recordedTopology().databaseWindows.map(\.databaseID), [a])
    }

    func testNothingSurvivingShowsDatabasesAndQuickLaunchOnlyRunsWithoutRestoredWindows() throws {
        record([(UUID(), frame(0))], launcher: false, front: nil)
        makeRestoringCoordinator()
        start()
        XCTAssertTrue(coordinator.databaseWindows.isEmpty)
        XCTAssertTrue(presenter.shown.last === coordinator.databasesWindow)
        XCTAssertEqual(try recordedTopology().databasesWindowOpen, true)
    }

    func testQuickLaunchOpensWhenNothingIsRestored() throws {
        record([(UUID(), frame(0))], front: nil)
        makeRestoringCoordinator()
        start(automaticOpenID: references[1].id)
        XCTAssertEqual(Array(coordinator.databaseWindows.keys), [references[1].id])
        XCTAssertNil(coordinator.databasesWindow, "Quick Launch shows only the database")
        XCTAssertEqual(registry.registration(for: coordinator.databaseWindows[references[1].id]?.window)?.isRestoring, false)
    }

    func testQuickLaunchYieldsToARestoredWindow() throws {
        record([(references[0].id, frame(0))], front: references[0].id)
        makeRestoringCoordinator()
        start(automaticOpenID: references[1].id)
        XCTAssertEqual(Array(coordinator.databaseWindows.keys), [references[0].id])
    }

    func testLaunchPresentationDelaysRestorationAndNeverOverwritesTheRecord() throws {
        let a = references[0].id
        record([(a, frame(0))], front: a)
        let saved = restorationDefaults.data(forKey: MacWindowRestorationStore.storageKey)
        makeRestoringCoordinator()
        coordinator.start(transitionNotice: false, whatsNewRelease: WhatsNewRelease(version: "1.0", features: []), automaticOpenID: nil)
        XCTAssertEqual(coordinator.routing.launchPresentation, .whatsNew)
        XCTAssertTrue(coordinator.databaseWindows.isEmpty, "Nothing is restored behind a launch presentation")
        coordinator.databasesWindow?.close()
        coordinator.showDatabasesWindow()
        XCTAssertEqual(restorationDefaults.data(forKey: MacWindowRestorationStore.storageKey), saved)
        coordinator.finishLaunchPresentation(.whatsNew)
        XCTAssertNotNil(coordinator.databaseWindows[a])
        XCTAssertEqual(store.session(for: a)?.state, .locked)
        XCTAssertTrue(try recordedTopology().databasesWindowOpen)
    }

    func testRecordingFollowsOpenFrontChangeMoveResizeMinimizeAndCommittedClose() throws {
        makeRestoringCoordinator()
        start()
        XCTAssertTrue(try recordedTopology().databasesWindowOpen)
        coordinator.open(references[0])
        XCTAssertEqual(try recordedTopology().databaseWindows.map(\.databaseID), [references[0].id])
        coordinator.open(references[1])
        var recorded = try recordedTopology()
        XCTAssertEqual(recorded.databaseWindows.map(\.databaseID), [references[0].id, references[1].id])
        XCTAssertEqual(recorded.frontmostDatabaseID, references[1].id)

        let windowA = try XCTUnwrap(coordinator.databaseWindows[references[0].id]?.window)
        center.post(name: NSWindow.didBecomeKeyNotification, object: windowA)
        XCTAssertEqual(try recordedTopology().frontmostDatabaseID, references[0].id)

        let moved = CGRect(x: 40, y: 60, width: 1300, height: 820)
        windowA.setFrame(moved, display: false)
        center.post(name: NSWindow.didMoveNotification, object: windowA)
        XCTAssertEqual(try recordedTopology().databaseWindows.first { $0.databaseID == references[0].id }?.frame, moved)
        let resized = CGRect(x: 40, y: 60, width: 1400, height: 900)
        windowA.setFrame(resized, display: false)
        center.post(name: NSWindow.didEndLiveResizeNotification, object: windowA)
        XCTAssertEqual(try recordedTopology().databaseWindows.first { $0.databaseID == references[0].id }?.frame, resized)

        // Never ordered on screen, like a minimized window: it is still part of the topology.
        XCTAssertFalse(windowA.isVisible)
        center.post(name: NSWindow.didMiniaturizeNotification, object: windowA)
        XCTAssertEqual(try recordedTopology().databaseWindows.count, 2)

        coordinator.databaseWindows[references[1].id]?.window?.close()
        recorded = try recordedTopology()
        XCTAssertEqual(recorded.databaseWindows.map(\.databaseID), [references[0].id])
        XCTAssertEqual(recorded.frontmostDatabaseID, references[0].id)

        let launcherFrame = try XCTUnwrap(coordinator.databasesWindow?.frame)
        coordinator.databasesWindow?.close()
        XCTAssertFalse(try recordedTopology().databasesWindowOpen)
        windowA.close()
        recorded = try recordedTopology()
        XCTAssertTrue(recorded.databaseWindows.isEmpty, "Zero windows: the app keeps running with nothing to restore")
        XCTAssertNil(recorded.frontmostDatabaseID)
        XCTAssertFalse(recorded.databasesWindowOpen)
        XCTAssertEqual(recorded.databasesWindowFrame, launcherFrame)

        coordinator.dockReopen(hasVisibleWindows: false)
        XCTAssertTrue(presenter.shown.last === coordinator.databasesWindow)
        XCTAssertTrue(try recordedTopology().databasesWindowOpen)
    }

    func testRestoredDatabasesWindowUsesItsRecordedFrame() throws {
        let launcherFrame = CGRect(x: 300, y: 200, width: 700, height: 720)
        restoration.recordTopology(.init(databaseWindows: [], databasesWindowOpen: true,
            databasesWindowFrame: launcherFrame, frontmostDatabaseID: nil))
        makeRestoringCoordinator()
        start()
        XCTAssertEqual(coordinator.databasesWindow?.frame, launcherFrame)
    }

    func testRemovingADatabaseDropsItsSplitGeometryAndItsWindowRecord() async throws {
        makeRestoringCoordinator()
        start()
        coordinator.open(references[0])
        coordinator.open(references[1])
        let geometryKey = "NSSplitView Subview Frames \(MacWindowRestorationStore.splitViewAutosaveName(for: references[0].id))"
        let otherKey = "NSSplitView Subview Frames \(MacWindowRestorationStore.splitViewAutosaveName(for: references[1].id))"
        restorationDefaults.set(["geometry"], forKey: geometryKey)
        restorationDefaults.set(["other"], forKey: otherKey)
        list.removeDatabase(references[0])
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
        XCTAssertNil(restorationDefaults.object(forKey: geometryKey))
        XCTAssertEqual(restorationDefaults.stringArray(forKey: otherKey), ["other"])
        XCTAssertEqual(try recordedTopology().databaseWindows.map(\.databaseID), [references[1].id])
        XCTAssertNil(coordinator.databaseWindows[references[0].id])
    }

    // MARK: - Quit

    func testCleanQuitTerminatesNowAndKeepsThePreQuitTopology() throws {
        makeRestoringCoordinator()
        start()
        coordinator.open(references[0])
        coordinator.open(references[1])
        let before = try recordedTopology()
        XCTAssertEqual(coordinator.requestTermination { _ in XCTFail("No reply for an immediate quit") }, .terminateNow)
        for controller in coordinator.databaseWindows.values { controller.window?.close() }
        coordinator.databasesWindow?.close()
        XCTAssertEqual(try recordedTopology(), before, "Closes during termination never overwrite the record")
        XCTAssertTrue(prompts.windows.isEmpty)
    }

    func testCancelledQuitWithTwoDirtyWindowsKeepsEveryWindowSessionAndTheRecord() async throws {
        makeRestoringCoordinator()
        start()
        coordinator.open(references[0])
        coordinator.open(references[1])
        let a = try XCTUnwrap(coordinator.databaseWindows[references[0].id])
        let b = try XCTUnwrap(coordinator.databaseWindows[references[1].id])
        await a.session.unlock(password: "testpassword123")
        await b.session.unlock(password: "testpassword123")
        try makeDirty(a.session, title: "Unsaved in A")
        try makeDirty(b.session, title: "Unsaved in B")
        let before = try recordedTopology()
        prompts.choices = [.save, .cancel]

        let reply = try await terminate()
        XCTAssertEqual(reply, false)
        XCTAssertEqual(prompts.windows.count, 2)
        XCTAssertTrue(prompts.windows[0] === b.window, "The front window is asked first")
        XCTAssertTrue(prompts.windows[1] === a.window)
        for controller in [a, b] {
            XCTAssertTrue(coordinator.databaseWindows[controller.databaseID] === controller)
            XCTAssertTrue(store.session(for: controller.databaseID) === controller.session)
            XCTAssertEqual(controller.session.state, .unlocked)
            XCTAssertTrue(controller.session.isDirty, "Save on the first window waits for every answer")
        }
        let after = try recordedTopology()
        XCTAssertEqual(Set(after.databaseWindows.map(\.databaseID)), Set(before.databaseWindows.map(\.databaseID)))

        center.post(name: NSWindow.didBecomeKeyNotification, object: b.window)
        XCTAssertEqual(try recordedTopology().frontmostDatabaseID, b.databaseID, "Recording carries on after a cancelled quit")
    }

    func testSettledQuitSavesThenKeepsThePreQuitTopologyWhileWindowsClose() async throws {
        makeRestoringCoordinator()
        start()
        coordinator.open(references[0])
        coordinator.open(references[1])
        let a = try XCTUnwrap(coordinator.databaseWindows[references[0].id])
        let b = try XCTUnwrap(coordinator.databaseWindows[references[1].id])
        await a.session.unlock(password: "testpassword123")
        await b.session.unlock(password: "testpassword123")
        try makeDirty(a.session, title: "Saved on quit")
        try makeDirty(b.session, title: "Discarded on quit")
        prompts.choices = [.discard, .save]

        let reply = try await terminate()
        XCTAssertEqual(reply, true)
        XCTAssertFalse(a.session.isDirty, "Save wrote A")
        XCTAssertNil(a.session.saveError)
        let before = try recordedTopology()
        XCTAssertEqual(before.databaseWindows.map(\.databaseID), [references[1].id, references[0].id],
            "Each prompt fronted its window; the last one asked is in front")
        XCTAssertEqual(before.frontmostDatabaseID, references[0].id)

        for controller in [a, b] {
            controller.session.lockRequest(force: true)
            controller.window?.close()
        }
        coordinator.databasesWindow?.close()
        XCTAssertEqual(try recordedTopology(), before)
    }

    func testLaunchOptionsOnlyApplyUnderUITesting() {
        let plain = MacWindowLaunchOptions(arguments: ["KeeForge", MacWindowLaunchOptions.databaseWindowSizeArgument, "1440x900"])
        XCTAssertTrue(plain.restoresWindows)
        XCTAssertEqual(plain.databaseWindowContentSize, DatabaseWindow.defaultContentSize)
        let testing = MacWindowLaunchOptions(arguments: ["KeeForge", "-ui-testing", MacWindowLaunchOptions.databaseWindowSizeArgument, "1440x900"])
        XCTAssertFalse(testing.restoresWindows)
        XCTAssertEqual(testing.databaseWindowContentSize, NSSize(width: 1440, height: 900))
        for value in ["wide", "0x900", "1440", "1440x900x2", "infx900"] {
            let options = MacWindowLaunchOptions(arguments: ["-ui-testing", MacWindowLaunchOptions.databaseWindowSizeArgument, value])
            XCTAssertEqual(options.databaseWindowContentSize, DatabaseWindow.defaultContentSize, value)
        }
        XCTAssertEqual(MacWindowLaunchOptions(arguments: ["-ui-testing", MacWindowLaunchOptions.databaseWindowSizeArgument])
            .databaseWindowContentSize, DatabaseWindow.defaultContentSize)
    }

    func testUITestingStartsWithoutRestoredWindowsAndRecordsNothing() throws {
        record([(references[0].id, frame(0))], front: references[0].id)
        let saved = restorationDefaults.data(forKey: MacWindowRestorationStore.storageKey)
        makeRestoringCoordinator(restoresWindows: false, databaseWindowContentSize: NSSize(width: 1440, height: 900))
        start()
        XCTAssertTrue(coordinator.databaseWindows.isEmpty)
        coordinator.open(references[1])
        let window = try XCTUnwrap(coordinator.databaseWindows[references[1].id]?.window)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 1440, height: 900))
        XCTAssertEqual(restorationDefaults.data(forKey: MacWindowRestorationStore.storageKey), saved)
    }

    func testANewDatabaseWindowCascadesFromTheFrontmostOne() throws {
        start()
        coordinator.open(references[0])
        let first = try XCTUnwrap(coordinator.databaseWindows[references[0].id]?.window)
        let firstFrame = first.frame
        coordinator.open(references[1])
        let second = try XCTUnwrap(coordinator.databaseWindows[references[1].id]?.window)
        XCTAssertEqual(first.frame, firstFrame, "Opening another window never moves this one")
        XCTAssertEqual(second.frame.size, firstFrame.size)
        XCTAssertGreaterThan(second.frame.minX, firstFrame.minX)
        XCTAssertLessThan(second.frame.maxY, firstFrame.maxY)
    }

    func testSystemPresenterAsksTheCloseGuardWhileASheetIsAttached() throws {
        final class Delegate: NSObject, NSWindowDelegate {
            var allows = false
            var asked = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool {
                asked += 1
                return allows
            }
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = Delegate()
        window.delegate = delegate
        window.orderFront(nil)
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        defer {
            window.endSheet(sheet)
            window.close()
        }
        XCTAssertNotNil(window.attachedSheet)
        let presenter = MacSystemWindowPresenter()

        presenter.requestClose(window)
        XCTAssertEqual(delegate.asked, 1, "Close Database must reach the guard even though the close button is disabled")
        XCTAssertTrue(window.isVisible, "A held close keeps the window")

        delegate.allows = true
        presenter.requestClose(window)
        XCTAssertEqual(delegate.asked, 2)
        XCTAssertFalse(window.isVisible)
    }

    // MARK: - Helpers

    private func makeRestoringCoordinator(restoresWindows: Bool = true,
                                          databaseWindowContentSize: NSSize = DatabaseWindow.defaultContentSize) {
        let focus = self.focus!
        let prompts = self.prompts!
        let screen = Self.screen
        coordinator = MacWindowCoordinator(listViewModel: list, sessionStore: store, registry: registry,
            quickAccess: quickAccess, presenter: presenter,
            keyWindow: { focus.key }, mainWindow: { focus.main },
            persistsLayout: false, restorationStore: restoration, restoresWindows: restoresWindows,
            screenFrames: { [screen] }, terminationPrompt: { window, _ in prompts.next(window) },
            databaseWindowContentSize: databaseWindowContentSize,
            notificationCenter: center, deferredPresentationDelay: .zero)
    }

    private func record(_ windows: [(UUID, CGRect)], launcher: Bool = false, front: UUID?) {
        restoration.recordTopology(.init(databaseWindows: windows.map { .init(databaseID: $0.0, frame: $0.1) },
            databasesWindowOpen: launcher, databasesWindowFrame: CGRect(x: 200, y: 200, width: 640, height: 700),
            frontmostDatabaseID: front))
    }

    private func recordedTopology() throws -> MacWindowRestorationStore.Topology {
        let data = try XCTUnwrap(restorationDefaults.data(forKey: MacWindowRestorationStore.storageKey))
        return try JSONDecoder().decode(MacWindowRestorationStore.Topology.self, from: data)
    }

    private func frame(_ index: Int) -> CGRect {
        CGRect(x: 100 + CGFloat(index) * 200, y: 100, width: 1100, height: 760)
    }

    private func makeDirty(_ session: DatabaseViewModel, title: String) throws {
        let root = try XCTUnwrap(session.rootGroup)
        try session.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: root),
            draft: EntryDraftPayload(title: title)))
        XCTAssertTrue(session.isDirty)
    }

    private func terminate() async throws -> Bool? {
        let result = ReplyBox()
        let done = expectation(description: "termination reply")
        XCTAssertEqual(coordinator.requestTermination { settled in
            result.value = settled
            done.fulfill()
        }, .terminateLater)
        await fulfillment(of: [done], timeout: 30)
        return result.value
    }

    private func start(automaticOpenID: UUID?) {
        coordinator.start(transitionNotice: false, whatsNewRelease: nil, automaticOpenID: automaticOpenID)
    }

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
private final class ReplyBox {
    var value: Bool?
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
