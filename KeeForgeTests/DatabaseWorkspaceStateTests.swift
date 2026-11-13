import CryptoKit
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
        let workspace = DatabaseWorkspaceState()
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
        let workspace = DatabaseWorkspaceState()
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
        let workspace = DatabaseWorkspaceState()
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
        let workspace = DatabaseWorkspaceState()
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
        let workspace = DatabaseWorkspaceState()
        workspace.navigationPath = [.collection(.tags), .tag("Work"), .entry(UUID())]
        workspace.selectedTag = "Work"
        workspace.selectedEntryID = UUID()
        workspace.beginEntrySelection(with: UUID())
        workspace.isSearchActive = true
        workspace.request(.newEntry)
        workspace.request(.newEntry)
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
        XCTAssertEqual(workspace.newEntryRequestID, 2)
        XCTAssertEqual(workspace.newGroupRequestID, 1)
        XCTAssertEqual(workspace.editEntryRequestID, 1)
        XCTAssertEqual(workspace.deleteSelectionRequestID, 1)
    }

    func testSelectingFromTheMoreMenuStartsWithNothingPicked() {
        let workspace = DatabaseWorkspaceState()
        workspace.beginEntrySelection()
        XCTAssertEqual(workspace.entrySelection, [])
        XCTAssertNil(workspace.commandEntryID, "Single-entry commands pause while entries are being picked")

        let entryID = UUID()
        workspace.toggleEntrySelection(entryID)
        XCTAssertEqual(workspace.entrySelection, [entryID])
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
            { workspace.navigationPath.append(.collection(.recycleBin)) },
            { workspace.beginEntrySelection(with: UUID()) },
            { workspace.beginEntrySelection() },
            { workspace.toggleEntrySelection(UUID()) },
            { workspace.endEntrySelection() },
        ]
        for action in actions {
            let before = interactions
            action()
            XCTAssertGreaterThan(interactions, before)
        }
    }
    // MARK: - Layout changes (iPhone Duo open/close, iPad resize)

    func testOpeningToRegularMovesTheShownEntryIntoTheDetailColumn() {
        let workspace = DatabaseWorkspaceState()
        let groupID = UUID()
        let entryID = UUID()
        workspace.navigationPath = [.group(groupID), .entry(entryID)]

        workspace.adaptNavigation(toRegularLayout: true)

        XCTAssertEqual(workspace.navigationPath, [.group(groupID)])
        XCTAssertEqual(workspace.selectedEntryID, entryID)
    }

    func testOpeningToRegularDropsEntriesTheSidebarCannotShow() {
        let workspace = DatabaseWorkspaceState()
        let firstEntryID = UUID()
        workspace.navigationPath = [.entry(firstEntryID), .tag("Work")]
        workspace.selectedEntryID = UUID()

        workspace.adaptNavigation(toRegularLayout: true)

        XCTAssertEqual(workspace.navigationPath, [.tag("Work")])
        XCTAssertNil(workspace.selectedEntryID, "A stale selection must not resurface in the detail column")
    }

    func testClosingToCompactPushesTheSelectedEntry() {
        let workspace = DatabaseWorkspaceState()
        let entryID = UUID()
        workspace.navigationPath = [.collection(.tags), .tag("Work")]
        workspace.selectedEntryID = entryID

        workspace.adaptNavigation(toRegularLayout: false)

        XCTAssertEqual(workspace.navigationPath, [.collection(.tags), .tag("Work"), .entry(entryID)])
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testOpenAndCloseRoundTripKeepsThePlace() {
        let workspace = DatabaseWorkspaceState()
        let path: [DatabaseRoute] = [.group(UUID()), .group(UUID()), .entry(UUID())]
        workspace.navigationPath = path

        workspace.adaptNavigation(toRegularLayout: true)
        workspace.adaptNavigation(toRegularLayout: false)

        XCTAssertEqual(workspace.navigationPath, path)
    }

    func testLayoutChangeKeepsSearchSelectionAndTheOpenEditor() {
        let workspace = DatabaseWorkspaceState()
        let entryID = UUID()
        let editor = EntryEditViewModel(createIn: UUID())
        workspace.isSearchActive = true
        workspace.beginEntrySelection(with: entryID)
        workspace.present(.entry(editor))

        workspace.adaptNavigation(toRegularLayout: true)
        workspace.adaptNavigation(toRegularLayout: false)

        XCTAssertEqual(workspace.navigationPath, [.editor])
        XCTAssertTrue(workspace.isSearchActive)
        XCTAssertEqual(workspace.entrySelection, [entryID])
        XCTAssertTrue(workspace.entryEditor === editor, "The editor and its unsaved changes outlive the layout")
    }

    // MARK: - Editors

    func testAnOpenEditorKeepsItsPlaceAgainstASecondOne() {
        let workspace = DatabaseWorkspaceState()
        let first = EntryEditViewModel(createIn: UUID())
        workspace.present(.entry(first))

        workspace.present(.entry(EntryEditViewModel(createIn: UUID())))
        workspace.present(.group(GroupEditViewModel(editing: KPGroup(id: UUID(), name: "Work"), isHiddenFromAutoFill: false)))

        XCTAssertTrue(workspace.entryEditor === first)
    }

    func testCompactCreateReplacesTheEditorWithTheNewEntry() {
        let workspace = DatabaseWorkspaceState()
        let groupID = UUID()
        let createdID = UUID()
        workspace.present(.entry(EntryEditViewModel(createIn: groupID)))
        workspace.navigationPath = [.group(groupID), .editor]

        workspace.finishCompactEntryEditor(.created(createdID))

        XCTAssertNil(workspace.openEditor)
        XCTAssertEqual(workspace.navigationPath, [.group(groupID), .entry(createdID)])
    }

    func testCompactDeletePopsTheEditorAndTheDeletedEntry() {
        let workspace = DatabaseWorkspaceState()
        let groupID = UUID()
        let entry = KPEntry(title: "Twitter")
        workspace.present(.entry(EntryEditViewModel(editing: entry, sessionKey: SymmetricKey(size: .bits256))))
        workspace.navigationPath = [.group(groupID), .entry(entry.id), .editor]

        workspace.finishCompactEntryEditor(.deleted)

        XCTAssertEqual(workspace.navigationPath, [.group(groupID)])
    }

    func testCompactSaveOnlyPopsTheEditor() {
        let workspace = DatabaseWorkspaceState()
        let entry = KPEntry(title: "Twitter")
        workspace.present(.entry(EntryEditViewModel(editing: entry, sessionKey: SymmetricKey(size: .bits256))))
        workspace.navigationPath = [.entry(entry.id), .editor]

        workspace.finishCompactEntryEditor(.saved)

        XCTAssertEqual(workspace.navigationPath, [.entry(entry.id)])
    }

    func testLockClosesTheEditorAndItsScreen() {
        let workspace = DatabaseWorkspaceState()
        workspace.present(.entry(EntryEditViewModel(createIn: UUID())))
        workspace.navigationPath = [.editor]

        workspace.resetForLock()

        XCTAssertNil(workspace.openEditor)
        XCTAssertEqual(workspace.navigationPath, [])
    }

    func testEditingAnEntryRoundTripsItsScreenAndEditor() throws {
        let workspace = DatabaseWorkspaceState()
        let groupID = UUID()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(title: "Twitter")
        workspace.navigationPath = [.group(groupID), .entry(entry.id)]
        workspace.present(.entry(EntryEditViewModel(editing: entry, sessionKey: sessionKey)))
        workspace.navigationPath.append(.editor)

        workspace.adaptNavigation(toRegularLayout: true)
        XCTAssertEqual(workspace.navigationPath, [.group(groupID)], "The regular sidebar holds neither the entry nor its editor")
        XCTAssertEqual(workspace.selectedEntryID, entry.id)

        workspace.adaptNavigation(toRegularLayout: false)
        XCTAssertEqual(workspace.navigationPath, [.group(groupID), .entry(entry.id), .editor])
    }

    func testClosingTheEditorPopsItsScreen() {
        let workspace = DatabaseWorkspaceState()
        let groupID = UUID()
        workspace.present(.entry(EntryEditViewModel(createIn: groupID)))
        workspace.navigationPath = [.group(groupID), .editor]

        workspace.finishCompactEntryEditor(.cancelled)

        XCTAssertNil(workspace.openEditor)
        XCTAssertEqual(workspace.navigationPath, [.group(groupID)])
    }
}
