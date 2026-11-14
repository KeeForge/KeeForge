#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceToolbarTests: XCTestCase {
    func testItemsKeepTheWorkspaceToolbarIdentifiersLabelsAndOrder() async throws {
        let (toolbar, window) = try await makeToolbar()
        defer { window.close() }
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier.rawValue), [
            "sidebar.left", "lock.button", "database.cloud-sync-status",
            "database.read-only-indicator", "entry-list.add-entry", "sort.menu", "database-details.button",
            "settings.button", NSToolbarItem.Identifier.flexibleSpace.rawValue, "entry-detail.edit", "workspace.search",
        ])
        let labels = [
            "sidebar.left": "Show Sidebar", "lock.button": "Lock Database",
            "database.read-only-indicator": "Read-only database", "entry-list.add-entry": "Add Entry or Group",
            "sort.menu": "Sort", "database-details.button": "Database Details", "settings.button": "Settings",
            "entry-detail.edit": "Edit",
        ]
        for (identifier, label) in labels {
            let item = try XCTUnwrap(toolbar.items[NSToolbarItem.Identifier(identifier)], identifier)
            XCTAssertEqual(item.label, localized(label), identifier)
            XCTAssertEqual(item.toolTip, localized(label), identifier)
            XCTAssertEqual(item.view?.accessibilityIdentifier(), identifier)
            XCTAssertEqual(item.menuFormRepresentation?.title, localized(label), identifier)
            XCTAssertEqual(item.isNavigational, identifier != "entry-detail.edit", identifier)
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
            XCTAssertEqual(toolbar.items[MacWorkspaceToolbar.Item.cloudSync]?.isHidden, true)
            session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first).id
            await Task { @MainActor in }.value
            let commands = DatabaseCommands(session: session)
            XCTAssertEqual(edit.isHidden, readOnly)
            XCTAssertEqual((edit.view as? NSControl)?.isEnabled, commands.canEditEntry)
            XCTAssertEqual((toolbar.items[MacWorkspaceToolbar.Item.lock]?.view as? NSControl)?.isEnabled, commands.canLock)
            XCTAssertEqual((toolbar.items[MacWorkspaceToolbar.Item.add]?.view as? NSControl)?.isEnabled, commands.canNewEntry)
        }
    }

    func testTheSortMenuIsFlatAndDimsWhileTheListIsEmpty() async throws {
        let savedSort = ["KeeForge.sortOrder", "KeeForge.sortAscending"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock { for (key, value) in savedSort { UserDefaults.standard.set(value, forKey: key) } }
        let (toolbar, window) = try await makeToolbar()
        defer { window.close() }
        let session = toolbar.session
        let item = try XCTUnwrap(toolbar.items[MacWorkspaceToolbar.Item.sort])
        let popUp = try XCTUnwrap(item.view as? NSPopUpButton)
        let items = try XCTUnwrap(popUp.menu?.items.dropFirst(), "The first item is the pull-down's face")
        XCTAssertTrue(items.allSatisfy { $0.submenu == nil }, "No submenus")
        XCTAssertEqual(items.map(\.title), [localized("Sort By")] + DatabaseViewModel.SortOrder.allCases.map(\.title)
            + ["", localized("Ascending"), localized("Descending")])
        XCTAssertTrue(try XCTUnwrap(items.first).isSectionHeader)
        XCTAssertTrue(items[items.startIndex + 4].isSeparatorItem)
        XCTAssertEqual(item.menuFormRepresentation?.submenu?.items.map(\.title), items.map(\.title))

        session.workspace.selectedCollection = .allEntries
        session.sortOrder = .modifiedDate
        session.sortAscending = false
        await Task { @MainActor in }.value
        let states = items.filter { $0.representedObject != nil }.map { $0.state == .on }
        XCTAssertEqual(states, DatabaseViewModel.SortOrder.allCases.map { $0 == .modifiedDate } + [false, true])
        XCTAssertTrue(popUp.isEnabled)

        session.searchText = "no entry matches this"
        await Task { @MainActor in }.value
        XCTAssertFalse(popUp.isEnabled, "Sort is dimmed while the list is empty")
        XCTAssertEqual(item.menuFormRepresentation?.isEnabled, false)
        session.searchText = ""
        await Task { @MainActor in }.value
        XCTAssertTrue(popUp.isEnabled)
    }

    private func makeToolbar(readOnly: Bool = false) async throws -> (MacWorkspaceToolbar, NSWindow) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        reference.isReadOnly = readOnly
        let session = DatabaseViewModel(databaseReference: reference,
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        let toolbar = MacWorkspaceToolbar(session: session, presentation: MacWorkspacePresentation())
        // No split view: a windowed one autosaves its layout into the host app's defaults.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = toolbar.toolbar
        return (toolbar, window)
    }

    private func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}
#endif
