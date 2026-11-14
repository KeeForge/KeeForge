#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceToolbarTests: XCTestCase {
    func testItemsKeepTheWorkspaceToolbarIdentifiersLabelsAndOrder() async throws {
        let (toolbar, window, splitView) = try await makeToolbarAndSplitView()
        defer { window.close() }
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier.rawValue), [
            "sidebar.left", "workspace.sidebar-separator", "workspace.search", "entry-list.add-entry",
            "database.read-only-indicator", "workspace.list-separator",
            NSToolbarItem.Identifier.flexibleSpace.rawValue, "entry-detail.edit", "workspace.database-status",
            "database-details.button", "database.cloud-sync-now", "lock.button",
        ])
        let statusInsets = toolbar.statusLineView.edgeInsets
        XCTAssertGreaterThanOrEqual(min(statusInsets.left, statusInsets.right), 8,
                                    "The status text keeps clear of the item's rounded background")
        XCTAssertNil(toolbar.items[NSToolbarItem.Identifier("settings.button")], "App Settings is ⌘, and the app menu")
        let separators = [MacWorkspaceToolbar.Item.sidebarSeparator, MacWorkspaceToolbar.Item.listSeparator]
            .compactMap { toolbar.items[$0] as? NSTrackingSeparatorToolbarItem }
        XCTAssertEqual(separators.map(\.dividerIndex), [0, 1], "Search and New Entry sit over the entry list")
        XCTAssertTrue(separators.allSatisfy { $0.splitView === splitView })
        XCTAssertNil(toolbar.items[NSToolbarItem.Identifier("sort.menu")], "Sort moved to the list header")
        let labels = [
            "sidebar.left": "Show Sidebar", "lock.button": "Lock Database",
            "database.read-only-indicator": "Read-only database", "entry-list.add-entry": "New Entry",
            "database-details.button": "Database Settings", "database.cloud-sync-now": "Sync Now",
            "entry-detail.edit": "Edit",
        ]
        for (identifier, label) in labels {
            let item = try XCTUnwrap(toolbar.items[NSToolbarItem.Identifier(identifier)], identifier)
            XCTAssertEqual(item.label, localized(label), identifier)
            XCTAssertEqual(item.toolTip, localized(label), identifier)
            XCTAssertEqual(item.view?.accessibilityIdentifier(), identifier)
            XCTAssertEqual(item.menuFormRepresentation?.title, localized(label), identifier)
            XCTAssertFalse(item.isNavigational, identifier)
        }
        XCTAssertEqual(toolbar.searchItem.searchField.placeholderString,
                       String(localized: "Search \(toolbar.session.databaseDisplayName)"))
        XCTAssertNotEqual(toolbar.session.databaseDisplayName, "")
        XCTAssertFalse(toolbar.toolbar.allowsUserCustomization)
    }

    func testSearchFieldAndSessionTextAreBoundBothWays() async throws {
        let (toolbar, window) = try await makeToolbar()
        defer { window.close() }
        let field = toolbar.searchItem.searchField
        toolbar.session.searchText = "GitHub"
        await Task { @MainActor in }.value
        XCTAssertEqual(field.stringValue, "GitHub")
        field.stringValue = "Work"
        toolbar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(toolbar.session.searchText, "Work")
        await Task { @MainActor in }.value
        XCTAssertEqual(field.stringValue, "Work")
    }

    func testItemStateFollowsSelectionWritabilityAndDatabaseCommands() async throws {
        for readOnly in [false, true] {
            let (toolbar, window) = try await makeToolbar(readOnly: readOnly)
            defer { window.close() }
            let session = toolbar.session
            let edit = try XCTUnwrap(toolbar.items[MacWorkspaceToolbar.Item.edit])
            XCTAssertTrue(edit.isHidden)
            XCTAssertEqual(toolbar.items[MacWorkspaceToolbar.Item.add]?.isHidden, readOnly)
            XCTAssertEqual(toolbar.items[MacWorkspaceToolbar.Item.readOnly]?.isHidden, !readOnly)
            session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first).id
            await Task { @MainActor in }.value
            let commands = DatabaseCommands(session: session)
            XCTAssertEqual(edit.isHidden, readOnly)
            XCTAssertEqual((edit.view as? NSControl)?.isEnabled, commands.canEditEntry)
            XCTAssertEqual((toolbar.items[MacWorkspaceToolbar.Item.add]?.view as? NSControl)?.isEnabled, commands.canNewEntry)
        }
    }

    func testTheStatusItemsShowOnlyWhileTheSidebarIsHidden() async throws {
        let presentation = MacWorkspacePresentation()
        let (toolbar, window, _) = try await makeToolbarAndSplitView(presentation: presentation)
        defer { window.close() }
        let statusItems = MacWorkspaceToolbar.statusItemIdentifiers.compactMap { toolbar.items[$0] }
        XCTAssertEqual(statusItems.count, 4)
        XCTAssertTrue(statusItems.allSatisfy(\.isHidden), "The sidebar's card has them")

        presentation.isSidebarCollapsed = true
        await Task { @MainActor in }.value
        XCTAssertFalse(toolbar.items[MacWorkspaceToolbar.Item.databaseStatus]?.isHidden ?? true)
        XCTAssertFalse(toolbar.items[MacWorkspaceToolbar.Item.databaseSettings]?.isHidden ?? true)
        XCTAssertFalse(toolbar.items[MacWorkspaceToolbar.Item.lock]?.isHidden ?? true)
        XCTAssertEqual(toolbar.items[MacWorkspaceToolbar.Item.syncNow]?.isHidden, true, "A local database has no Sync Now")
        XCTAssertEqual(toolbar.statusLineView.textField.stringValue, String(localized: "On This Mac"))
        XCTAssertEqual(toolbar.statusLineView.accessibilityIdentifier(), "workspace.database-status")
        XCTAssertEqual((toolbar.items[MacWorkspaceToolbar.Item.lock]?.view as? NSControl)?.isEnabled,
                       DatabaseCommands(session: toolbar.session).canLock)

        (toolbar.items[MacWorkspaceToolbar.Item.databaseSettings]?.view as? NSButton)?.performClick(nil)
        XCTAssertTrue(presentation.isShowingDatabaseDetails)

        presentation.isSidebarCollapsed = false
        await Task { @MainActor in }.value
        XCTAssertTrue(statusItems.allSatisfy(\.isHidden))
    }

    func testNewEntryIsOneButtonThatCreatesAnEntry() async throws {
        let (toolbar, window) = try await makeToolbar()
        defer { window.close() }
        let button = try XCTUnwrap(toolbar.items[MacWorkspaceToolbar.Item.add]?.view as? NSButton)
        XCTAssertFalse(button is NSPopUpButton, "No New Group in a pull-down: the File menu and sidebar have it")
        let requests = toolbar.session.workspace.newEntryRequestID
        button.performClick(nil)
        XCTAssertEqual(toolbar.session.workspace.newEntryRequestID, requests + 1)
    }

    private func makeToolbar(readOnly: Bool = false) async throws -> (MacWorkspaceToolbar, NSWindow) {
        let (toolbar, window, _) = try await makeToolbarAndSplitView(readOnly: readOnly)
        return (toolbar, window)
    }

    private func makeToolbarAndSplitView(
        readOnly: Bool = false, presentation: MacWorkspacePresentation = MacWorkspacePresentation()
    ) async throws -> (MacWorkspaceToolbar, NSWindow, NSSplitView) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        reference.isReadOnly = readOnly
        let session = DatabaseViewModel(databaseReference: reference,
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        // Three panes and no autosave name, so nothing is written to the host app's defaults.
        let splitView = NSSplitView()
        splitView.isVertical = true
        for _ in 0..<3 { splitView.addArrangedSubview(NSView()) }
        let toolbar = MacWorkspaceToolbar(session: session, presentation: presentation, splitView: splitView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = splitView
        window.toolbar = toolbar.toolbar
        return (toolbar, window, splitView)
    }

    private func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}
#endif
