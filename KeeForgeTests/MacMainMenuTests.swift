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
        let sortItems: [Item] = DatabaseViewModel.SortOrder.allCases.map { ($0.title, "", [], "chooseSortOrder:") }
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
            ("New Entry", "n", command, "newEntry:"),
            ("New Group", "n", shift, "newGroup:"),
            ("New Database…", "n", option, "newDatabase:"),
            ("Open Database File…", "o", command, "openDatabase:"),
            ("Connect to Server…", "", [], "connectToServer:"),
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
            ("Duplicate", "d", command, "duplicateSelectedEntry:"),
            ("Move to Group…", "", [], "moveSelectedEntries:"),
            ("Delete", "\u{8}", command, "deleteSelection:"),
            ("Find", "f", command, "findEntry:"),
        ], [
            ("Show Sidebar", "s", control, "toggleSidebar:"),
            (DatabaseCollection.allEntries.title, "1", command, "showAllEntries:"),
            (DatabaseCollection.verificationCodes.title, "2", command, "showVerificationCodes:"),
        ] + sortItems + [
            ("Ascending", "", [], "chooseSortDirection:"),
            ("Descending", "", [], "chooseSortDirection:"),
            ("Expand All Groups", MainMenu.rightArrowKey, control, "expandAllGroups:"),
            ("Collapse All Groups", MainMenu.leftArrowKey, control, "collapseAllGroups:"),
            ("Enter Full Screen", "f", control, "toggleFullScreen:"),
        ], [
            ("Lock", "l", command, "lockDatabase:"),
            ("Sync Now", "r", shift, "syncNow:"),
            ("Database Settings…", "i", command, "showDatabaseSettings:"),
        ], [
            ("Minimize", "m", command, "performMiniaturize:"),
            ("Zoom", "", [], "performZoom:"),
            ("Databases", "0", shift, "showDatabasesWindow:"),
            ("Bring All to Front", "", [], "arrangeInFront:"),
        ], [("KeeForge Help", "", [], "showHelp:"), ("Report a Bug", "", [], "reportBug:")]]
        let databaseActions: Set<String> = ["newEntry:", "newGroup:", "saveDatabase:", "closeDatabase:", "copyUsername:", "copyPassword:", "copyURL:", "copyVerificationCode:", "editEntry:", "duplicateSelectedEntry:", "moveSelectedEntries:", "deleteSelection:", "findEntry:", "showAllEntries:", "showVerificationCodes:", "chooseSortOrder:", "chooseSortDirection:", "expandAllGroups:", "collapseAllGroups:", "lockDatabase:", "syncNow:", "showDatabaseSettings:"]
        let appActions: Set<String> = ["showAboutPanel:", "showSettings:", "newDatabase:", "openDatabase:", "showHelp:", "reportBug:", "checkForUpdates:", "showDatabasesWindow:", "connectToServer:"]
        for (top, contracts) in zip(menu.items, expected) {
            let submenu = try XCTUnwrap(top.submenu)
            let items = submenu.items.filter { $0.action != nil && $0.submenu == nil }
            XCTAssertEqual(items.map(\.title), contracts.map { localized($0.0) }, top.title)
            for (item, contract) in zip(items, contracts) {
                XCTAssertEqual(item.keyEquivalent, contract.1, item.title)
                XCTAssertEqual(item.keyEquivalentModifierMask, contract.2, item.title)
                XCTAssertEqual(item.action.map(NSStringFromSelector), contract.3, item.title)
                XCTAssertNil(item.target)
                let selector = NSSelectorFromString(contract.3)
                if databaseActions.contains(contract.3) {
                    XCTAssertTrue(DatabaseWindowController.instancesRespond(to: selector), contract.3)
                    XCTAssertFalse(AppDelegate.instancesRespond(to: selector), contract.3)
                } else if appActions.contains(contract.3) {
                    XCTAssertTrue(AppDelegate.instancesRespond(to: selector), contract.3)
                    XCTAssertFalse(DatabaseWindowController.instancesRespond(to: selector), contract.3)
                }
            }
        }
        XCTAssertEqual(separatedTitles(menu.items[1]), [
            ["New Entry", "New Group"], ["New Database…", "Open Database File…", "Connect to Server…"],
            ["Close Window", "Save"], ["Close Database"],
        ].map { $0.map(localized) })
        XCTAssertEqual(separatedTitles(menu.items[2]).suffix(3), [
            ["Copy Username", "Copy Password", "Copy URL", "Copy Verification Code"],
            ["Edit Entry", "Duplicate", "Move to Group…", "Delete"], ["Find"],
        ].map { $0.map(localized) })
        XCTAssertEqual(separatedTitles(menu.items[3]), [
            ["Show Sidebar"], [DatabaseCollection.allEntries.title, DatabaseCollection.verificationCodes.title],
            [localized("Sort By")] + DatabaseViewModel.SortOrder.allCases.map(\.title),
            ["Ascending", "Descending"].map(localized), ["Expand All Groups", "Collapse All Groups"].map(localized),
            [localized("Enter Full Screen")],
        ])
        let sortHeader = try XCTUnwrap(menu.items[3].submenu?.items.first { $0.title == localized("Sort By") })
        XCTAssertTrue(sortHeader.isSectionHeader)
        XCTAssertEqual(separatedTitles(menu.items[4]), [["Lock"], ["Sync Now"], ["Database Settings…"]].map { $0.map(localized) })
        let view = try XCTUnwrap(menu.items[3].submenu)
        XCTAssertEqual(view.items.filter { $0.action == #selector(DatabaseWindowController.chooseSortOrder) }
            .compactMap { $0.representedObject as? String }, DatabaseViewModel.SortOrder.allCases.map(\.rawValue))
        XCTAssertEqual(view.items.filter { $0.action == #selector(DatabaseWindowController.chooseSortDirection) }
            .compactMap { $0.representedObject as? Bool }, [true, false])
        MainMenu.install(menu)
        XCTAssertTrue(application.windowsMenu === menu.items[5].submenu)
        XCTAssertTrue(application.helpMenu === menu.items[6].submenu)
        XCTAssertEqual(application.servicesMenu?.title, localized("Services"))
    }

    func testLauncherWindowAndAppLevelCommandsIgnoreDatabaseState() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        // The host app's launch shows the Databases window when nothing else opens.
        let window = try XCTUnwrap(delegate.windowCoordinator.databasesWindow)
        XCTAssertEqual(window.identifier, DatabasesWindowController.identifier)
        XCTAssertEqual(window.contentMinSize, DatabasesWindowController.contentSize)
        XCTAssertGreaterThanOrEqual(DatabasesWindowController.contentSize.height, MacSheetMetrics.maxHeight + 60)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        for selector in ["newDatabase:", "openDatabase:"] {
            XCTAssertTrue(delegate.validateMenuItem(item(selector)), selector)
        }
        XCTAssertEqual(delegate.validateMenuItem(item("connectToServer:")), delegate.windowCoordinator.launcher.canConnect)
        XCTAssertTrue(delegate.windowCoordinator.launcher.canConnect, "WebDAV and FTP are Mac servers")
    }

    /// Row and sidebar menus target their controllers, which sit in the
    /// responder chain; a shared selector would catch the nil-targeted
    /// main-menu command first and validate it without a row.
    func testRowMenuSelectorsNeverShadowMainMenuCommands() throws {
        let mainSelectors = Set(Self.actions(in: MainMenu.build()))
        let session = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(
            for: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        ))
        let presentation = MacWorkspacePresentation()
        let list = MacEntryListViewController(session: session, presentation: presentation, currentSession: { nil })
        let sidebar = MacSidebarViewController(session: session, presentation: presentation)
        let rowSelectors = ["copyRowUsername:", "copyRowPassword:", "duplicateEntry:", "restoreEntry:", "moveEntry:",
                            "deleteEntry:", "moveSelection:"]
        let groupSelectors = ["newSubgroup:", "editGroup:", "restoreGroup:", "moveGroup:", "deleteGroup:"]
        for name in rowSelectors { XCTAssertTrue(list.responds(to: NSSelectorFromString(name)), name) }
        for name in groupSelectors { XCTAssertTrue(sidebar.responds(to: NSSelectorFromString(name)), name) }
        XCTAssertTrue(mainSelectors.isDisjoint(with: rowSelectors + groupSelectors),
                      "\(mainSelectors.intersection(rowSelectors + groupSelectors))")
        let appCommands = mainSelectors.map(NSSelectorFromString).filter {
            DatabaseWindowController.instancesRespond(to: $0) || AppDelegate.instancesRespond(to: $0)
        }
        for selector in appCommands where selector != #selector(NSSplitViewController.toggleSidebar(_:)) {
            let name = NSStringFromSelector(selector)
            XCTAssertFalse(list.responds(to: selector), "The entry list shadows \(name)")
            XCTAssertFalse(sidebar.responds(to: selector), "The sidebar shadows \(name)")
        }
    }

    private static func actions(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item in
            (item.action.map { [NSStringFromSelector($0)] } ?? []) + (item.submenu.map(actions(in:)) ?? [])
        }
    }

    /// A menu's titles, split where its separators are.
    private func separatedTitles(_ top: NSMenuItem) -> [[String]] {
        var groups: [[String]] = [[]]
        for item in top.submenu?.items ?? [] {
            if item.isSeparatorItem { groups.append([]) } else { groups[groups.count - 1].append(item.title) }
        }
        return groups.filter { $0.isEmpty == false }
    }

    private func item(_ selector: String) -> NSMenuItem {
        NSMenuItem(title: "", action: NSSelectorFromString(selector), keyEquivalent: "")
    }

    private func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}
#endif
