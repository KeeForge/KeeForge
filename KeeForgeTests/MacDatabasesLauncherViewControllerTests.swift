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
    }

    /// At the window's minimum size the brand column and three rows with a problem line fit unclipped.
    func testTheMinimumSizeFitsTheBrandColumnAndThreeRows() async throws {
        let (controller, _, _) = await makeController([])
        let root = controller.view
        XCTAssertEqual(root.frame.size, DatabasesWindowController.contentSize)
        let version = root.convert(controller.versionField.bounds, from: controller.versionField)
        let firstAction = root.convert(controller.newDatabaseButton.bounds, from: controller.newDatabaseButton)
        let lastAction = root.convert(controller.connectButton.bounds, from: controller.connectButton)
        XCTAssertGreaterThanOrEqual(version.minY, firstAction.maxY + 16, "The actions stay clear of the version")
        XCTAssertGreaterThanOrEqual(lastAction.minY, 16)
        let list = try XCTUnwrap(controller.tableView.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(list.frame.height,
            3 * (MacDatabasesLauncherViewController.rowWithDetailHeight + controller.tableView.intercellSpacing.height))
        XCTAssertEqual(list.frame.minY, 0, "No bar under the list; the brand panel and menus add and remove")
    }

    /// The press background is the button's own and clears when the click, and the action it sent, ends.
    func testActionButtonClearsItsPressedBackgroundAfterTheClick() async throws {
        let (controller, _, _) = await makeController([])
        let button = controller.newDatabaseButton
        let window = try XCTUnwrap(button.window)
        final class Target: NSObject {
            var backgroundDuringAction: CGColor?
            var fired = false
            @objc func fire(_ sender: MacLauncherActionButton) {
                fired = true
                backgroundDuringAction = sender.layer?.backgroundColor
            }
        }
        let target = Target()
        button.target = target
        button.action = #selector(Target.fire(_:))
        XCTAssertEqual((button.cell as? NSButtonCell)?.highlightsBy, [], "The cell draws no highlight of its own")
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // The tracking loop inside mouseDown ends on this queued mouse-up.
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        button.mouseDown(with: try event(.leftMouseDown))
        XCTAssertTrue(target.fired)
        XCTAssertNotNil(target.backgroundDuringAction, "Pressed while the click is down")
        XCTAssertFalse(button.isPressed)
        XCTAssertNil(button.layer?.backgroundColor, "Back to normal once the click ends")
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
        XCTAssertTrue(second.readOnlyBadge.superview === second.titleField.superview, "Read-Only sits inline after the name")
        XCTAssertFalse(second.readOnlyBadge.superview === second.lockImage.superview)
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

    func testDeleteKeyAndEditDeleteAskAboutTheSelectedDatabase() async throws {
        let reference = try reference()
        let (controller, _, launcher) = await makeController([reference])
        let deleteItem = NSMenuItem(title: "", action: #selector(controller.deleteSelection(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(deleteItem), "Nothing selected")
        let chain = sequence(first: controller.tableView as NSResponder, next: \.nextResponder)
        XCTAssertTrue(chain.contains { $0 === controller }, "Edit > Delete reaches the launcher from the list")
        launcher.selectedDatabaseID = reference.id
        await settle()
        XCTAssertTrue(controller.validateMenuItem(deleteItem))
        controller.deleteSelection(nil)
        XCTAssertEqual(launcher.pendingRemoval?.id, reference.id)

        launcher.pendingRemoval = nil
        for keyCode: UInt16 in [51, 117] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                isARepeat: false, keyCode: keyCode))
            controller.tableView.keyDown(with: key)
            XCTAssertEqual(launcher.pendingRemoval?.id, reference.id, "key \(keyCode)")
            launcher.pendingRemoval = nil
        }
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
