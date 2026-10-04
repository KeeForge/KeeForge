import Foundation
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseWorkspaceStateTests: XCTestCase {
    func testSwitchingBetweenGroupAndTagClearsEntryButReselectingPreservesIt() {
        let workspace = DatabaseWorkspaceState()
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
        let workspace = DatabaseWorkspaceState()
        let rootID = UUID()
        workspace.selectedTag = "Work"
        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { $0 == "Work" }
        )
        XCTAssertNil(workspace.selectedGroupID)
        XCTAssertEqual(workspace.selectedTag, "Work")

        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false }
        )
        XCTAssertNil(workspace.selectedTag)
        XCTAssertEqual(workspace.selectedGroupID, rootID)
    }

    func testMissingGroupFallsBackToRootAndClearsItsEntry() {
        let workspace = DatabaseWorkspaceState()
        let rootID = UUID()
        workspace.selectedGroupID = UUID()
        workspace.selectedEntryID = UUID()
        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false }
        )
        XCTAssertEqual(workspace.selectedGroupID, rootID)
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testReconciliationLeavesEntryForPresentationHostToDismiss() {
        let workspace = DatabaseWorkspaceState()
        let rootID = UUID()
        let entryID = UUID()
        workspace.selectedGroupID = rootID
        workspace.selectedEntryID = entryID
        workspace.reconcileSelection(
            visibleRootGroupID: rootID,
            groupExists: { $0 == rootID },
            tagExists: { _ in false }
        )
        XCTAssertEqual(workspace.selectedEntryID, entryID)

        workspace.reconcileSelection(
            visibleRootGroupID: nil,
            groupExists: { _ in false },
            tagExists: { _ in false }
        )
        XCTAssertNil(workspace.selectedGroupID)
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testLockClearsNavigationAndSelectionWithoutReplayingCommands() {
        let workspace = DatabaseWorkspaceState()
        workspace.navigationPath = [.group(UUID()), .entry(UUID()), .tag("Work")]
        workspace.selectedTag = "Work"
        workspace.selectedEntryID = UUID()
        workspace.isSearchActive = true
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
        XCTAssertFalse(workspace.isSearchActive)
        XCTAssertEqual(workspace.viewMode, DatabaseWorkspaceState.initialViewMode())
        XCTAssertEqual(workspace.newEntryRequestID, 2)
        XCTAssertEqual(workspace.searchFocusRequestID, 1)
        XCTAssertEqual(workspace.newGroupRequestID, 1)
        XCTAssertEqual(workspace.editEntryRequestID, 1)
        XCTAssertEqual(workspace.deleteSelectionRequestID, 1)
    }

    func testEveryNavigationInteractionReportsActivity() {
        let workspace = DatabaseWorkspaceState()
        var interactions = 0
        workspace.onInteraction = { interactions += 1 }
        let actions: [() -> Void] = [
            { workspace.navigationPath.append(.entry(UUID())) },
            { workspace.selectedGroupID = UUID() },
            { workspace.selectedTag = "Work" },
            { workspace.selectedEntryID = UUID() },
            { workspace.isSearchActive = true },
            { workspace.viewMode = .tags },
        ]
        for action in actions {
            let before = interactions
            action()
            XCTAssertGreaterThan(interactions, before)
        }
    }
}
