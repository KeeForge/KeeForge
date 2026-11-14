#if os(macOS)
import AppKit
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class MacEntryListViewControllerTests: MacSidebarSessionTestCase {
    private static let sortDefaultsKeys = ["KeeForge.sortOrder", "KeeForge.sortAscending"]
    private var savedSortDefaults: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        savedSortDefaults = Self.sortDefaultsKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    override func tearDown() async throws {
        for key in Self.sortDefaultsKeys {
            UserDefaults.standard.set(savedSortDefaults[key], forKey: key)
        }
        try await super.tearDown()
    }

    /// Work holds Account 00…(count-1) sorted by title; Other is empty; the
    /// Recycle Bin holds Gone.
    private struct Tree {
        let work: KPGroup
        let other: KPGroup
        let recycleBin: KPGroup
        let gone: KPEntry
        let root: KPGroup

        init(count: Int = 3, key: SymmetricKey, configure: (inout [KPEntry]) -> Void = { _ in }) throws {
            var entries = try (0..<count).map { index in
                KPEntry(title: String(format: "Account %02d", index), username: "user\(index)",
                        password: try EncryptedValue.encrypt("secret\(index)", using: key))
            }
            configure(&entries)
            work = KPGroup(name: "Work", entries: entries)
            other = KPGroup(name: "Other")
            gone = KPEntry(title: "Gone", username: "old", password: try EncryptedValue.encrypt("gone", using: key))
            recycleBin = KPGroup(name: "Recycle Bin", entries: [gone])
            root = KPGroup(name: "Root", groups: [work, other, recycleBin], recycleBinUUID: recycleBin.id)
        }
    }

    // MARK: - Structure

    func testRowsFollowTheSnapshotInANativeInsetTable() async throws {
        let (controller, session, _, tree) = try await makeController()
        let table = controller.tableView

        XCTAssertEqual(table.style, .inset)
        XCTAssertEqual(table.numberOfColumns, 1)
        XCTAssertNil(table.headerView)
        XCTAssertTrue(table.allowsMultipleSelection)
        XCTAssertTrue(table.allowsEmptySelection)
        XCTAssertEqual(titles(controller), tree.work.entries.map(\.title))
        XCTAssertEqual(controller.snapshot, MacEntryListSnapshot.make(session: session))

        session.workspace.selectedCollection = .allEntries
        await settle()
        XCTAssertEqual(titles(controller), MacEntryListSnapshot.make(session: session).rows.map(\.title))
        XCTAssertEqual(table.delegate?.tableView?(table, heightOfRow: 0), MacEntryListViewController.rowWithFolderHeight)
        session.workspace.selectedGroupID = tree.work.id
        await settle()
        XCTAssertEqual(table.delegate?.tableView?(table, heightOfRow: 0), MacEntryListViewController.rowHeight)
    }

    func testEditsApplyRowUpdatesThatKeepRowObjectsSelectionAndScroll() async throws {
        let (controller, session, _, tree) = try await makeController(count: 60, height: 300)
        let table = controller.tableView
        let selected = tree.work.entries[31]
        session.workspace.selectedEntryID = selected.id
        await settle()
        table.scrollRowToVisible(40)
        table.scrollRowToVisible(30)
        controller.view.layoutSubtreeIfNeeded()
        let origin = table.visibleRect.origin
        let neighbour = try XCTUnwrap(cell(controller, entryID: tree.work.entries[30].id))
        let edited = try XCTUnwrap(cell(controller, entryID: selected.id))

        try replaceWork(in: session, tree: tree) { entries in
            entries[31].title = "Account 31 renamed"
        }
        await settle()
        XCTAssertTrue(cell(controller, entryID: tree.work.entries[30].id) === neighbour, "An unchanged row keeps its view")
        XCTAssertTrue(cell(controller, entryID: selected.id) === edited, "The renamed row is updated in place")
        XCTAssertEqual(edited.textField?.stringValue, "Account 31 renamed")
        XCTAssertEqual(table.visibleRect.origin, origin)
        XCTAssertEqual(selectedIDs(controller), [selected.id])

        let created = KPEntry(title: "Account 30a")
        try replaceWork(in: session, tree: tree) { entries in
            entries[31].title = "Account 31 renamed"
            entries.append(created)
        }
        await settle()
        XCTAssertEqual(titles(controller), MacEntryListSnapshot.make(session: session).rows.map(\.title))
        XCTAssertEqual(rowIndex(controller, entryID: created.id), 31)
        XCTAssertEqual(selectedIDs(controller), [selected.id])
        XCTAssertTrue(cell(controller, entryID: tree.work.entries[30].id) === neighbour)

        try replaceWork(in: session, tree: tree) { entries in
            entries[31].title = "Account 31 renamed"
            entries.append(created)
            entries.remove(at: 30)
        }
        await settle()
        XCTAssertEqual(titles(controller), MacEntryListSnapshot.make(session: session).rows.map(\.title))
        XCTAssertNil(rowIndex(controller, entryID: tree.work.entries[30].id))
        XCTAssertEqual(selectedIDs(controller), [selected.id])

        session.sortAscending = false
        await settle()
        XCTAssertEqual(titles(controller), MacEntryListSnapshot.make(session: session).rows.map(\.title))
        XCTAssertEqual(titles(controller).first, "Account 59")
        XCTAssertEqual(selectedIDs(controller), [selected.id], "A resort moves the selection with its entry")
    }

    // MARK: - Selection

    func testModelSelectionDrivesTheTableAndTheBar() async throws {
        let (controller, session, _, tree) = try await makeController()
        let entries = tree.work.entries

        session.workspace.selectedEntryID = entries[1].id
        await settle()
        XCTAssertEqual(controller.tableView.selectedRowIndexes, [1])
        XCTAssertTrue(controller.selectionBar.isHidden)

        session.workspace.setEntrySelection([entries[0].id, entries[2].id, tree.gone.id])
        await settle()
        XCTAssertEqual(controller.tableView.selectedRowIndexes, [0, 2], "Only the visible picks are selected")
        XCTAssertFalse(controller.selectionBar.isHidden)
        XCTAssertEqual(controller.selectionBar.countField.stringValue, String(localized: "\(3) entries"))
        XCTAssertTrue(controller.selectionBar.moveButton.isEnabled)

        session.workspace.endEntrySelection()
        await settle()
        XCTAssertEqual(controller.tableView.selectedRowIndexes, [1])
        XCTAssertTrue(controller.selectionBar.isHidden)
    }

    func testTheSelectionBarFitsItsTextsInTheDefaultColumnWidth() {
        let bar = MacEntrySelectionBarView()
        bar.update(selection: Set((0..<12).map { _ in UUID() }), isReadOnly: false, isSaving: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        for view in [bar.countField, bar.cancelButton, bar.moveButton] {
            XCTAssertGreaterThanOrEqual(view.frame.width + 0.5, view.intrinsicContentSize.width,
                                        "\(view) is truncated")
        }
        XCTAssertLessThanOrEqual(bar.moveButton.frame.maxX, bar.frame.width)
    }

    func testTableSelectionWritesTheWorkspaceExtendingAndFiltering() async throws {
        let (controller, session, _, tree) = try await makeController()
        let table = controller.tableView
        let entries = tree.work.entries
        var extending = false
        controller.isExtendingSelection = { extending }

        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertEqual(session.workspace.selectedEntryID, entries[1].id)
        XCTAssertNil(session.workspace.entrySelection)

        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        XCTAssertEqual(session.workspace.entrySelection, [entries[0].id, entries[2].id])
        XCTAssertNil(session.workspace.commandEntryID)

        // A Command-click elsewhere keeps the picks this list does not show.
        session.workspace.selectedCollection = .allEntries
        session.searchText = "Account 01"
        await settle()
        extending = true
        table.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertEqual(session.workspace.entrySelection, Set(entries.map(\.id)))

        await settle()
        extending = false
        table.deselectAll(nil)
        table.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertNil(session.workspace.entrySelection, "A plain click collapses the selection")
        XCTAssertEqual(session.workspace.selectedEntryID, entries[1].id)

        let (readOnly, readOnlySession, _, readOnlyTree) = try await makeController(readOnly: true)
        readOnlySession.workspace.selectedEntryID = readOnlyTree.work.entries[1].id
        await settle()
        XCTAssertEqual(readOnly.tableView(readOnly.tableView, selectionIndexesForProposedSelection: [0, 1, 2]), [1],
                       "A read-only database keeps one row")
    }

    func testRecycledRowsCannotJoinAMultipleSelection() async throws {
        let (controller, session, _, tree) = try await makeController()
        let bin = tree.recycleBin
        let extra = KPEntry(title: "Gone too")
        let root = tree.root.deepCopy()
        root.groups.first { $0.id == bin.id }?.entries.append(extra)
        session.draft = DatabaseDraft(rootGroup: root, meta: KPMeta(recycleBin: .group(bin.id)),
                                      sessionKey: try XCTUnwrap(session.sessionKey))
        session.workspace.selectedGroupID = bin.id
        await settle()
        let table = controller.tableView
        table.selectRowIndexes([0], byExtendingSelection: false)

        XCTAssertEqual(controller.tableView(table, selectionIndexesForProposedSelection: [0, 1]), [0])
    }

    // MARK: - Keyboard and mouse

    func testReturnAndDoubleClickOpenTheEditorWhileOtherKeysDoNothing() async throws {
        let (controller, session, presentation, tree) = try await makeController()
        let table = controller.tableView
        let entry = tree.work.entries[2]
        XCTAssertTrue(table.target === controller)
        XCTAssertNotNil(table.doubleAction)

        var requests = session.workspace.editEntryRequestID
        table.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(session.workspace.editEntryRequestID, requests, "Nothing selected opens nothing")

        session.workspace.selectedEntryID = entry.id
        await settle()
        table.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(session.workspace.editEntryRequestID, requests + 1)
        table.keyDown(with: try key(76, "\u{3}"))
        XCTAssertEqual(session.workspace.editEntryRequestID, requests + 2, "Enter opens as Return does")

        requests = session.workspace.editEntryRequestID
        let deletions = session.workspace.deleteSelectionRequestID
        table.keyDown(with: try key(51, "\u{7f}"))
        table.keyDown(with: try key(49, " "))
        XCTAssertEqual(session.workspace.editEntryRequestID, requests)
        XCTAssertEqual(session.workspace.deleteSelectionRequestID, deletions)
        XCTAssertNil(presentation.pendingDeletion)

        controller.openEntry(atRow: 0)
        XCTAssertEqual(session.workspace.selectedEntryID, tree.work.entries[0].id)
        XCTAssertEqual(session.workspace.editEntryRequestID, requests + 1)

        session.workspace.setEntrySelection([tree.work.entries[0].id, entry.id])
        await settle()
        controller.openEntry(atRow: 1)
        table.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(session.workspace.editEntryRequestID, requests + 1, "A multiple selection opens nothing")
    }

    func testEscapeAndCancelEndAMultipleSelection() async throws {
        let (controller, session, presentation, tree) = try await makeController()
        let ids = Set(tree.work.entries.prefix(2).map(\.id))
        XCTAssertEqual(controller.selectionBar.cancelButton.keyEquivalent, "\u{1b}")

        session.workspace.setEntrySelection(ids)
        await settle()
        controller.tableView.cancelOperation(nil)
        XCTAssertNil(session.workspace.entrySelection)

        session.workspace.setEntrySelection(ids)
        await settle()
        controller.selectionBar.moveButton.performClick(nil)
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.entries(ids).id)
        controller.selectionBar.cancelButton.performClick(nil)
        XCTAssertNil(session.workspace.entrySelection)
        await settle()
        XCTAssertTrue(controller.selectionBar.isHidden)
    }

    // MARK: - Context menu

    func testMenusFollowTheWritableReadOnlyAndRecycleBinGates() async throws {
        let (controller, session, _, tree) = try await makeController()
        let entry = tree.work.entries[0]

        XCTAssertEqual(identifiers(controller.contextMenuItems(forEntryID: entry.id)), [
            EntryRowActions.copyUsernameIdentifier, EntryRowActions.copyPasswordIdentifier,
            EntryRowActions.duplicateIdentifier, EntryRowActions.moveIdentifier, EntryRowActions.deleteIdentifier,
        ])
        let items = controller.contextMenuItems(forEntryID: entry.id)
        XCTAssertEqual(items.map(\.title), [
            String(localized: "Copy Username"), String(localized: "Copy Password"), "", String(localized: "Duplicate"),
            String(localized: "Move to Group…"), "", String(localized: "Delete"),
        ])
        XCTAssertEqual(items.map(\.isSeparatorItem), [false, false, true, false, false, true, false])
        let command: NSEvent.ModifierFlags = .command
        let shift: NSEvent.ModifierFlags = [.command, .shift]
        let commandItems = items.filter { $0.isSeparatorItem == false }
        XCTAssertEqual(commandItems.map(\.keyEquivalent), ["b", "c", "d", "", "\u{8}"])
        XCTAssertEqual(commandItems.map(\.keyEquivalentModifierMask), [shift, shift, command, [], command],
                       "The menu bar's shortcuts, shown in the row menu")
        XCTAssertTrue(items.filter { $0.isSeparatorItem == false }.allSatisfy {
            controller.validateMenuItem($0) && $0.target === controller && $0.image == nil
        })
        XCTAssertFalse(identifiers(controller.contextMenuItems(forEntryID: entry.id))
            .contains(EntryRowActions.selectIdentifier), "Native multi-select replaces Select Entries")

        XCTAssertEqual(identifiers(controller.contextMenuItems(forEntryID: tree.gone.id)), [
            EntryRowActions.copyUsernameIdentifier, EntryRowActions.copyPasswordIdentifier,
            EntryRowActions.restoreIdentifier, EntryRowActions.deletePermanentlyIdentifier,
        ])
        XCTAssertEqual(controller.contextMenuItems(forEntryID: tree.gone.id).map(\.title), [
            String(localized: "Copy Username"), String(localized: "Copy Password"), "", String(localized: "Restore"), "",
            String(localized: "Delete Permanently"),
        ])
        XCTAssertEqual(controller.contextMenuItems(forEntryID: tree.gone.id).last?.keyEquivalent, "\u{8}")

        let (readOnly, _, _, readOnlyTree) = try await makeController(readOnly: true)
        XCTAssertEqual(identifiers(readOnly.contextMenuItems(forEntryID: readOnlyTree.work.entries[0].id)), [
            EntryRowActions.copyUsernameIdentifier, EntryRowActions.copyPasswordIdentifier,
        ])
        XCTAssertEqual(identifiers(readOnly.contextMenuItems(forEntryID: readOnlyTree.gone.id)), [
            EntryRowActions.copyUsernameIdentifier, EntryRowActions.copyPasswordIdentifier,
        ])
    }

    func testAClickInsideAMultipleSelectionOffersOnlyMove() async throws {
        let (controller, session, presentation, tree) = try await makeController()
        let ids = Set(tree.work.entries.prefix(2).map(\.id))
        session.workspace.setEntrySelection(ids)
        await settle()

        let bulk = controller.contextMenuItems(forRow: 0)
        XCTAssertEqual(identifiers(bulk), [EntryRowActions.moveIdentifier])
        XCTAssertEqual(bulk.first?.title, String(localized: "Move to Group…"))
        XCTAssertTrue(bulk.allSatisfy { controller.validateMenuItem($0) })
        XCTAssertEqual(identifiers(controller.contextMenuItems(forRow: 2)).first, EntryRowActions.copyUsernameIdentifier,
                       "A row outside the selection offers its own items")
        try perform(XCTUnwrap(bulk.first))
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.entries(ids).id)
    }

    func testMenuActionsSetThePresentationAndCopyThroughTheCommands() async throws {
        let (controller, session, presentation, tree) = try await makeController(configure: { _, entries in
            entries[1].username = "{REF:U@T:Account 00}"
            entries[2].tags = ["Shared"]
        })
        var copied: [String] = []
        controller.copyToClipboard = { copied.append($0) }
        let entry = tree.work.entries[1]
        func item(_ identifier: String, for entryID: UUID = entry.id) throws -> NSMenuItem {
            try XCTUnwrap(controller.contextMenuItems(forEntryID: entryID).first { $0.identifier?.rawValue == identifier })
        }

        try perform(item(EntryRowActions.copyUsernameIdentifier))
        XCTAssertEqual(copied, ["user0"], "Field references resolve as the copy command does")

        try perform(item(EntryRowActions.moveIdentifier))
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.entry(entry.id).id)
        presentation.pendingMove = nil

        try perform(item(EntryRowActions.deleteIdentifier))
        guard case .entry(let deletion) = presentation.pendingDeletion else { return XCTFail("No entry deletion") }
        XCTAssertEqual(deletion.entryID, entry.id)
        XCTAssertTrue(deletion.sendToRecycleBin)

        try perform(item(EntryRowActions.deletePermanentlyIdentifier, for: tree.gone.id))
        guard case .entry(let permanent) = presentation.pendingDeletion else { return XCTFail("No entry deletion") }
        XCTAssertFalse(permanent.sendToRecycleBin)

        try perform(item(EntryRowActions.restoreIdentifier, for: tree.gone.id))
        XCTAssertTrue(presentation.pendingMove != nil || session.isEntryInRecycleBin(entryID: tree.gone.id) == false)
        presentation.pendingMove = nil

        try perform(item(EntryRowActions.duplicateIdentifier))
        XCTAssertNotNil(presentation.commandEditor)
        XCTAssertFalse(presentation.selectsCreatedEntryInPlace, "The group column reveals the copy")
        presentation.commandEditor = nil

        session.searchText = "Account"
        await settle()
        try perform(item(EntryRowActions.duplicateIdentifier))
        XCTAssertNotNil(presentation.commandEditor)
        XCTAssertTrue(presentation.selectsCreatedEntryInPlace, "Search keeps the list and selects the copy in place")
        presentation.commandEditor = nil

        session.searchText = ""
        session.workspace.selectedTag = "Shared"
        await settle()
        let tagged = tree.work.entries[2]
        XCTAssertEqual(controller.tableView.numberOfRows, 1)
        try perform(item(EntryRowActions.deleteIdentifier, for: tagged.id))
        guard case .entry(let tagDeletion) = presentation.pendingDeletion else { return XCTFail("No tag deletion") }
        XCTAssertEqual(tagDeletion.entryID, tagged.id)
        XCTAssertTrue(tagDeletion.sendToRecycleBin)
        presentation.pendingDeletion?.performDeletion(viewModel: session)
        await settle()
        XCTAssertTrue(session.isEntryInRecycleBin(entryID: tagged.id))
        XCTAssertEqual(controller.tableView.numberOfRows, 0, "A recycled carrier leaves the tag list")
    }

    func testPasswordCopyWaitsForAuthenticationAndIsRejectedAfterALock() async throws {
        var current: DatabaseViewModel?
        let (controller, session, _, tree) = try await makeController(currentSession: { current })
        current = session
        var copied: [String] = []
        controller.copyToClipboard = { copied.append($0) }
        let authentication = SuspendedAuthentication()
        controller.authenticatePassword = authentication.authenticate
        let entry = tree.work.entries[2]
        let menuItem = try XCTUnwrap(controller.contextMenuItems(forEntryID: entry.id)
            .first { $0.identifier?.rawValue == EntryRowActions.copyPasswordIdentifier })

        let task = try XCTUnwrap(controller.copyPassword(entryID: entry.id))
        await authentication.waitUntilRequested()
        XCTAssertTrue(copied.isEmpty)
        XCTAssertFalse(controller.validateMenuItem(menuItem), "One prompt at a time")
        authentication.complete()
        await task.value
        XCTAssertEqual(copied, ["secret2"])

        current = nil
        XCTAssertNil(controller.copyPassword(entryID: entry.id), "A window that lost its session starts no prompt")
        current = session

        let locked = try XCTUnwrap(controller.copyPassword(entryID: entry.id))
        await authentication.waitUntilRequested()
        session.lockRequest(force: true)
        authentication.complete()
        await locked.value
        XCTAssertEqual(copied, ["secret2"], "A lock during the prompt discloses nothing")
    }

    func testAUsernameReferencingAPasswordIsMaskedAndCopiesOnlyAfterAuthentication() async throws {
        var current: DatabaseViewModel?
        let (controller, session, _, tree) = try await makeController(currentSession: { current }, configure: { _, entries in
            entries[1].username = "{REF:P@I:\(entries[0].id.kdbxHexString)}"
        })
        current = session
        var copied: [String] = []
        controller.copyToClipboard = { copied.append($0) }
        let authentication = SuspendedAuthentication()
        controller.authenticatePassword = authentication.authenticate
        let alias = tree.work.entries[1]

        let row = try XCTUnwrap(cell(controller, entryID: alias.id))
        XCTAssertEqual(row.usernameField.stringValue, String(repeating: "\u{2022}", count: 12))
        XCTAssertFalse(row.usernameField.stringValue.contains("secret0"))

        let task = try XCTUnwrap(controller.copyUsername(entryID: alias.id))
        await authentication.waitUntilRequested()
        XCTAssertTrue(copied.isEmpty, "Nothing reaches the clipboard before the prompt answers")
        authentication.complete()
        await task.value
        XCTAssertEqual(copied, ["secret0"])

        let locked = try XCTUnwrap(controller.copyUsername(entryID: alias.id))
        await authentication.waitUntilRequested()
        session.lockRequest(force: true)
        authentication.complete()
        await locked.value
        XCTAssertEqual(copied, ["secret0"], "A lock during the prompt discloses nothing")
    }

    // MARK: - Cells

    func testCellsCarryIdentifiersLabelsGlyphsAndResolvedUsernames() async throws {
        let now = Date()
        let (controller, session, _, tree) = try await makeController(configure: { _, entries in
            entries[0].username = "{REF:U@T:Account 01}"
            entries[1].expires = true
            entries[1].expiryTime = now.addingTimeInterval(-60)
            entries[1].totpConfig = TOTPConfig(secret: EncryptedValue(sealedData: Data([0]), hasValue: true))
            entries[1].customFields = [
                PasskeyCredential.credentialIDKey: "Y3JlZA",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice",
                PasskeyCredential.userHandleKey: "aGFuZGxl",
            ]
            entries[1].passkeyPrivateKey = EncryptedValue(sealedData: Data([0]), hasValue: true)
            entries[2].username = ""
        })
        let first = try XCTUnwrap(cell(controller, entryID: tree.work.entries[0].id))
        let second = try XCTUnwrap(cell(controller, entryID: tree.work.entries[1].id))
        let third = try XCTUnwrap(cell(controller, entryID: tree.work.entries[2].id))

        XCTAssertEqual(first.textField?.accessibilityIdentifier(), "entry.navlink")
        XCTAssertEqual(first.accessibilityLabel(), "Account 00")
        XCTAssertEqual(first.usernameField.stringValue, "user1")
        XCTAssertTrue(third.usernameField.isHidden)
        XCTAssertNotNil(first.imageView?.image)
        XCTAssertTrue(first.expiredGlyph.isHidden && first.passkeyGlyph.isHidden && first.verificationCodeGlyph.isHidden)
        XCTAssertFalse(second.expiredGlyph.isHidden || second.passkeyGlyph.isHidden || second.verificationCodeGlyph.isHidden)
        let glyphs = [second.expiredGlyph, second.passkeyGlyph, second.verificationCodeGlyph]
        XCTAssertEqual(glyphs.map(\.style), [.expired, .symbol("person.fill"), .symbol("timer")])
        XCTAssertEqual(second.expiredGlyph.intrinsicContentSize.height < MacEntryBadgeView.diameter, true,
                       "The EXPIRED pill is a short text capsule")
        XCTAssertGreaterThan(second.expiredGlyph.intrinsicContentSize.width, MacEntryBadgeView.diameter)
        XCTAssertEqual(second.passkeyGlyph.intrinsicContentSize,
                       NSSize(width: MacEntryBadgeView.diameter, height: MacEntryBadgeView.diameter))
        XCTAssertTrue(glyphs.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .image })
        XCTAssertEqual(glyphs.map { $0.accessibilityIdentifier() }, ["entry-row.expired", "entry-row.passkey", "entry-row.totp"])
        XCTAssertEqual(glyphs.map { $0.accessibilityLabel() ?? "" },
                       [String(localized: "Expired"), String(localized: "Has a passkey"),
                        String(localized: "Has a verification code")])
        XCTAssertEqual(first.folderField.accessibilityIdentifier(), "entry-row.folder")
        XCTAssertTrue(first.folderField.isHiddenOrHasHiddenAncestor, "A group lists no folder path")
        XCTAssertEqual(controller.tableView(controller.tableView, typeSelectStringFor: nil, row: 1), "Account 01")

        session.searchText = "Account"
        await settle()
        let found = try XCTUnwrap(cell(controller, entryID: tree.work.entries[0].id))
        XCTAssertEqual(found.textField?.accessibilityIdentifier(), "search.entry.navlink")
        XCTAssertFalse(found.folderField.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(found.folderField.stringValue, "Root › Work", "The root's name and the board's separator")
        XCTAssertEqual(found.folderRow.arrangedSubviews, [found.folderField], "No folder glyph")
        XCTAssertEqual(controller.tableView.accessibilityIdentifier(), "search.results")

        session.searchText = ""
        session.workspace.selectedTag = "Shared"
        await settle()
        XCTAssertEqual(controller.tableView.accessibilityIdentifier(), "", "No carriers leaves no list")
    }

    func testOffscreenRowsDoNotResolveFieldReferences() async throws {
        let (controller, session, _, tree) = try await makeController(count: 5_000, height: 400, configure: { _, entries in
            entries[4_999].username = "{REF:U@T:Account 00}"
        })
        XCTAssertEqual(controller.tableView.numberOfRows, 5_000)
        XCTAssertFalse(try hasBuiltFieldReferenceCache(session), "Only drawn rows resolve their usernames")

        let referencing = try XCTUnwrap(cell(controller, entryID: tree.work.entries[4_999].id))
        XCTAssertEqual(referencing.usernameField.stringValue, "user0")
        XCTAssertTrue(try hasBuiltFieldReferenceCache(session))
    }

    // MARK: - Empty states, result count, saving

    func testEmptyStatesAndTheSearchResultCount() async throws {
        let (controller, session, _, tree) = try await makeController(showsResultCount: true)
        XCTAssertTrue(controller.emptyView.isHidden)
        XCTAssertTrue(controller.resultCountField.isHidden)

        session.workspace.selectedGroupID = tree.other.id
        await settle()
        XCTAssertFalse(controller.emptyView.isHidden)
        XCTAssertTrue(controller.scrollView.isHidden)
        XCTAssertEqual(controller.emptyView.titleField.stringValue, String(localized: "No Entries"))
        XCTAssertEqual(controller.emptyView.messageField.stringValue, String(localized: "This group has no entries."))

        session.searchText = "zzz"
        await settle()
        XCTAssertEqual(controller.emptyView.titleField.stringValue, String(localized: "No Results"))
        XCTAssertEqual(controller.emptyView.accessibilityIdentifier(), "search.no-results")
        XCTAssertFalse(controller.resultCountField.isHidden)
        XCTAssertEqual(controller.resultCountField.accessibilityIdentifier(), "search.results.count")
        XCTAssertEqual(controller.resultCountField.stringValue, String(localized: "results:\(0)"))

        session.searchText = "Account"
        await settle()
        XCTAssertTrue(controller.emptyView.isHidden)
        XCTAssertFalse(controller.scrollView.isHidden)
        XCTAssertEqual(controller.resultCountField.stringValue, String(localized: "results:\(3)"))

        session.searchText = ""
        session.workspace.selectedCollection = .verificationCodes
        await settle()
        XCTAssertTrue(controller.resultCountField.isHidden)
        XCTAssertEqual(controller.emptyView.titleField.stringValue, String(localized: "No Verification Codes"))
        XCTAssertEqual(controller.emptyView.accessibilityIdentifier(), "")

        let (plain, plainSession, _, _) = try await makeController()
        plainSession.searchText = "Account"
        await settle()
        XCTAssertTrue(plain.resultCountField.isHidden, "Outside UI testing the count stays hidden")
    }

    func testSavingDisablesTheTableItsMenuAndTheBar() async throws {
        let gate = SaveGate()
        let (controller, session, _, tree) = try await makeController(save: { _, _, _, hash, _, _, _ in
            await gate.signalStarted()
            await gate.waitUntilOpen()
            return .saved(newSHA512: hash)
        })
        let menuItems = controller.contextMenuItems(forEntryID: tree.work.entries[0].id)
        session.workspace.setEntrySelection(Set(tree.work.entries.prefix(2).map(\.id)))
        try session.createGroup(named: "Draft", in: tree.other.id)
        await settle()
        XCTAssertTrue(controller.tableView.isEnabled)

        let save = try XCTUnwrap(DatabaseCommands(session: session).save())
        await gate.waitUntilStarted()
        await settle()
        XCTAssertTrue(session.isSaving)
        XCTAssertFalse(controller.tableView.isEnabled)
        XCTAssertTrue(menuItems.allSatisfy { controller.validateMenuItem($0) == false })
        XCTAssertFalse(controller.selectionBar.cancelButton.isEnabled)
        XCTAssertFalse(controller.selectionBar.moveButton.isEnabled)

        await gate.open()
        await save.value
        await settle()
        XCTAssertTrue(controller.tableView.isEnabled)
        XCTAssertTrue(controller.selectionBar.moveButton.isEnabled)
    }

    // MARK: - Verification codes

    func testCodeRowsShowOnlyInVerificationCodes() async throws {
        let clock = MacVerificationCodeClock(now: { Date(timeIntervalSince1970: 1_000_000_005) },
                                             generate: { _, _, _ in "123456" })
        let (controller, session, _, tree) = try await makeController(codeClock: clock, configure: { _, entries in
            entries[0].totpConfig = Self.fakeTOTP
            entries[2].totpConfig = Self.fakeTOTP
            entries[2].username = ""
        })
        let table = controller.tableView
        controller.viewDidAppear()
        XCTAssertNil(try XCTUnwrap(cell(controller, entryID: tree.work.entries[0].id)) as? MacVerificationCodeCellView)
        XCTAssertNil(controller.verificationCodeTimer, "A group shows no codes")

        session.workspace.selectedCollection = .verificationCodes
        await settle()
        XCTAssertEqual(titles(controller), ["Account 00", "Account 02"])
        XCTAssertEqual(table.delegate?.tableView?(table, heightOfRow: 0), MacEntryListViewController.verificationCodeRowHeight)
        let first = try XCTUnwrap(cell(controller, entryID: tree.work.entries[0].id) as? MacVerificationCodeCellView)
        let second = try XCTUnwrap(cell(controller, entryID: tree.work.entries[2].id) as? MacVerificationCodeCellView)
        XCTAssertEqual(first.codeField.stringValue, "123 456", "Grouped as the iOS code rows group it")
        XCTAssertEqual(first.usernameField.stringValue, "user0 · Root › Work")
        XCTAssertEqual(second.usernameField.stringValue, "Root › Work")
        XCTAssertTrue(first.folderRow.isHidden)
        XCTAssertTrue(first.verificationCodeGlyph.isHidden, "The code replaces the glyph")
        XCTAssertEqual(first.textField?.accessibilityIdentifier(), "entry.navlink")
        XCTAssertEqual(first.accessibilityLabel(), "Account 00")
        XCTAssertEqual(first.accessibilityValue() as? String, "1 2 3 4 5 6")
        XCTAssertFalse(first.codeField.isAccessibilityElement())
        XCTAssertEqual(first.copyButton.accessibilityIdentifier(), "verification-code-row.copy")
        XCTAssertEqual(first.copyButton.accessibilityLabel(), String(localized: "Copy Verification Code"))
        XCTAssertEqual(first.countdown.accessibilityLabel(), String(localized: "\(15) seconds remaining"))
        XCTAssertEqual(first.countdown.seconds, 15)

        session.workspace.selectedCollection = .allEntries
        await settle()
        XCTAssertNil(try XCTUnwrap(cell(controller, entryID: tree.work.entries[0].id)) as? MacVerificationCodeCellView)
        XCTAssertEqual(table.delegate?.tableView?(table, heightOfRow: 0), MacEntryListViewController.rowWithFolderHeight)

        let (readOnly, readOnlySession, _, readOnlyTree) = try await makeController(
            readOnly: true, codeClock: MacVerificationCodeClock(generate: { _, _, _ in "123456" }),
            configure: { _, entries in entries[1].totpConfig = Self.fakeTOTP }
        )
        readOnlySession.workspace.selectedCollection = .verificationCodes
        await settle()
        let readOnlyCell = try XCTUnwrap(cell(readOnly, entryID: readOnlyTree.work.entries[1].id)
            as? MacVerificationCodeCellView)
        XCTAssertEqual(readOnlyCell.codeField.stringValue, "123 456", "A read-only database shows codes, as the detail does")
    }

    func testOneCodeTimerRunsOnlyWhileTheCodesAreOnScreenAndUnlocked() async throws {
        let clock = MacVerificationCodeClock(generate: { _, _, _ in "123456" })
        let (controller, session, _, tree) = try await makeController(codeClock: clock, configure: { _, entries in
            for index in entries.indices { entries[index].totpConfig = Self.fakeTOTP }
        })
        session.workspace.selectedCollection = .verificationCodes
        await settle()
        XCTAssertNil(controller.verificationCodeTimer, "Not on screen yet")

        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        let timer = try XCTUnwrap(controller.verificationCodeTimer)
        XCTAssertTrue(timer.isValid)
        XCTAssertGreaterThan(clock.cachedCodeCount, 0)
        func codeCell() throws -> MacVerificationCodeCellView {
            try XCTUnwrap(cell(controller, entryID: tree.work.entries[0].id) as? MacVerificationCodeCellView)
        }
        func assertBlank(_ cell: MacVerificationCodeCellView, _ message: String) {
            XCTAssertNil(cell.display, message)
            XCTAssertEqual(cell.codeField.stringValue, "", message)
            XCTAssertNil(cell.accessibilityValue(), message)
        }
        let shown = try codeCell()
        XCTAssertEqual(shown.codeField.stringValue, "123 456")
        try replaceWork(in: session, tree: tree) { entries in
            for index in entries.indices { entries[index].totpConfig = Self.fakeTOTP }
            entries[0].title = "Account 00 renamed"
        }
        await settle()
        controller.viewDidAppear()
        XCTAssertTrue(controller.verificationCodeTimer === timer, "One timer per table")

        session.workspace.selectedCollection = .allEntries
        await settle()
        XCTAssertNil(controller.verificationCodeTimer)
        XCTAssertFalse(timer.isValid, "Leaving the codes stops the timer")
        XCTAssertEqual(clock.cachedCodeCount, 0)
        assertBlank(shown, "Leaving the codes blanks the cells, reusable ones included")

        session.workspace.selectedCollection = .verificationCodes
        await settle()
        let restarted = try XCTUnwrap(controller.verificationCodeTimer)
        controller.viewWillDisappear()
        XCTAssertNil(controller.verificationCodeTimer)
        XCTAssertFalse(restarted.isValid, "Disappearing stops the timer")
        XCTAssertEqual(clock.cachedCodeCount, 0)

        controller.viewDidAppear()
        let beforeLock = try XCTUnwrap(controller.verificationCodeTimer)
        let lockedCell = try codeCell()
        XCTAssertEqual(lockedCell.codeField.stringValue, "123 456")
        lockedCell.prepareForReuse()
        assertBlank(lockedCell, "Reuse blanks the cell")
        controller.tickVerificationCodes()
        XCTAssertEqual(lockedCell.codeField.stringValue, "123 456")
        session.lockRequest(force: true)
        await settle()
        XCTAssertNil(controller.verificationCodeTimer)
        XCTAssertFalse(beforeLock.isValid, "Lock stops the timer")
        XCTAssertEqual(clock.cachedCodeCount, 0, "Lock clears the codes shown")
        assertBlank(lockedCell, "Lock blanks the cells")
        controller.tickVerificationCodes()
        XCTAssertEqual(clock.cachedCodeCount, 0)
    }

    func testTheCodeTimerCannotOutliveItsTable() async throws {
        let (_, session, presentation, _) = try await makeController(configure: { _, entries in
            entries[0].totpConfig = Self.fakeTOTP
        })
        session.workspace.selectedCollection = .verificationCodes
        weak var released: MacEntryListViewController?
        var timer: Timer?
        autoreleasepool {
            let controller = MacEntryListViewController(
                session: session, presentation: presentation, currentSession: { session }, showsResultCount: false,
                codeClock: MacVerificationCodeClock(generate: { _, _, _ in "123456" }), loadFavicon: { _ in nil }
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidAppear()
            timer = controller.verificationCodeTimer
            released = controller
            window.contentViewController = nil
            window.close()
        }
        await settle()
        XCTAssertNil(released)
        XCTAssertEqual(timer?.isValid, false)
    }

    func testATickRedrawsOnlyTheVisibleCodeRows() async throws {
        var date = Date(timeIntervalSince1970: 1_000_000_005)
        var generated = 0
        let clock = MacVerificationCodeClock(now: { date }, generate: { _, _, _ in
            generated += 1
            return String(100_000 + generated)
        })
        let (controller, session, _, tree) = try await makeController(count: 60, height: 300, codeClock: clock,
                                                                      configure: { _, entries in
            for index in entries.indices { entries[index].totpConfig = Self.fakeTOTP }
        })
        session.workspace.selectedCollection = .verificationCodes
        await settle()
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        let table = controller.tableView
        let visible = table.rows(in: table.visibleRect)
        XCTAssertGreaterThan(visible.length, 0)
        XCTAssertLessThan(visible.length, 60)
        let firstEntry = tree.work.entries[visible.location].id
        let before = try XCTUnwrap(cell(controller, entryID: firstEntry) as? MacVerificationCodeCellView).codeField.stringValue

        let generatedBefore = generated
        controller.tickVerificationCodes()
        XCTAssertEqual(generated, generatedBefore, "Within one period the shown codes are reused")

        date = date.addingTimeInterval(30)
        controller.tickVerificationCodes()
        XCTAssertEqual(generated - generatedBefore, visible.length, "Only the rows in view are regenerated")
        let after = try XCTUnwrap(cell(controller, entryID: firstEntry) as? MacVerificationCodeCellView)
        XCTAssertNotEqual(after.codeField.stringValue, before)
        XCTAssertEqual(after.countdown.seconds, 15)

        table.scrollRowToVisible(59)
        controller.view.layoutSubtreeIfNeeded()
        controller.tickVerificationCodes()
        var available = 0
        table.enumerateAvailableRowViews { _, _ in available += 1 }
        XCTAssertLessThanOrEqual(clock.cachedCodeCount, available, "Rows scrolled away forget their codes")
        XCTAssertLessThan(clock.cachedCodeCount, 60)
    }

    func testTheCopyButtonCopiesTheCodeThroughTheCommand() async throws {
        var config: TOTPConfig?
        let (controller, session, _, tree) = try await makeController(configure: { key, entries in
            let totp = TOTPConfig(secret: try! EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: key))
            config = totp
            entries[1].totpConfig = totp
        })
        var copied: [String] = []
        controller.copyToClipboard = { copied.append($0) }
        session.workspace.selectedCollection = .verificationCodes
        await settle()
        let codeCell = try XCTUnwrap(cell(controller, entryID: tree.work.entries[1].id) as? MacVerificationCodeCellView)
        let key = try XCTUnwrap(session.sessionKey)
        let totp = try XCTUnwrap(config)

        let before = TOTPGenerator.generateCode(config: totp, sessionKey: key)
        codeCell.copyButton.performClick(nil)
        let after = TOTPGenerator.generateCode(config: totp, sessionKey: key)
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue([before, after].contains(copied[0]))
        XCTAssertNotEqual(copied.first, TOTPGenerator.placeholderCode)
        XCTAssertEqual(session.workspace.selectedEntryID, nil, "Copying does not select the row")
    }

    // MARK: - Helpers

    private static let fakeTOTP = TOTPConfig(secret: EncryptedValue(sealedData: Data([0]), hasValue: true))

    private func makeController(
        count: Int = 3,
        height: CGFloat = 600,
        readOnly: Bool = false,
        showsResultCount: Bool = false,
        currentSession: (@MainActor () -> DatabaseViewModel?)? = nil,
        codeClock: MacVerificationCodeClock = MacVerificationCodeClock(),
        save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) },
        configure: (SymmetricKey, inout [KPEntry]) -> Void = { _, _ in }
    ) async throws -> (MacEntryListViewController, DatabaseViewModel, MacWorkspacePresentation, Tree) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        reference.isReadOnly = readOnly
        let session = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: save,
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false }
        )
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        let key = try XCTUnwrap(session.sessionKey)
        let tree = try Tree(count: count, key: key) { configure(key, &$0) }
        session.draft = DatabaseDraft(rootGroup: tree.root, meta: KPMeta(recycleBin: .group(tree.recycleBin.id)),
                                      sessionKey: key)
        session.sortOrder = .title
        session.sortAscending = true
        session.workspace.selectedGroupID = tree.work.id
        let presentation = MacWorkspacePresentation()
        let controller = MacEntryListViewController(
            session: session,
            presentation: presentation,
            currentSession: currentSession ?? { session },
            showsResultCount: showsResultCount,
            codeClock: codeClock,
            loadFavicon: { _ in nil }
        )
        // Never ordered in: the table only needs a window to lay out its rows.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 320, height: height))
        addTeardownBlock { @MainActor in window.close() }
        controller.view.layoutSubtreeIfNeeded()
        await settle()
        return (controller, session, presentation, tree)
    }

    private func replaceWork(in session: DatabaseViewModel, tree: Tree, _ change: (inout [KPEntry]) -> Void) throws {
        let root = tree.root.deepCopy()
        let work = try XCTUnwrap(root.groups.first { $0.id == tree.work.id })
        change(&work.entries)
        session.draft = DatabaseDraft(rootGroup: root, meta: KPMeta(recycleBin: .group(tree.recycleBin.id)),
                                      sessionKey: try XCTUnwrap(session.sessionKey))
    }

    private func settle() async {
        for _ in 0..<4 { await Task { @MainActor in }.value }
    }

    private func key(_ keyCode: UInt16, _ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func perform(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
    }

    private func identifiers(_ items: [NSMenuItem]) -> [String] {
        items.compactMap { $0.identifier?.rawValue }
    }

    private func titles(_ controller: MacEntryListViewController) -> [String] {
        (0..<controller.tableView.numberOfRows).compactMap { controller.entryRow(at: $0)?.title }
    }

    private func rowIndex(_ controller: MacEntryListViewController, entryID: UUID) -> Int? {
        (0..<controller.tableView.numberOfRows).first { controller.entryRow(at: $0)?.id == entryID }
    }

    private func selectedIDs(_ controller: MacEntryListViewController) -> [UUID] {
        controller.tableView.selectedRowIndexes.compactMap { controller.entryRow(at: $0)?.id }
    }

    private func cell(_ controller: MacEntryListViewController, entryID: UUID) -> MacEntryCellView? {
        guard let row = rowIndex(controller, entryID: entryID) else { return nil }
        return controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacEntryCellView
    }

    private func hasBuiltFieldReferenceCache(_ viewModel: DatabaseViewModel) throws -> Bool {
        let cache = try XCTUnwrap(
            Mirror(reflecting: viewModel).children.first { $0.label == "fieldReferenceResolver" },
            "Resolver storage was renamed; update this probe."
        )
        return Mirror(reflecting: cache.value).children.isEmpty == false
    }

    @MainActor
    private final class SuspendedAuthentication {
        private var completion: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func authenticate() async {
            await withCheckedContinuation { continuation in
                completion = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilRequested() async {
            guard completion == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func complete() {
            completion?.resume()
            completion = nil
        }
    }
}
#endif
