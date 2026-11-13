#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

/// Windows are constructed but never ordered front, and `persistsLayout: false`
/// keeps frames and split geometry out of the host app's defaults.
@MainActor
final class DatabaseWindowControllerTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        try await super.tearDown()
    }

    func testWindowIdentityTitleAndPerDatabaseLayoutNames() throws {
        let session = try makeSession()
        let id = session.databaseReference.id
        let persisted = DatabaseWindowController(session: session, windowRegistry: registry(), enrollment: TOTPEnrollmentCoordinator())
        XCTAssertEqual(persisted.splitAutosaveName, MacWindowRestorationStore.splitViewAutosaveName(for: id))
        XCTAssertEqual(persisted.frameAutosaveName, "database.\(id.uuidString)")
        XCTAssertNil(persisted.window, "Construction must not create a window")

        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false))
        let window = try XCTUnwrap(controller.window)
        XCTAssertNil(controller.splitAutosaveName)
        XCTAssertEqual(window.frameAutosaveName, "")
        XCTAssertEqual(window.identifier, DatabaseWindowController.windowIdentifier(for: id))
        XCTAssertEqual(window.identifier?.rawValue, "database.\(id.uuidString)")
        XCTAssertEqual(window.title, session.databaseDisplayName)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 900, height: 620))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(window.isRestorable)
    }

    func testTwoControllersStayIndependentThroughUnlockLockErrorEditAndTitle() async throws {
        let first = try makeSession()
        let second = try makeSession()
        let a = try load(DatabaseWindowController(session: first, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false))
        let b = try load(DatabaseWindowController(session: second, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false))
        let windowA = try XCTUnwrap(a.window)
        let windowB = try XCTUnwrap(b.window)
        let rootA = windowA.contentViewController
        let rootB = windowB.contentViewController

        await first.unlock(password: "testpassword123")
        await settle()
        XCTAssertTrue(a.workspaceSplitViewController?.session === first)
        XCTAssertTrue(windowA.toolbar === a.workspaceToolbar?.toolbar)
        XCTAssertNil(b.workspaceSplitViewController)
        XCTAssertNotEqual(windowB.toolbar?.identifier, MacWorkspaceToolbar.identifier)
        XCTAssertTrue(a.validateMenuItem(item("newEntry:")))
        XCTAssertFalse(b.validateMenuItem(item("newEntry:")))
        XCTAssertTrue(b.validateMenuItem(item("closeDatabase:")))

        await second.unlock(password: "wrong password")
        await settle()
        if case .error = second.state {} else { XCTFail("Expected an unlock error, got \(second.state)") }
        XCTAssertEqual(first.state, .unlocked)
        XCTAssertNotNil(a.workspaceSplitViewController)

        let root = try XCTUnwrap(first.rootGroup)
        try first.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: root),
            draft: EntryDraftPayload(title: "Window A")))
        XCTAssertTrue(a.validateMenuItem(item("saveDatabase:")))
        XCTAssertFalse(b.validateMenuItem(item("saveDatabase:")))

        var renamed = first.databaseReference
        renamed.nickname = "Window A Title"
        first.reconcileReference(renamed)
        await settle()
        XCTAssertEqual(windowA.title, "Window A Title")
        XCTAssertEqual(windowB.title, second.databaseDisplayName)
        let group = try XCTUnwrap(first.group(withID: try XCTUnwrap(first.visibleRootGroupID)))
        XCTAssertEqual(windowA.subtitle, group.name)
        XCTAssertEqual(windowB.subtitle, "")

        await second.unlock(password: "testpassword123")
        await settle()
        XCTAssertTrue(b.workspaceSplitViewController?.session === second)
        first.lockRequest(force: true)
        await settle()
        XCTAssertNil(a.workspaceSplitViewController)
        XCTAssertNil(a.workspaceToolbar)
        XCTAssertEqual(windowA.subtitle, "")
        XCTAssertEqual(windowA.title, "Window A Title", "A locked window keeps its database name")
        XCTAssertEqual(second.state, .unlocked)
        XCTAssertTrue(b.workspaceSplitViewController?.session === second)
        XCTAssertTrue(windowA.contentViewController === rootA, "Lock must not remount the root")
        XCTAssertTrue(windowB.contentViewController === rootB)
        second.lockRequest(force: true)
    }

    func testCommandsActOnlyWhileTheControllerIsTheCommandTarget() async throws {
        let session = try makeSession()
        let action = EntrySecretAction()
        let controller = DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false, passwordCopyAction: action)
        let isTarget = Box(true)
        controller.isCommandTarget = { isTarget.value }
        await session.unlock(password: "testpassword123")
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first(where: { $0.hasPassword })).id
        assertValidation(controller, session: session, action: action)
        let task = try XCTUnwrap(action.perform(authenticate: {}, isCurrent: { true }, disclose: {}))
        XCTAssertFalse(controller.validateMenuItem(item("copyPassword:")))
        await task.value
        XCTAssertTrue(controller.validateMenuItem(item("copyPassword:")))

        isTarget.value = false
        assertValidation(controller, session: nil, action: action)
        controller.lockDatabase(nil)
        XCTAssertEqual(session.state, .unlocked, "A command for another target must do nothing")
        isTarget.value = true
        controller.lockDatabase(nil)
        XCTAssertEqual(session.state, .locked)
        XCTAssertNil(controller.window, "Headless validation must not create a window")
    }

    func testCloseDatabaseAndReturnToDatabasesUseTheGuardedClose() throws {
        let session = try makeSession()
        let closeRequests = Box<[NSWindow]>([])
        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false, requestClose: { closeRequests.value.append($0) }))
        controller.closeDatabase(nil)
        XCTAssertEqual(closeRequests.value.count, 1)
        XCTAssertTrue(closeRequests.value.first === controller.window)
        controller.isCommandTarget = { false }
        controller.closeDatabase(nil)
        XCTAssertEqual(closeRequests.value.count, 1)
    }

    // MARK: - Helpers

    private func load(_ controller: DatabaseWindowController) throws -> DatabaseWindowController {
        controller.loadWindow()
        windows.append(try XCTUnwrap(controller.window))
        return controller
    }

    private func settle() async {
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
    }

    private func registry() -> MacDatabaseWindowRegistry {
        MacDatabaseWindowRegistry(sessionStore: DatabaseSessionStore())
    }

    private func makeSession() throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        return DatabaseViewModel(databaseReference: reference,
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
    }

    private func assertValidation(_ controller: DatabaseWindowController, session: DatabaseViewModel?,
                                  action: EntrySecretAction, file: StaticString = #filePath, line: UInt = #line) {
        let commands = DatabaseCommands(session: session, passwordCopyAction: action)
        let cases = [
            ("newEntry:", commands.canNewEntry), ("newGroup:", commands.canNewGroup),
            ("saveDatabase:", commands.canSave), ("closeDatabase:", commands.canCloseDatabase),
            ("copyUsername:", commands.canCopyUsername), ("copyPassword:", commands.canCopyPassword),
            ("copyURL:", commands.canCopyURL), ("copyVerificationCode:", commands.canCopyVerificationCode),
            ("editEntry:", commands.canEditEntry), ("deleteSelection:", commands.canDelete),
            ("findEntry:", commands.canFind), ("lockDatabase:", commands.canLock),
        ]
        for (selector, expected) in cases {
            XCTAssertEqual(controller.validateMenuItem(item(selector)), expected, selector, file: file, line: line)
        }
    }

    private func item(_ selector: String) -> NSMenuItem {
        NSMenuItem(title: "", action: NSSelectorFromString(selector), keyEquivalent: "")
    }
}

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
#endif
