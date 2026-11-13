#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacMainMenuTests: XCTestCase {
    func testCompleteMenuContractAndActionOwners() throws {
        let application = NSApplication.shared
        let oldMain = application.mainMenu
        let oldServices = application.servicesMenu
        let oldWindows = application.windowsMenu
        let oldHelp = application.helpMenu
        defer {
            application.mainMenu = oldMain
            application.servicesMenu = oldServices
            application.windowsMenu = oldWindows
            application.helpMenu = oldHelp
        }
        let menu = MainMenu.build()
        XCTAssertEqual(menu.items.map(\.title), ["KeeForge", "File", "Edit", "View", "Database", "Window", "Help"].map(localized))
        let command: NSEvent.ModifierFlags = .command
        let shift: NSEvent.ModifierFlags = [.command, .shift]
        let option: NSEvent.ModifierFlags = [.command, .option]
        let control: NSEvent.ModifierFlags = [.command, .control]
        typealias Item = (String, String, NSEvent.ModifierFlags, String)
        var app: [Item] = [("About KeeForge", "", [], "showAboutPanel:")]
        #if KEEFORGE_DIRECT_DOWNLOAD
        app.append(("Check for Updates…", "", [], "checkForUpdates:"))
        #endif
        app += [
            ("Settings…", ",", command, "showSettings:"),
            ("Hide KeeForge", "h", command, "hide:"),
            ("Hide Others", "h", option, "hideOtherApplications:"),
            ("Show All", "", [], "unhideAllApplications:"),
            ("Quit KeeForge", "q", command, "terminate:"),
        ]
        let expected: [[Item]] = [app, [
            ("New Database…", "", [], "newDatabase:"),
            ("New Entry", "n", command, "newEntry:"),
            ("New Group", "n", shift, "newGroup:"),
            ("Open Database…", "o", command, "openDatabase:"),
            ("Close Window", "w", command, "performClose:"),
            ("Save", "s", command, "saveDatabase:"),
            ("Close Database", "w", shift, "closeDatabase:"),
        ], [
            ("Undo", "z", command, "undo:"), ("Redo", "z", shift, "redo:"),
            ("Cut", "x", command, "cut:"), ("Copy", "c", command, "copy:"),
            ("Paste", "v", command, "paste:"), ("Select All", "a", command, "selectAll:"),
            ("Copy Username", "b", shift, "copyUsername:"),
            ("Copy Password", "c", shift, "copyPassword:"),
            ("Copy URL", "u", shift, "copyURL:"),
            ("Copy Verification Code", "t", shift, "copyVerificationCode:"),
            ("Edit Entry", "e", command, "editEntry:"),
            ("Delete", "\u{8}", command, "deleteSelection:"),
            ("Find", "f", command, "findEntry:"),
        ], [
            ("Show Toolbar", "t", option, "toggleToolbarShown:"),
            ("Customize Toolbar…", "", [], "runToolbarCustomizationPalette:"),
            ("Show Sidebar", "s", control, "toggleSidebar:"),
            ("Enter Full Screen", "f", control, "toggleFullScreen:"),
        ], [("Lock", "l", command, "lockDatabase:")], [
            ("Minimize", "m", command, "performMiniaturize:"),
            ("Zoom", "", [], "performZoom:"),
            ("Bring All to Front", "", [], "arrangeInFront:"),
        ], [("KeeForge Help", "", [], "showHelp:"), ("Report a Bug", "", [], "reportBug:")]]
        let databaseActions: Set<String> = ["newEntry:", "newGroup:", "saveDatabase:", "closeDatabase:", "copyUsername:", "copyPassword:", "copyURL:", "copyVerificationCode:", "editEntry:", "deleteSelection:", "findEntry:", "lockDatabase:"]
        let appActions: Set<String> = ["showAboutPanel:", "showSettings:", "newDatabase:", "openDatabase:", "showHelp:", "reportBug:", "checkForUpdates:"]
        for (top, contracts) in zip(menu.items, expected) {
            let submenu = try XCTUnwrap(top.submenu)
            let items = submenu.items.filter { $0.action != nil && $0.submenu == nil }
            XCTAssertEqual(items.count, contracts.count, top.title)
            for (item, contract) in zip(items, contracts) {
                XCTAssertEqual(item.title, localized(contract.0))
                XCTAssertEqual(item.keyEquivalent, contract.1, item.title)
                XCTAssertEqual(item.keyEquivalentModifierMask, contract.2, item.title)
                XCTAssertEqual(item.action.map(NSStringFromSelector), contract.3, item.title)
                XCTAssertNil(item.target)
                let selector = NSSelectorFromString(contract.3)
                if databaseActions.contains(contract.3) {
                    XCTAssertTrue(MainWindowController.instancesRespond(to: selector), contract.3)
                    XCTAssertFalse(AppDelegate.instancesRespond(to: selector), contract.3)
                } else if appActions.contains(contract.3) {
                    XCTAssertTrue(AppDelegate.instancesRespond(to: selector), contract.3)
                    XCTAssertFalse(MainWindowController.instancesRespond(to: selector), contract.3)
                }
            }
        }
        MainMenu.install(menu)
        XCTAssertTrue(application.windowsMenu === menu.items[5].submenu)
        XCTAssertTrue(application.helpMenu === menu.items[6].submenu)
        XCTAssertEqual(application.servicesMenu?.title, localized("Services"))
    }

    func testAppKitHostWindowAndSupplementalCommandTarget() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let window = try XCTUnwrap(controller.window)
        XCTAssertNotNil(window.contentViewController)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 900, height: 620))
        XCTAssertEqual(window.frameAutosaveName, "main-AppWindow-1")
        XCTAssertEqual(window.identifier?.rawValue, "main")
        XCTAssertTrue(window.canBecomeMain, "The retained window must count as a host window")
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        for selector in ["newEntry:", "newGroup:", "saveDatabase:", "closeDatabase:", "copyUsername:", "copyPassword:", "copyURL:", "copyVerificationCode:", "editEntry:", "deleteSelection:", "findEntry:", "lockDatabase:"] {
            XCTAssertTrue(delegate.supplementalTarget(forAction: NSSelectorFromString(selector), sender: nil) as? MainWindowController === controller, selector)
        }
    }

    func testIncomingURLsWaitForInitialRoutingAndDrainOnceInOrder() throws {
        let routing = AppRoutingCoordinator()
        let controller = MainWindowController(listViewModel: DatabaseListViewModel(), sessionStore: DatabaseSessionStore(),
            routing: routing, quickAccess: MacQuickAccessController(), sshAgent: MacSSHAgentController())
        let unsupported = try XCTUnwrap(URL(string: "otpauth://hotp/Test?secret=JBSWY3DPEHPK3PXP&counter=0"))
        let invalid = try XCTUnwrap(URL(string: "otpauth://totp/Test"))
        controller.handleOpenURL(unsupported)
        controller.handleOpenURL(invalid)
        XCTAssertNil(routing.enrollmentAlert)
        XCTAssertFalse(routing.didResolveInitialRoute)
        _ = routing.resolveInitialRoute(hasActiveSession: false, showsTransitionNotice: false, release: nil, autoOpenReference: nil)
        controller.rootDidBecomeReady()
        XCTAssertEqual(routing.enrollmentAlert, .invalidLink)
        routing.enrollmentAlert = nil
        controller.rootDidBecomeReady()
        XCTAssertNil(routing.enrollmentAlert)
        controller.handleOpenURL(unsupported)
        XCTAssertEqual(routing.enrollmentAlert, .unsupportedLink)
        XCTAssertNil(controller.window)
    }

    func testValidationTracksSessionSelectionWritabilityAndAuthentication() async throws {
        let store = DatabaseSessionStore()
        let action = EntrySecretAction()
        let controller = MainWindowController(listViewModel: DatabaseListViewModel(), sessionStore: store,
            routing: AppRoutingCoordinator(), quickAccess: MacQuickAccessController(), sshAgent: MacSSHAgentController(),
            passwordCopyAction: action)
        assertValidation(controller, action: action)
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        for readOnly in [false, true] {
            var reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
            reference.isReadOnly = readOnly
            let session = store.adopt(DatabaseViewModel(databaseReference: reference, quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false }))
            store.activeSessionID = reference.id
            XCTAssertTrue(controller.session === session)
            assertValidation(controller, action: action)
            await session.unlock(password: "testpassword123")
            XCTAssertEqual(session.state, .unlocked)
            session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first(where: { $0.hasPassword })).id
            assertValidation(controller, action: action)
            let task = try XCTUnwrap(action.perform(authenticate: {}, isCurrent: { true }, disclose: {}))
            XCTAssertFalse(controller.validateMenuItem(item("copyPassword:")))
            await task.value
            XCTAssertTrue(controller.validateMenuItem(item("copyPassword:")))
            if !readOnly {
                try session.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: try XCTUnwrap(session.rootGroup)), draft: EntryDraftPayload(title: "Menu validation")))
                XCTAssertTrue(controller.validateMenuItem(item("saveDatabase:")))
                let entryID = try XCTUnwrap(session.workspace.selectedEntryID)
                try session.applyEntryEdit(.deleteEntry(entryID: entryID, sendToRecycleBin: true))
                session.workspace.selectedEntryID = entryID
                XCTAssertTrue(session.isEntryInRecycleBin(entryID: entryID))
                assertValidation(controller, action: action)
                let delete = item("deleteSelection:")
                XCTAssertTrue(controller.validateMenuItem(delete))
                XCTAssertEqual(delete.title, localized("Delete Permanently"))
            }
            store.retire(reference.id, force: true)
            assertValidation(controller, action: action)
        }
        XCTAssertNil(controller.window, "Headless menu validation must not create a window")
    }

    func testContentAndTitleFollowUnlockLockAndSessionReplacementWithoutRemountingRoot() async throws {
        let store = DatabaseSessionStore()
        let routing = AppRoutingCoordinator()
        _ = routing.resolveInitialRoute(hasActiveSession: false, showsTransitionNotice: false, release: nil, autoOpenReference: nil)
        let controller = MainWindowController(listViewModel: DatabaseListViewModel(), sessionStore: store,
            routing: routing, quickAccess: MacQuickAccessController(), sshAgent: MacSSHAgentController())
        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentViewController)
        defer { window.close() }
        XCTAssertNil(controller.workspaceSplitViewController)
        XCTAssertEqual(window.title, "KeeForge")
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        for _ in 0..<2 {
            let reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
            let session = store.adopt(DatabaseViewModel(databaseReference: reference,
                quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false }))
            store.activeSessionID = reference.id
            await session.unlock(password: "testpassword123")
            await Task { @MainActor in }.value
            let split = try XCTUnwrap(controller.workspaceSplitViewController)
            XCTAssertTrue(split.session === session)
            XCTAssertEqual(window.title, session.databaseDisplayName)
            let group = try XCTUnwrap(session.group(withID: try XCTUnwrap(session.visibleRootGroupID)))
            XCTAssertEqual(window.subtitle, group.name)
            session.searchText = "GitHub"
            await Task { @MainActor in }.value
            XCTAssertEqual(window.subtitle, localized("Search"))
            XCTAssertTrue(controller.workspaceSplitViewController === split)
            session.workspace.selectedTag = "Work"
            session.searchText = ""
            await Task { @MainActor in }.value
            XCTAssertEqual(window.subtitle, "Work")
            XCTAssertEqual(window.title, session.databaseDisplayName)
            XCTAssertTrue(window.contentViewController === root)
            XCTAssertTrue(controller.validateMenuItem(item("toggleSidebar:")))
            split.splitViewItems[0].isCollapsed = false
            controller.toggleSidebar(nil)
            XCTAssertTrue(split.splitViewItems[0].isCollapsed)
            session.lock()
            await Task { @MainActor in }.value
            XCTAssertNil(controller.workspaceSplitViewController)
            XCTAssertEqual(window.title, "KeeForge")
            XCTAssertEqual(window.subtitle, "")
            XCTAssertTrue(window.contentViewController === root)
            XCTAssertFalse(controller.validateMenuItem(item("toggleSidebar:")))
            store.retire(reference.id, force: true)
        }
    }

    private func assertValidation(_ controller: MainWindowController, action: EntrySecretAction,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let commands = DatabaseCommands(session: controller.session, passwordCopyAction: action)
        let cases = [
            ("newEntry:", commands.canNewEntry), ("newGroup:", commands.canNewGroup),
            ("saveDatabase:", commands.canSave), ("closeDatabase:", commands.canCloseDatabase),
            ("copyUsername:", commands.canCopyUsername), ("copyPassword:", commands.canCopyPassword),
            ("copyURL:", commands.canCopyURL), ("copyVerificationCode:", commands.canCopyVerificationCode),
            ("editEntry:", commands.canEditEntry), ("deleteSelection:", commands.canDelete),
            ("findEntry:", commands.canFind), ("lockDatabase:", commands.canLock),
        ]
        for (selector, expected) in cases {
            let menuItem = item(selector)
            XCTAssertEqual(controller.validateMenuItem(menuItem), expected, selector, file: file, line: line)
            if selector == "deleteSelection:" {
                XCTAssertEqual(menuItem.title, localized(commands.deletesPermanently ? "Delete Permanently" : "Delete"), file: file, line: line)
            }
        }
    }

    private func item(_ selector: String) -> NSMenuItem {
        NSMenuItem(title: "", action: NSSelectorFromString(selector), keyEquivalent: "")
    }

    private func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}
#endif
