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
            ("Databases", "", [], "showDatabasesWindow:"),
            ("Bring All to Front", "", [], "arrangeInFront:"),
        ], [("KeeForge Help", "", [], "showHelp:"), ("Report a Bug", "", [], "reportBug:")]]
        let databaseActions: Set<String> = ["newEntry:", "newGroup:", "saveDatabase:", "closeDatabase:", "copyUsername:", "copyPassword:", "copyURL:", "copyVerificationCode:", "editEntry:", "deleteSelection:", "findEntry:", "lockDatabase:"]
        let appActions: Set<String> = ["showAboutPanel:", "showSettings:", "newDatabase:", "openDatabase:", "showHelp:", "reportBug:", "checkForUpdates:", "showDatabasesWindow:", "connectToServer:"]
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
                    XCTAssertTrue(DatabaseWindowController.instancesRespond(to: selector), contract.3)
                    XCTAssertFalse(AppDelegate.instancesRespond(to: selector), contract.3)
                } else if appActions.contains(contract.3) {
                    XCTAssertTrue(AppDelegate.instancesRespond(to: selector), contract.3)
                    XCTAssertFalse(DatabaseWindowController.instancesRespond(to: selector), contract.3)
                }
            }
        }
        let connect = try XCTUnwrap(menu.items[1].submenu?.items.first { $0.title == localized("Connect to Server") }?.submenu)
        XCTAssertEqual(connect.items.map(\.title), [CloudProviderKind.webDAV.displayName, CloudProviderKind.ftp.displayName])
        XCTAssertEqual(connect.items.compactMap { $0.representedObject as? String }, [CloudProviderKind.webDAV.rawValue, CloudProviderKind.ftp.rawValue])
        XCTAssertTrue(connect.items.allSatisfy { $0.action == #selector(AppDelegate.connectToServer) && $0.target == nil })
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
        let connect = item("connectToServer:")
        connect.representedObject = CloudProviderKind.webDAV.rawValue
        XCTAssertTrue(delegate.validateMenuItem(connect))
        connect.representedObject = CloudProviderKind.dropbox.rawValue
        XCTAssertFalse(delegate.validateMenuItem(connect))
    }

    private func item(_ selector: String) -> NSMenuItem {
        NSMenuItem(title: "", action: NSSelectorFromString(selector), keyEquivalent: "")
    }

    private func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}
#endif
