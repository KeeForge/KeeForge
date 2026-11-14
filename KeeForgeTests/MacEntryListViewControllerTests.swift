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
        XCTAssertEqual(controller.contextMenuItems(forEntryID: entry.id).map(\.title), [
            String(localized: "Copy Username"), String(localized: "Copy Password"), String(localized: "Duplicate"),
            String(localized: "Move to Group"), String(localized: "Delete"),
        ])
        XCTAssertTrue(controller.contextMenuItems(forEntryID: entry.id).allSatisfy { controller.validateMenuItem($0) })
        XCTAssertFalse(identifiers(controller.contextMenuItems(forEntryID: entry.id))
            .contains(EntryRowActions.selectIdentifier), "Native multi-select replaces Select Entries")

        XCTAssertEqual(identifiers(controller.contextMenuItems(forEntryID: tree.gone.id)), [
            EntryRowActions.copyUsernameIdentifier, EntryRowActions.copyPasswordIdentifier,
            EntryRowActions.restoreIdentifier, EntryRowActions.deletePermanentlyIdentifier,
        ])
        XCTAssertEqual(controller.contextMenuItems(forEntryID: tree.gone.id).last?.title,
                       String(localized: "Delete Permanently"))

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
        XCTAssertEqual(bulk.first?.title, String(localized: "Move to Group"))
        XCTAssertTrue(bulk.allSatisfy { controller.validateMenuItem($0) })
        XCTAssertEqual(identifiers(controller.contextMenuItems(forRow: 2)).first, EntryRowActions.copyUsernameIdentifier,
                       "A row outside the selection offers its own items")
        try perform(XCTUnwrap(bulk.first))
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.entries(ids).id)
    }

    func testMenuActionsSetThePresentationAndCopyThroughTheCommands() async throws {
        let (controller, session, presentation, tree) = try await makeController(configure: { _, entries in
            entries[1].username = "{REF:U@T:Account 00}"
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
        let glyphs: [NSImageView] = [second.expiredGlyph, second.passkeyGlyph, second.verificationCodeGlyph]
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
        XCTAssertEqual(found.folderField.stringValue, session.folderPath(forEntryID: tree.work.entries[0].id))
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

    // MARK: - Helpers

    private func makeController(
        count: Int = 3,
        height: CGFloat = 600,
        readOnly: Bool = false,
        showsResultCount: Bool = false,
        currentSession: (@MainActor () -> DatabaseViewModel?)? = nil,
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
