#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceCommandsTests: XCTestCase {
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

    /// Root ▸ Work (two entries, a Servers subgroup), Root ▸ Empty, and a
    /// Recycle Bin holding Gone and an Old subgroup.
    private struct Tree {
        let first: KPEntry
        let second: KPEntry
        let gone: KPEntry
        let work: KPGroup
        let servers: KPGroup
        let empty: KPGroup
        let recycleBin: KPGroup
        let root: KPGroup

        init(key: SymmetricKey) throws {
            first = KPEntry(title: "First", username: "one", password: try EncryptedValue.encrypt("1", using: key))
            second = KPEntry(title: "Second", username: "two", password: try EncryptedValue.encrypt("2", using: key))
            gone = KPEntry(title: "Gone", username: "old", password: try EncryptedValue.encrypt("3", using: key))
            servers = KPGroup(name: "Servers")
            work = KPGroup(name: "Work", entries: [first, second], groups: [servers])
            empty = KPGroup(name: "Empty")
            recycleBin = KPGroup(name: "Recycle Bin", entries: [gone], groups: [KPGroup(name: "Old", groups: [KPGroup(name: "Older")])])
            root = KPGroup(name: "Root", groups: [work, empty, recycleBin], recycleBinUUID: recycleBin.id)
        }
    }

    func testNoTargetOrALockedSessionDisablesEveryCommand() async throws {
        let (session, presentation, _) = try await makeSession()
        assertDisabled(MacWorkspaceCommands(session: nil, presentation: presentation))
        XCTAssertTrue(MacWorkspaceCommands(session: session, presentation: presentation).canShowCollection)

        session.lockRequest(force: true)
        assertDisabled(MacWorkspaceCommands(session: session, presentation: presentation))
        MacWorkspaceCommands(session: session, presentation: presentation).showDatabaseSettings()
        XCTAssertFalse(presentation.isShowingDatabaseDetails)
    }

    func testLibraryCommandsSelectTheCollectionAsTheSidebarDoes() async throws {
        let (session, presentation, tree) = try await makeSession()
        let commands = MacWorkspaceCommands(session: session, presentation: presentation)
        XCTAssertFalse(commands.isShowing(.allEntries))

        commands.show(.verificationCodes)
        XCTAssertEqual(session.workspace.selectedCollection, .verificationCodes)
        XCTAssertNil(session.workspace.selectedGroupID)
        XCTAssertTrue(commands.isShowing(.verificationCodes))
        commands.show(.allEntries)
        XCTAssertTrue(commands.isShowing(.allEntries))
        XCTAssertFalse(commands.isShowing(.verificationCodes))
        commands.show(.passkeys)
        XCTAssertTrue(commands.isShowing(.passkeys))
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .collection(.passkeys))
        session.workspace.selectedGroupID = tree.work.id
        XCTAssertFalse(commands.isShowing(.allEntries))
    }

    func testDuplicateFollowsTheRowMenuGateAndSelectsInPlaceInSearch() async throws {
        let (session, presentation, tree) = try await makeSession()
        let commands = MacWorkspaceCommands(session: session, presentation: presentation)
        XCTAssertFalse(commands.canDuplicate, "Nothing selected")

        session.workspace.selectedEntryID = tree.first.id
        XCTAssertTrue(commands.canDuplicate)
        commands.duplicate()
        XCTAssertNotNil(presentation.commandEditor)
        XCTAssertFalse(presentation.selectsCreatedEntryInPlace, "The group column reveals the copy")
        XCTAssertFalse(commands.canDuplicate, "One editor at a time")
        presentation.commandEditor = nil

        session.searchText = "First"
        session.workspace.selectedEntryID = tree.first.id
        commands.duplicate()
        XCTAssertTrue(presentation.selectsCreatedEntryInPlace)
        presentation.commandEditor = nil
        session.searchText = ""

        session.workspace.setEntrySelection([tree.first.id, tree.second.id])
        XCTAssertFalse(commands.canDuplicate, "Several picked entries are not one entry")
        session.workspace.endEntrySelection()
        session.workspace.selectedGroupID = tree.recycleBin.id
        session.workspace.selectedEntryID = tree.gone.id
        XCTAssertFalse(commands.canDuplicate, "A deleted entry comes back through Restore")
        commands.duplicate()
        XCTAssertNil(presentation.commandEditor)

        let (readOnly, readOnlyPresentation, readOnlyTree) = try await makeSession(readOnly: true)
        readOnly.workspace.selectedEntryID = readOnlyTree.first.id
        XCTAssertFalse(MacWorkspaceCommands(session: readOnly, presentation: readOnlyPresentation).canDuplicate)
    }

    func testMoveToGroupMovesThePickedEntriesOrTheSelectedOne() async throws {
        let (session, presentation, tree) = try await makeSession()
        let commands = MacWorkspaceCommands(session: session, presentation: presentation)
        XCTAssertFalse(commands.canMoveToGroup)

        session.workspace.selectedEntryID = tree.first.id
        commands.moveToGroup()
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.entry(tree.first.id).id)
        presentation.pendingMove = nil

        let picked: Set<UUID> = [tree.first.id, tree.second.id]
        session.workspace.setEntrySelection(picked)
        commands.moveToGroup()
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.entries(picked).id)
        presentation.pendingMove = nil
        session.workspace.setEntrySelection([])
        XCTAssertFalse(commands.canMoveToGroup, "Selection mode with nothing picked")
        session.workspace.endEntrySelection()

        session.workspace.selectedGroupID = tree.recycleBin.id
        session.workspace.selectedEntryID = tree.gone.id
        XCTAssertFalse(commands.canMoveToGroup, "A deleted entry comes back through Restore")

        let (readOnly, readOnlyPresentation, readOnlyTree) = try await makeSession(readOnly: true)
        readOnly.workspace.selectedEntryID = readOnlyTree.first.id
        XCTAssertFalse(MacWorkspaceCommands(session: readOnly, presentation: readOnlyPresentation).canMoveToGroup)
    }

    func testSortCommandsWriteTheSessionAndDimWhileTheListIsEmpty() async throws {
        let (session, presentation, tree) = try await makeSession()
        let commands = MacWorkspaceCommands(session: session, presentation: presentation)
        XCTAssertTrue(commands.canSort)
        commands.setSortOrder(.modifiedDate)
        commands.setSortAscending(false)
        XCTAssertEqual(session.sortOrder, .modifiedDate)
        XCTAssertFalse(session.sortAscending)

        session.workspace.selectedGroupID = tree.empty.id
        XCTAssertFalse(commands.canSort)
        commands.setSortOrder(.title)
        XCTAssertEqual(session.sortOrder, .modifiedDate, "A dimmed command does nothing")
    }

    func testExpandAndCollapseAllGroupsDriveTheSidebarsFoldedGroups() async throws {
        let (session, presentation, tree) = try await makeSession()
        let commands = MacWorkspaceCommands(session: session, presentation: presentation)
        let collapsible = MacSidebarSnapshot.make(session: session).collapsibleGroupIDs
        XCTAssertTrue(collapsible.isSuperset(of: [tree.root.id, tree.work.id]))
        XCTAssertFalse(collapsible.contains(tree.recycleBin.id), "Deleted Entries has no subgroups to fold")
        XCTAssertFalse(collapsible.contains(tree.servers.id), "A group without subgroups has nothing to fold")
        XCTAssertFalse(commands.canExpandAllGroups)
        XCTAssertTrue(commands.canCollapseAllGroups)

        commands.collapseAllGroups()
        XCTAssertEqual(presentation.collapsedGroupIDs, collapsible)
        XCTAssertFalse(commands.canCollapseAllGroups)
        XCTAssertTrue(commands.canExpandAllGroups)

        commands.expandAllGroups()
        XCTAssertEqual(presentation.collapsedGroupIDs, [])
        presentation.collapsedGroupIDs = [tree.work.id]
        XCTAssertTrue(commands.canExpandAllGroups)
        XCTAssertTrue(commands.canCollapseAllGroups)
    }

    func testSyncNowIsDimmedForALocalDatabaseAndSettingsOpensTheDetails() async throws {
        let (session, presentation, _) = try await makeSession()
        let commands = MacWorkspaceCommands(session: session, presentation: presentation)
        XCTAssertFalse(session.databaseReference.isCloudBacked)
        XCTAssertFalse(commands.canSyncNow, "Sync Now is dimmed for a database stored on this Mac")
        XCTAssertNil(commands.syncNow())

        XCTAssertTrue(commands.canShowDatabaseSettings)
        commands.showDatabaseSettings()
        XCTAssertTrue(presentation.isShowingDatabaseDetails)
    }

    // MARK: - Helpers

    private func assertDisabled(_ commands: MacWorkspaceCommands, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(commands.canShowCollection, file: file, line: line)
        XCTAssertFalse(commands.isShowing(.allEntries), file: file, line: line)
        XCTAssertFalse(commands.canDuplicate, file: file, line: line)
        XCTAssertFalse(commands.canMoveToGroup, file: file, line: line)
        XCTAssertFalse(commands.canSort, file: file, line: line)
        XCTAssertFalse(commands.canCollapseAllGroups, file: file, line: line)
        XCTAssertFalse(commands.canSyncNow, file: file, line: line)
        XCTAssertFalse(commands.canShowDatabaseSettings, file: file, line: line)
    }

    private func makeSession(readOnly: Bool = false) async throws -> (DatabaseViewModel, MacWorkspacePresentation, Tree) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        reference.isReadOnly = readOnly
        let session = DatabaseViewModel(databaseReference: reference,
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        let key = try XCTUnwrap(session.sessionKey)
        let tree = try Tree(key: key)
        session.draft = DatabaseDraft(rootGroup: tree.root, meta: KPMeta(recycleBin: .group(tree.recycleBin.id)),
                                      sessionKey: key)
        session.workspace.selectedGroupID = tree.work.id
        return (session, MacWorkspacePresentation(), tree)
    }
}
#endif
