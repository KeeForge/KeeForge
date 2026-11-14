import AppKit

@MainActor
enum MainMenu {
    // NSRightArrowFunctionKey and NSLeftArrowFunctionKey.
    static let rightArrowKey = "\u{F703}"
    static let leftArrowKey = "\u{F702}"

    static func build() -> NSMenu {
        let menu = NSMenu()
        let app = submenu("KeeForge", in: menu)
        add(String(localized: "About KeeForge"), #selector(AppDelegate.showAboutPanel), to: app)
        #if KEEFORGE_DIRECT_DOWNLOAD
        add(String(localized: "Check for Updates…"), #selector(AppDelegate.checkForUpdates), to: app)
        #endif
        app.addItem(.separator())
        add(String(localized: "Settings…"), #selector(AppDelegate.showSettings), key: ",", to: app)
        app.addItem(.separator())
        _ = submenu(String(localized: "Services"), in: app)
        app.addItem(.separator())
        add(String(localized: "Hide KeeForge"), #selector(NSApplication.hide(_:)), key: "h", to: app)
        add(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], to: app)
        add(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:)), to: app)
        app.addItem(.separator())
        add(String(localized: "Quit KeeForge"), #selector(NSApplication.terminate(_:)), key: "q", to: app)

        let file = submenu(String(localized: "File"), in: menu)
        add(String(localized: "New Entry"), #selector(DatabaseWindowController.newEntry), key: "n", to: file)
        add(String(localized: "New Group"), #selector(DatabaseWindowController.newGroup), key: "n", modifiers: [.command, .shift], to: file)
        file.addItem(.separator())
        add(String(localized: "New Database…"), #selector(AppDelegate.newDatabase), key: "n", modifiers: [.command, .option], to: file)
        add(String(localized: "Open Database File…"), #selector(AppDelegate.openDatabase), key: "o", to: file)
        add(String(localized: "Connect to Server…"), #selector(AppDelegate.connectToServer), to: file)
        file.addItem(.separator())
        add(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), key: "w", to: file)
        add(String(localized: "Save"), #selector(DatabaseWindowController.saveDatabase), key: "s", to: file)
        file.addItem(.separator())
        add(String(localized: "Close Database"), #selector(DatabaseWindowController.closeDatabase), key: "w", modifiers: [.command, .shift], to: file)

        let edit = submenu(String(localized: "Edit"), in: menu)
        add(String(localized: "Undo"), Selector(("undo:")), key: "z", to: edit)
        add(String(localized: "Redo"), Selector(("redo:")), key: "z", modifiers: [.command, .shift], to: edit)
        edit.addItem(.separator())
        add(String(localized: "Cut"), #selector(NSText.cut(_:)), key: "x", to: edit)
        add(String(localized: "Copy"), #selector(NSText.copy(_:)), key: "c", to: edit)
        add(String(localized: "Paste"), #selector(NSText.paste(_:)), key: "v", to: edit)
        add(String(localized: "Select All"), #selector(NSText.selectAll(_:)), key: "a", to: edit)
        edit.addItem(.separator())
        add(String(localized: "Copy Username"), #selector(DatabaseWindowController.copyUsername), key: "b", modifiers: [.command, .shift], to: edit)
        add(String(localized: "Copy Password"), #selector(DatabaseWindowController.copyPassword), key: "c", modifiers: [.command, .shift], to: edit)
        add(String(localized: "Copy URL"), #selector(DatabaseWindowController.copyURL), key: "u", modifiers: [.command, .shift], to: edit)
        add(String(localized: "Copy Verification Code"), #selector(DatabaseWindowController.copyVerificationCode), key: "t", modifiers: [.command, .shift], to: edit)
        edit.addItem(.separator())
        add(String(localized: "Edit Entry"), #selector(DatabaseWindowController.editEntry), key: "e", to: edit)
        add(String(localized: "Duplicate"), #selector(DatabaseWindowController.duplicateSelectedEntry), key: "d", to: edit)
        add(String(localized: "Move to Group…"), #selector(DatabaseWindowController.moveSelectedEntries), to: edit)
        add(String(localized: "Delete"), #selector(DatabaseWindowController.deleteSelection), key: "\u{8}", to: edit)
        edit.addItem(.separator())
        add(String(localized: "Find"), #selector(DatabaseWindowController.findEntry), key: "f", to: edit)

        let view = submenu(String(localized: "View"), in: menu)
        add(String(localized: "Show Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), key: "s", modifiers: [.command, .control], to: view)
        view.addItem(.separator())
        add(DatabaseCollection.allEntries.title, #selector(DatabaseWindowController.showAllEntries), key: "1", to: view)
        add(DatabaseCollection.verificationCodes.title, #selector(DatabaseWindowController.showVerificationCodes), key: "2", to: view)
        add(DatabaseCollection.passkeys.title, #selector(DatabaseWindowController.showPasskeys), key: "3", to: view)
        view.addItem(.separator())
        view.addItem(.sectionHeader(title: String(localized: "Sort By")))
        for order in DatabaseViewModel.SortOrder.allCases {
            add(order.title, #selector(DatabaseWindowController.chooseSortOrder), to: view).representedObject = order.rawValue
        }
        view.addItem(.separator())
        for (title, ascending) in [(String(localized: "Ascending"), true), (String(localized: "Descending"), false)] {
            add(title, #selector(DatabaseWindowController.chooseSortDirection), to: view).representedObject = ascending
        }
        view.addItem(.separator())
        add(String(localized: "Expand All Groups"), #selector(DatabaseWindowController.expandAllGroups),
            key: rightArrowKey, modifiers: [.command, .control], to: view)
        add(String(localized: "Collapse All Groups"), #selector(DatabaseWindowController.collapseAllGroups),
            key: leftArrowKey, modifiers: [.command, .control], to: view)
        view.addItem(.separator())
        add(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control], to: view)

        let database = submenu(String(localized: "Database"), in: menu)
        add(String(localized: "Lock"), #selector(DatabaseWindowController.lockDatabase), key: "l", to: database)
        database.addItem(.separator())
        add(String(localized: "Sync Now"), #selector(DatabaseWindowController.syncNow), key: "r", modifiers: [.command, .shift], to: database)
        database.addItem(.separator())
        add(String(localized: "Database Settings…"), #selector(DatabaseWindowController.showDatabaseSettings), key: "i", to: database)

        let window = submenu(String(localized: "Window"), in: menu)
        add(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window)
        add(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:)), to: window)
        window.addItem(.separator())
        add(String(localized: "Databases"), #selector(AppDelegate.showDatabasesWindow), key: "0", modifiers: [.command, .shift], to: window)
        window.addItem(.separator())
        add(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), to: window)

        let help = submenu(String(localized: "Help"), in: menu)
        add(String(localized: "KeeForge Help"), #selector(AppDelegate.showHelp), to: help)
        add(String(localized: "Report a Bug"), #selector(AppDelegate.reportBug), to: help)
        return menu
    }

    static func install(_ menu: NSMenu) {
        NSApp.mainMenu = menu
        NSApp.servicesMenu = menu.items.first?.submenu?.item(withTitle: String(localized: "Services"))?.submenu
        NSApp.windowsMenu = menu.item(withTitle: String(localized: "Window"))?.submenu
        NSApp.helpMenu = menu.item(withTitle: String(localized: "Help"))?.submenu
    }

    private static func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        parent.addItem(item)
        return submenu
    }

    @discardableResult
    private static func add(_ title: String, _ action: Selector, key: String = "",
                            modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menu.addItem(item)
        return item
    }
}
