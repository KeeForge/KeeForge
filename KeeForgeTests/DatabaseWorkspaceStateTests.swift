import Foundation
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseWorkspaceStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "DatabaseWorkspaceStateTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testSwitchingBetweenGroupAndTagClearsEntryButReselectingPreservesIt() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        let groupID = UUID()
        let entryID = UUID()
        workspace.selectedGroupID = groupID
        workspace.selectedEntryID = entryID
        workspace.selectedGroupID = groupID
        XCTAssertEqual(workspace.selectedEntryID, entryID)

        workspace.selectedTag = "Work"
        XCTAssertNil(workspace.selectedGroupID)
        XCTAssertNil(workspace.selectedEntryID)
        workspace.selectedEntryID = entryID
        workspace.selectedTag = "Work"
        XCTAssertEqual(workspace.selectedEntryID, entryID)

        workspace.selectedGroupID = groupID
        XCTAssertNil(workspace.selectedTag)
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testReconciliationPreservesTagUntilItsLastCarrierDisappears() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        let rootID = UUID()
        workspace.selectedTag = "Work"
        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { $0 == "Work" },
            entryIsSelectable: { _ in true }
        )
        XCTAssertNil(workspace.selectedGroupID)
        XCTAssertEqual(workspace.selectedTag, "Work")

        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false },
            entryIsSelectable: { _ in true }
        )
        XCTAssertNil(workspace.selectedTag)
        XCTAssertEqual(workspace.selectedGroupID, rootID)
    }

    func testMissingGroupFallsBackToRootAndClearsItsEntry() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        let rootID = UUID()
        workspace.selectedGroupID = UUID()
        workspace.selectedEntryID = UUID()
        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false },
            entryIsSelectable: { _ in true }
        )
        XCTAssertEqual(workspace.selectedGroupID, rootID)
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testReconciliationLeavesEntryForPresentationHostToDismiss() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        let rootID = UUID()
        let entryID = UUID()
        workspace.selectedGroupID = rootID
        workspace.selectedEntryID = entryID
        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false },
            entryIsSelectable: { _ in true }
        )
        XCTAssertEqual(workspace.selectedEntryID, entryID)

        workspace.reconcileSelection(
            visibleRootGroupID: nil,
            groupExists: { _ in false },
            tagExists: { _ in false },
            entryIsSelectable: { _ in true }
        )
        XCTAssertNil(workspace.selectedGroupID)
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testEntrySelectionTogglesEntriesAndOnlyEndsWhenAsked() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        let first = UUID()
        let second = UUID()

        workspace.toggleEntrySelection(first)
        XCTAssertNil(workspace.entrySelection, "a toggle outside selection mode must not start it")

        workspace.beginEntrySelection(with: first)
        workspace.toggleEntrySelection(second)
        XCTAssertEqual(workspace.entrySelection, [first, second])

        workspace.toggleEntrySelection(first)
        workspace.toggleEntrySelection(second)
        XCTAssertEqual(workspace.entrySelection, [], "deselecting the last entry keeps the mode")

        workspace.endEntrySelection()
        XCTAssertNil(workspace.entrySelection)
    }

    func testReconciliationDropsEntriesThatCanNoLongerBeSelected() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        let rootID = UUID()
        let kept = UUID()
        let gone = UUID()
        workspace.beginEntrySelection(with: kept)
        workspace.toggleEntrySelection(gone)

        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false },
            entryIsSelectable: { $0 == kept }
        )
        XCTAssertEqual(workspace.entrySelection, [kept])

        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false },
            entryIsSelectable: { _ in false }
        )
        XCTAssertEqual(workspace.entrySelection, [], "the user is still choosing")

        workspace.reconcileSelection(
            visibleRootGroupID: nil,
            groupExists: { _ in false },
            tagExists: { _ in false },
            entryIsSelectable: { _ in true }
        )
        XCTAssertNil(workspace.entrySelection)
    }

    func testLockClearsNavigationAndSelectionWithoutReplayingCommands() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        workspace.navigationPath = [.group(UUID()), .entry(UUID()), .tag("Work")]
        workspace.selectedTag = "Work"
        workspace.selectedEntryID = UUID()
        workspace.beginEntrySelection(with: UUID())
        workspace.isSearchActive = true
        workspace.viewMode = .tags
        workspace.viewMode = .recycleBin
        workspace.request(.newEntry)
        workspace.request(.newEntry)
        workspace.request(.searchFocus)
        workspace.request(.newGroup)
        workspace.request(.editEntry)
        workspace.request(.deleteSelection)

        workspace.resetForLock()

        XCTAssertTrue(workspace.navigationPath.isEmpty)
        XCTAssertNil(workspace.selectedGroupID)
        XCTAssertNil(workspace.selectedTag)
        XCTAssertNil(workspace.selectedEntryID)
        XCTAssertNil(workspace.entrySelection)
        XCTAssertFalse(workspace.isSearchActive)
        XCTAssertEqual(workspace.viewMode, .tags, "Locking leaves the recycle bin for the browsing view picked last")
        XCTAssertEqual(workspace.newEntryRequestID, 2)
        XCTAssertEqual(workspace.searchFocusRequestID, 1)
        XCTAssertEqual(workspace.newGroupRequestID, 1)
        XCTAssertEqual(workspace.editEntryRequestID, 1)
        XCTAssertEqual(workspace.deleteSelectionRequestID, 1)
    }

    func testANewSessionOpensOnTheBrowsingViewPickedLast() {
        XCTAssertEqual(DatabaseWorkspaceState(defaults: defaults).viewMode, .allEntries)

        DatabaseWorkspaceState(defaults: defaults).viewMode = .groups
        XCTAssertEqual(DatabaseWorkspaceState(defaults: defaults).viewMode, .groups)

        DatabaseWorkspaceState(defaults: defaults).viewMode = .recycleBin
        XCTAssertEqual(
            DatabaseWorkspaceState(defaults: defaults).viewMode,
            .groups,
            "The recycle bin is never where a database opens"
        )
    }

    func testAnUnreadableStoredViewOpensOnAllEntries() {
        for stored in ["no-such-view", DatabaseWorkspaceState.ViewMode.recycleBin.rawValue] {
            defaults.set(stored, forKey: DatabaseWorkspaceState.viewModeKey)
            XCTAssertEqual(DatabaseWorkspaceState(defaults: defaults).viewMode, .allEntries, stored)
        }
    }

    func testEveryNavigationInteractionReportsActivity() {
        let workspace = DatabaseWorkspaceState(defaults: defaults)
        var interactions = 0
        workspace.onInteraction = { interactions += 1 }
        let actions: [() -> Void] = [
            { workspace.navigationPath.append(.entry(UUID())) },
            { workspace.selectedGroupID = UUID() },
            { workspace.selectedTag = "Work" },
            { workspace.selectedEntryID = UUID() },
            { workspace.isSearchActive = true },
            { workspace.viewMode = .tags },
            { workspace.beginEntrySelection(with: UUID()) },
            { workspace.toggleEntrySelection(UUID()) },
            { workspace.endEntrySelection() },
        ]
        for action in actions {
            let before = interactions
            action()
            XCTAssertGreaterThan(interactions, before)
        }
    }
}
