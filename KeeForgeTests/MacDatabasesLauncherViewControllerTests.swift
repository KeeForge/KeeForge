#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

/// The Databases window's AppKit content, in a window that is never shown.
@MainActor
final class MacDatabasesLauncherViewControllerTests: XCTestCase {
    @MainActor @Observable
    final class Store {
        var references: [DatabaseReference] = []
        var unlocked: Set<UUID> = []
        var touchID: Set<UUID> = []
        var opened: [UUID] = []
    }

    func testBrandPanelSendsTheMenuCommandsAndShowsTheVersion() async throws {
        let (controller, _, _) = await makeController([])
        let buttons = [controller.newDatabaseButton, controller.openFileButton, controller.connectButton]
        XCTAssertEqual(buttons.map(\.commandTitle), ["New Database…", "Open Database File…", "Connect to Server…"]
            .map { String(localized: String.LocalizationValue($0)) })
        XCTAssertEqual(buttons.map(\.action), [#selector(AppDelegate.newDatabase(_:)),
            #selector(AppDelegate.openDatabase(_:)), #selector(AppDelegate.connectToServer(_:))])
        XCTAssertTrue(buttons.allSatisfy { $0.target == nil }, "Nil-targeted, like the File menu")
        XCTAssertEqual(buttons.map { $0.accessibilityIdentifier() },
                       ["databases.create-new", "databases.add-existing", "databases.connect-server"])
        XCTAssertEqual(buttons.map(\.shortcut), ["⌥⌘N", "⌘O", ""])
        controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        controller.view.layoutSubtreeIfNeeded()
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.titleField.frame.width.rounded(.up),
                                        button.titleField.intrinsicContentSize.width.rounded(.down),
                                        "\(button.commandTitle) is not clipped by its shortcut")
        }
        XCTAssertEqual(MacLauncherEmptyStateView.symbolName, "folder.badge.plus", "FirstRun draws a folder with a plus")
        XCTAssertEqual(controller.connectButton.caption, "WebDAV, FTP")
        XCTAssertTrue(controller.connectButton.isEnabled)
        XCTAssertEqual(MacDatabasesLauncherViewController.versionText("1.22"), String(localized: "Version \("1.22")"))
        XCTAssertFalse(controller.versionField.stringValue.isEmpty)
        XCTAssertEqual(controller.listLabel.stringValue, String(localized: "Databases"))

        let addMenu = controller.addMenu()
        XCTAssertEqual(addMenu.items.map(\.title), buttons.map(\.commandTitle))
        XCTAssertEqual(addMenu.items.map(\.action), buttons.map(\.action))
        XCTAssertEqual(controller.addButton.accessibilityIdentifier(), "database.add.button")
        XCTAssertEqual(controller.addButton.accessibilityLabel(), String(localized: "Add Database"))
        XCTAssertEqual(controller.removeButton.accessibilityIdentifier(), "databases.remove")
        XCTAssertEqual(controller.removeButton.accessibilityLabel(), String(localized: "Remove Database from List"))
    }

    /// FirstRun: the brand panel keeps the actions; the list says it is empty, once, with no buttons of its own.
    func testBrandActionTilesResolveTheirColoursForTheWindowAppearance() async throws {
        let (controller, _, _) = await makeController([])
        let tile = controller.newDatabaseButton.tile
        func background(_ name: NSAppearance.Name) throws -> CGColor {
            var color: CGColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                color = NSColor.controlBackgroundColor.cgColor
            }
            return try XCTUnwrap(color)
        }
        controller.view.window?.appearance = NSAppearance(named: .aqua)
        await settle()
        XCTAssertEqual(tile.layer?.backgroundColor, try background(.aqua))
        controller.view.window?.appearance = NSAppearance(named: .darkAqua)
        await settle()
        XCTAssertEqual(tile.layer?.backgroundColor, try background(.darkAqua))
    }

    func testFirstRunShowsTheEmptyStateWithoutRepeatingTheActions() async throws {
        let (controller, store, launcher) = await makeController([])
        XCTAssertFalse(controller.emptyStateView.isHidden)
        XCTAssertEqual(controller.emptyStateView.titleField.stringValue, String(localized: "No Databases"))
        XCTAssertEqual(controller.emptyStateView.messageField.stringValue,
                       String(localized: "Create a database, open a .kdbx file or connect to a server to get started."))
        XCTAssertFalse(controller.emptyStateView.arrangedSubviews.contains { $0 is NSButton })
        XCTAssertTrue(controller.tableView.enclosingScrollView?.isHidden == true)
        XCTAssertFalse(controller.removeButton.isEnabled)
        XCTAssertEqual(launcher.emptyState, .firstRun)

        store.references = [try reference(provider: .dropbox)]
        await settle()
        XCTAssertEqual(controller.emptyStateView.messageField.stringValue,
                       String(localized: "None of your databases can be opened on this Mac."))
        store.references.append(try reference())
        await settle()
        XCTAssertTrue(controller.emptyStateView.isHidden)
        XCTAssertFalse(controller.tableView.enclosingScrollView?.isHidden ?? true)
        XCTAssertEqual(controller.tableView.numberOfRows, 1)
    }

    func testRowsShowTitleSubtitleStateAndBadges() async throws {
        var local = try reference()
        local.filename = "archive.kdbx"
        local.isQuickLaunch = true
        var server = try reference(provider: .webDAV)
        server.filename = "work-vault.kdbx"
        server.nickname = "Work Vault"
        server.isReadOnly = true
        let (controller, store, _) = await makeController([local, server])
        store.unlocked = [local.id]
        store.touchID = [server.id]
        await settle()

        XCTAssertEqual(controller.tableView.numberOfRows, 2)
        let first = try cell(controller, 0)
        XCTAssertGreaterThan(controller.tableView.tableColumns[0].width, 400, "The column fills the list panel")
        first.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(first.titleField.frame.width, first.titleField.intrinsicContentSize.width,
                                    "The name is not squeezed out of the row")
        XCTAssertEqual(first.titleField.stringValue, "archive")
        XCTAssertEqual(first.titleField.accessibilityIdentifier(), "database.row")
        XCTAssertEqual(first.subtitleField.stringValue, "archive.kdbx · \(String(localized: "On This Mac"))")
        XCTAssertFalse(first.openStack.isHidden)
        XCTAssertEqual(first.openState.stringValue, String(localized: "database-state.open", defaultValue: "Open"))
        XCTAssertTrue(first.lockImage.isHidden)
        XCTAssertFalse(first.quickLaunchBadge.isHidden)
        XCTAssertEqual(first.quickLaunchBadge.accessibilityIdentifier(), "database-row.quick-launch-badge")
        XCTAssertTrue(first.readOnlyBadge.isHidden)
        XCTAssertTrue(first.touchIDImage.isHidden)

        let second = try cell(controller, 1)
        XCTAssertEqual(second.titleField.stringValue, "Work Vault")
        XCTAssertEqual(second.subtitleField.stringValue, "work-vault.kdbx · WebDAV")
        XCTAssertTrue(second.openStack.isHidden)
        XCTAssertFalse(second.lockImage.isHidden)
        XCTAssertEqual(second.lockImage.accessibilityIdentifier(), "database-row.locked")
        XCTAssertFalse(second.readOnlyBadge.isHidden)
        XCTAssertEqual(second.readOnlyBadge.accessibilityIdentifier(), "database-row.read-only-badge")
        XCTAssertFalse(second.touchIDImage.isHidden)
        XCTAssertEqual(controller.tableView(controller.tableView, heightOfRow: 1), MacDatabasesLauncherViewController.rowHeight)

        store.unlocked = []
        await settle()
        XCTAssertTrue(try cell(controller, 0).openStack.isHidden, "Locking turns Open back into the lock")
        XCTAssertFalse(try cell(controller, 0).lockImage.isHidden)
    }

    func testSelectionFollowsTheModelBothWaysAndReturnOpensOnlyTheSelection() async throws {
        let first = try reference()
        let second = try reference()
        let (controller, store, launcher) = await makeController([first, second])
        let table = controller.tableView
        XCTAssertEqual(table.selectedRow, -1)

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(launcher.selectedDatabaseID, second.id)
        await settle()
        XCTAssertTrue(controller.removeButton.isEnabled)

        launcher.selectedDatabaseID = first.id
        await settle()
        XCTAssertEqual(table.selectedRow, 0)

        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: returnKey)
        XCTAssertEqual(store.opened, [first.id])
        XCTAssertNil(launcher.sheet, "Opening a row never presents a picker or sheet")

        launcher.selectedDatabaseID = nil
        await settle()
        XCTAssertEqual(table.selectedRow, -1)
        table.keyDown(with: returnKey)
        XCTAssertEqual(store.opened, [first.id])
    }

    func testRowMenuOffersTheManagementItemsAndActsOnThatRow() async throws {
        var reference = try reference()
        reference.isQuickLaunch = true
        let (controller, store, launcher) = await makeController([reference])
        let items = controller.menuItems(for: reference)
        let actionItems = items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(actionItems.map { $0.identifier?.rawValue }, [
            "database-row.open-action", "database-row.rename", "database-row.key-file",
            "database-row.quick-launch-toggle", "database-row.read-only-toggle", "database-row.export-copy-action",
            "database-row.details", "database-row.remove",
        ])
        XCTAssertEqual(items.first?.title, String(localized: "Open"))
        XCTAssertTrue(items[1].isSeparatorItem, "Open stands apart")
        XCTAssertTrue(items[items.count - 2].isSeparatorItem, "Remove stands apart")
        XCTAssertEqual(actionItems.first { $0.identifier?.rawValue == "database-row.quick-launch-toggle" }?.state, .on)
        XCTAssertEqual(actionItems.first { $0.identifier?.rawValue == "database-row.read-only-toggle" }?.state, .off)
        XCTAssertTrue(actionItems.allSatisfy { $0.target === controller && $0.action == #selector(controller.performRowMenuItem(_:)) })

        controller.performRowMenuItem(try XCTUnwrap(actionItems.first))
        XCTAssertEqual(store.opened, [reference.id])
        controller.performRowMenuItem(try XCTUnwrap(actionItems.first { $0.identifier?.rawValue == "database-row.details" }))
        XCTAssertEqual(launcher.sheet, .details(reference.id))
        controller.performRowMenuItem(try XCTUnwrap(actionItems.last))
        XCTAssertEqual(launcher.pendingRemoval?.id, reference.id)
    }

    func testRemoveButtonAsksAboutTheSelectedDatabase() async throws {
        let reference = try reference()
        let (controller, _, launcher) = await makeController([reference])
        XCTAssertFalse(controller.removeButton.isEnabled)
        launcher.selectedDatabaseID = reference.id
        await settle()
        XCTAssertTrue(controller.removeButton.isEnabled)
        controller.removeButton.performClick(nil)
        XCTAssertEqual(launcher.pendingRemoval?.id, reference.id)
    }

    func testAProblemAddsAThirdLineAndATallerRow() async throws {
        let reference = try reference()
        let store = Store()
        store.references = [reference]
        let launcher = makeLauncher(store)
        launcher.status = { _ in DatabaseRowStatus(hasStoredKey: false, hasAccessIssue: true, cloudState: nil) }
        let controller = await host(launcher)
        let row = try cell(controller, 0)
        XCTAssertFalse(row.detailField.isHidden)
        XCTAssertEqual(row.detailField.stringValue, String(localized: "File unavailable"))
        XCTAssertFalse(row.detailIcon.isHidden)
        XCTAssertEqual(controller.tableView(controller.tableView, heightOfRow: 0),
                       MacDatabasesLauncherViewController.rowWithDetailHeight)
    }

    // MARK: - Helpers

    private func makeController(_ references: [DatabaseReference])
        async -> (MacDatabasesLauncherViewController, Store, MacDatabasesLauncherViewModel) {
        let store = Store()
        store.references = references
        let launcher = makeLauncher(store)
        return (await host(launcher), store, launcher)
    }

    private func makeLauncher(_ store: Store) -> MacDatabasesLauncherViewModel {
        let launcher = MacDatabasesLauncherViewModel(references: { store.references })
        launcher.isUnlocked = { store.unlocked.contains($0) }
        launcher.status = { DatabaseRowStatus(hasStoredKey: store.touchID.contains($0.id), hasAccessIssue: false, cloudState: nil) }
        launcher.openDatabase = { store.opened.append($0.id) }
        return launcher
    }

    private func host(_ launcher: MacDatabasesLauncherViewModel) async -> MacDatabasesLauncherViewController {
        let controller = MacDatabasesLauncherViewController(launcher: launcher)
        // Never ordered in: the table only needs a window to lay out its rows.
        let size = DatabasesWindowController.contentSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        addTeardownBlock { @MainActor in window.close() }
        controller.view.layoutSubtreeIfNeeded()
        await settle()
        return controller
    }

    private func cell(_ controller: MacDatabasesLauncherViewController, _ row: Int) throws -> MacLauncherRowCellView {
        try XCTUnwrap(controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacLauncherRowCellView)
    }

    private func settle() async {
        for _ in 0..<4 { await Task { @MainActor in }.value }
    }

    private func reference(provider: CloudProviderKind? = nil) throws -> DatabaseReference {
        var reference = try TestDatabaseSupport.makeReference(
            for: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self)), autoFillEnabled: false)
        if let provider {
            reference.source = .cloud(CloudSyncMetadata(provider: provider.rawValue, accountId: "account",
                fileId: "/vault.kdbx", displayPath: "/vault.kdbx", remoteContentHash: nil, remoteModifiedAt: nil,
                remoteRev: nil, lastSyncedAt: nil, lastSyncIssue: nil))
        }
        return reference
    }
}
#endif
