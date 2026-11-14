#if os(macOS)
import AppKit
import CryptoKit
import XCTest
@testable import KeeForge

/// Windows are constructed but never ordered front, and `persistsLayout: false`
/// keeps split geometry out of the host app's defaults; frames are never autosaved.
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
        XCTAssertNil(window.restorationClass, "AppKit state restoration stays inert; the restoration store owns the frame")
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, DatabaseWindow.defaultContentSize)
        XCTAssertTrue(window.nextResponder === controller.attachmentPreview,
                      "Quick Look finds the window's preview controller in its responder chain")
        XCTAssertTrue(controller.attachmentPreview.nextResponder === controller)
    }

    func testClosingTheWindowEndsItsAttachmentPreviews() async throws {
        let entry = KPEntry(title: "Files", attachments: [KPAttachment(name: "report.txt", ref: 0)])
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry]), key: SymmetricKey(size: .bits256),
            binaryPool: BinaryPool(rawFields: [Data([0]) + Data("report".utf8)]), bundle: Bundle(for: Self.self)
        )
        defer { session.lockRequest(force: true) }
        let panel = RecordingPreviewPanel()
        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false, previewPanel: panel))
        session.workspace.selectedEntryID = entry.id
        await controller.attachmentPreview.preview(attachmentAt: 0, ofEntry: entry.id)?.value
        let url = try XCTUnwrap(controller.attachmentPreview.previews.previewURL)

        await settle()
        XCTAssertEqual(panel.shown, 1)
        let closes = panel.closed
        try XCTUnwrap(controller.window).close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(panel.closed, closes, "Closing the window closes its Quick Look panel")
        XCTAssertNil(controller.attachmentPreview.preview(attachmentAt: 0, ofEntry: entry.id),
                     "A closed window writes no more preview files")
    }

    func testInitialContentSizeIsChosenByTheCoordinatorAndNeverBelowTheMinimum() throws {
        let large = try load(DatabaseWindowController(session: try makeSession(), windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false, initialContentSize: NSSize(width: 1440, height: 900)))
        let largeWindow = try XCTUnwrap(large.window)
        XCTAssertEqual(largeWindow.contentRect(forFrameRect: largeWindow.frame).size, NSSize(width: 1440, height: 900))
        XCTAssertEqual(largeWindow.frameAutosaveName, "")
        let small = try load(DatabaseWindowController(session: try makeSession(), windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false, initialContentSize: NSSize(width: 300, height: 200)))
        let smallWindow = try XCTUnwrap(small.window)
        XCTAssertEqual(smallWindow.contentRect(forFrameRect: smallWindow.frame).size, DatabaseWindow.minimumContentSize)
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
        XCTAssertEqual(windowA.titleVisibility, .hidden, "The list header carries the title")
        XCTAssertEqual(windowB.titleVisibility, .visible, "The unlock screen keeps its title")
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
        first.workspace.selectedCollection = .verificationCodes
        await settle()
        XCTAssertEqual(windowA.subtitle, DatabaseCollection.verificationCodes.title)
        first.workspace.selectedGroupID = group.id
        await settle()
        XCTAssertEqual(windowA.subtitle, group.name)

        await second.unlock(password: "testpassword123")
        await settle()
        XCTAssertTrue(b.workspaceSplitViewController?.session === second)
        first.lockRequest(force: true)
        await settle()
        XCTAssertNil(a.workspaceSplitViewController)
        XCTAssertNil(a.workspaceToolbar)
        XCTAssertEqual(windowA.subtitle, "")
        XCTAssertEqual(windowA.titleVisibility, .visible)
        XCTAssertEqual(windowA.title, "Window A Title", "A locked window keeps its database name")
        XCTAssertEqual(second.state, .unlocked)
        XCTAssertTrue(b.workspaceSplitViewController?.session === second)
        XCTAssertTrue(windowA.contentViewController === rootA, "Lock must not remount the root")
        XCTAssertTrue(windowB.contentViewController === rootB)
        second.lockRequest(force: true)
    }

    func testTheUnlockScreenKeepsTheSafeAreaAndTheBridgedToolbarAcrossAnUnlock() async throws {
        let session = try makeSession()
        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false))
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentViewController)
        window.contentView?.layoutSubtreeIfNeeded()
        let lockedInsets = root.view.safeAreaInsets
        let lockedFrame = root.view.frame
        XCTAssertGreaterThan(lockedInsets.top, 0, "The unlock screen lays out below the titlebar")
        XCTAssertNotEqual(window.toolbar?.identifier, MacWorkspaceToolbar.identifier)

        await session.unlock(password: "testpassword123")
        await settle()
        XCTAssertTrue(window.toolbar === controller.workspaceToolbar?.toolbar)
        session.lockRequest(force: true)
        await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.contentViewController === root)
        XCTAssertEqual(root.view.safeAreaInsets.top, lockedInsets.top, "Locking restores the unlock screen's layout")
        XCTAssertEqual(root.view.frame, lockedFrame)
        XCTAssertNotEqual(window.toolbar?.identifier, MacWorkspaceToolbar.identifier, "The root's bridged toolbar returns")
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

    func testMenuBarCopiesTickTheCommandEntryOnlyForTheCommandTarget() async throws {
        let session = try makeSession()
        let controller = DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false)
        let isTarget = Box(false)
        controller.isCommandTarget = { isTarget.value }
        await session.unlock(password: "testpassword123")
        addTeardownBlock { @MainActor in
            session.lockRequest(force: true)
            ClipboardService.clearOwnedContents()
        }
        let entry = try XCTUnwrap(session.rootGroup?.allEntries.first { $0.username.isEmpty == false })
        session.workspace.selectedEntryID = entry.id
        let feedback = controller.workspacePresentation.copyFeedback

        controller.copyUsername(nil)
        XCTAssertNil(feedback.copied, "Another window's command copies nothing here")
        isTarget.value = true
        controller.copyUsername(nil)
        XCTAssertEqual(feedback.copied, MacCopyFeedback.Copied(entryID: entry.id, field: .username))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), entry.username)
    }

    func testShowInLargeTypeTakesTheGateThenShowsOverThisWindowUntilItCloses() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let key = SymmetricKey(size: .bits256)
        let entry = KPEntry(title: "GitHub", password: try EncryptedValue.encrypt("Vx7$", using: key))
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry]), key: key, secretAccess: harness.gate, bundle: Bundle(for: Self.self)
        )
        defer { session.lockRequest(force: true) }
        var presented: [NSPanel] = []
        let largeType = MacLargeTypePanelController(present: { presented.append($0) }, windowLookup: { _ in nil })
        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false, largeType: largeType))
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(controller.validateMenuItem(item("showInLargeType:")), "No entry selected")
        session.workspace.selectedEntryID = entry.id
        XCTAssertTrue(controller.validateMenuItem(item("showInLargeType:")))

        harness.promptSucceeds = false
        controller.showInLargeType(nil)
        await waitUntil { harness.promptReasons.count == 1 }
        await settle()
        XCTAssertNil(largeType.panel, "A declined prompt shows nothing")

        harness.promptSucceeds = true
        controller.showInLargeType(nil)
        await waitUntil { largeType.panel != nil }
        XCTAssertEqual(harness.promptReasons, [String(localized: "View password"), String(localized: "View password")])
        XCTAssertEqual(largeType.model, LargeTypeModel(title: "GitHub", fieldName: String(localized: "Password"), value: "Vx7$"))
        XCTAssertEqual(presented.count, 1)
        XCTAssertFalse(window.isVisible)
        let panel = try XCTUnwrap(largeType.panel)
        XCTAssertEqual(panel.frame.midX, window.frame.midX, accuracy: 0.5)

        window.close()
        XCTAssertNil(largeType.panel, "Closing the window closes its Large Type panel")
        XCTAssertNil(largeType.model)
    }

    /// View ▸ Hide Sidebar reads Show Sidebar while the sidebar is collapsed.
    func testTheInlineEditorFreezesMenuCommandsTakesFileSaveAndClosesOnLock() async throws {
        let entry = KPEntry(title: "Mail", username: "me")
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry]), bundle: Bundle(for: Self.self)
        )
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false))
        await settle()
        session.workspace.selectedEntryID = entry.id
        let presentation = controller.workspacePresentation
        presentation.beginEntryEdit(entryID: entry.id, in: session)
        let editor = try XCTUnwrap(presentation.entryEditor)
        for selector in ["newEntry:", "newGroup:", "editEntry:", "deleteSelection:", "findEntry:",
                         "duplicateSelectedEntry:", "moveSelectedEntries:", "showAllEntries:"] {
            XCTAssertFalse(controller.validateMenuItem(item(selector)), selector)
        }
        XCTAssertTrue(controller.validateMenuItem(item("lockDatabase:")))
        XCTAssertTrue(controller.validateMenuItem(item("copyUsername:")), "Copies act on the edited entry")
        XCTAssertFalse(controller.validateMenuItem(item("saveDatabase:")), "Nothing changed in the editor")

        editor.form.notes = "Saved with File ▸ Save"
        XCTAssertTrue(controller.validateMenuItem(item("saveDatabase:")))
        controller.saveDatabase(nil)
        for _ in 0..<200 where presentation.entryEditor != nil { await Task.yield() }
        XCTAssertNil(presentation.entryEditor)
        XCTAssertEqual(session.entry(withID: entry.id)?.notes, "Saved with File ▸ Save")
        XCTAssertFalse(session.isDirty, "The editor's save writes the database")
        XCTAssertTrue(controller.validateMenuItem(item("newEntry:")), "Closing releases the freeze")

        presentation.beginEntryEdit(entryID: entry.id, in: session)
        XCTAssertNotNil(presentation.entryEditor)
        session.lockRequest(manuallyTriggered: true)
        XCTAssertEqual(session.state, .locked, "An unchanged editor holds nothing back")
        await settle()
        XCTAssertNil(presentation.entryEditor, "The lock closes the window's editor")
    }

    func testSidebarMenuTitleFollowsTheCollapsedSidebar() throws {
        let controller = DatabaseWindowController(session: try makeSession(), windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false)
        let toggle = item("toggleSidebar:")
        _ = controller.validateMenuItem(toggle)
        XCTAssertEqual(toggle.title, String(localized: "Hide Sidebar"))
        controller.workspacePresentation.isSidebarCollapsed = true
        _ = controller.validateMenuItem(toggle)
        XCTAssertEqual(toggle.title, String(localized: "Show Sidebar"))
        controller.workspacePresentation.isSidebarCollapsed = false
        _ = controller.validateMenuItem(toggle)
        XCTAssertEqual(toggle.title, String(localized: "Hide Sidebar"))
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

    /// The root host's `preferredColorScheme` sets the window's appearance, and
    /// the AppKit sidebar and toolbar inherit it from the window.
    func testTheWindowAndItsSidebarFollowTheInAppAppearanceSetting() async throws {
        let key = SettingsService.appearanceModeDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock { @MainActor in UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(SettingsService.AppearanceMode.dark.rawValue, forKey: key)
        let session = try makeSession()
        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false))
        let window = try XCTUnwrap(controller.window)
        await session.unlock(password: "testpassword123")
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        await waitUntil {
            (controller.workspaceSplitViewController?.splitViewItems.first?.viewController as? MacSidebarViewController)?
                .outlineView.window === window
        }
        let sidebar = try XCTUnwrap(controller.workspaceSplitViewController?.splitViewItems.first?.viewController
            as? MacSidebarViewController)
        XCTAssertTrue(sidebar.outlineView.window === window, "The outline is in the database window")

        for (mode, expected) in [(SettingsService.AppearanceMode.dark, NSAppearance.Name.darkAqua), (.light, .aqua),
                                 (.dark, .darkAqua)] {
            UserDefaults.standard.set(mode.rawValue, forKey: key)
            await waitUntil { Self.match(window.effectiveAppearance) == expected }
            XCTAssertEqual(Self.match(window.effectiveAppearance), expected, mode.rawValue)
            XCTAssertEqual(Self.match(sidebar.outlineView.effectiveAppearance), expected, mode.rawValue)
        }
    }

    func testMainMenuCommandsReachTheWindowControllerWhileTheEntryTableIsFocused() async throws {
        let session = try makeSession()
        let controller = try load(DatabaseWindowController(session: session, windowRegistry: registry(),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false))
        let window = try XCTUnwrap(controller.window)
        await session.unlock(password: "testpassword123")
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        await waitUntil { controller.workspaceSplitViewController?.entryList.tableView.window === window }
        let table = try XCTUnwrap(controller.workspaceSplitViewController?.entryList.tableView)
        XCTAssertTrue(table.window === window)
        XCTAssertTrue(window.makeFirstResponder(table))
        session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first {
            $0.hasPassword && $0.username.isEmpty == false && $0.url.isEmpty == false
        }).id

        let selectors = ["copyUsername:", "copyPassword:", "copyURL:", "copyVerificationCode:", "showInLargeType:", "newEntry:",
                         "newGroup:", "saveDatabase:", "closeDatabase:", "editEntry:", "deleteSelection:",
                         "findEntry:", "lockDatabase:", "duplicateSelectedEntry:", "moveSelectedEntries:",
                         "showAllEntries:", "showVerificationCodes:", "showPasskeys:", "chooseSortOrder:", "chooseSortDirection:",
                         "expandAllGroups:", "collapseAllGroups:", "syncNow:", "showDatabaseSettings:"]
        for name in selectors {
            let item = NSMenuItem(title: "", action: NSSelectorFromString(name), keyEquivalent: "")
            let target = try XCTUnwrap(Self.actionTarget(for: NSSelectorFromString(name), in: window), name)
            XCTAssertTrue(target === controller, "\(name) resolves to \(type(of: target)), not the window controller")
            XCTAssertEqual((target as? NSMenuItemValidation)?.validateMenuItem(item), controller.validateMenuItem(item),
                           name)
        }
        for name in ["copyUsername:", "copyPassword:", "copyURL:", "showInLargeType:", "duplicateSelectedEntry:",
                     "moveSelectedEntries:"] {
            let item = NSMenuItem(title: "", action: NSSelectorFromString(name), keyEquivalent: "")
            XCTAssertEqual(Self.validate(item, in: window), true, "\(name) is enabled with the table focused")
        }
    }

    // MARK: - Helpers

    /// What a nil-targeted action reaches in `window`, in AppKit's order: the
    /// responder chain from the first responder, then the delegate and the
    /// window controller. Spelled out because a window that is never shown is
    /// not key, so `NSApp.target(forAction:)` would not search it.
    private static func actionTarget(for action: Selector, in window: NSWindow) -> AnyObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = window.delegate, delegate.responds(to: action) { return delegate }
        if let windowController = window.windowController, windowController.responds(to: action) {
            return windowController
        }
        return nil
    }

    private static func validate(_ item: NSMenuItem, in window: NSWindow) -> Bool? {
        guard let action = item.action, let target = actionTarget(for: action, in: window) else { return nil }
        return (target as? NSMenuItemValidation)?.validateMenuItem(item)
    }

    private static func match(_ appearance: NSAppearance) -> NSAppearance.Name? {
        appearance.bestMatch(from: [.aqua, .darkAqua])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where condition() == false {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

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
            ("showInLargeType:", commands.canShowPasswordInLargeType),
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
