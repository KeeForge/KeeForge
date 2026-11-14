#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspacePresentationTests: XCTestCase {
    func testNewEntryUsesSelectionThenVisibleRootAndRefusesUnavailableTargets() async throws {
        let group = KPGroup(name: "Selected")
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [group]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedGroupID = group.id
        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.commandEditor?.mode, .create(parentGroupID: group.id))

        presentation.commandEditor = nil
        database.workspace.selectedGroupID = nil
        let rootID = try XCTUnwrap(database.visibleRootGroupID)
        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.commandEditor?.mode, .create(parentGroupID: rootID))

        presentation.commandEditor = nil
        database.workspace.selectedCollection = .verificationCodes
        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.commandEditor?.mode, .create(parentGroupID: rootID), "A collection creates in the root")

        presentation.commandEditor = nil
        database.workspace.selectedGroupID = UUID()
        presentation.beginNewEntry(in: database)
        XCTAssertNil(presentation.commandEditor, "A vanished target must not open an unusable editor")

        database.lock()
        presentation.beginNewEntry(in: database)
        XCTAssertNil(presentation.commandEditor)
        let readOnly = try await makeDatabase(readOnly: true)
        defer { readOnly.lock() }
        presentation.beginNewEntry(in: readOnly)
        XCTAssertNil(presentation.commandEditor)
    }

    func testEntryRequestsKeepTheOpenEditorAndItsUnsavedFields() async throws {
        let entry = KPEntry(title: "Original")
        let database = try await makeDatabase(root: KPGroup(name: "Root", entries: [entry]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedEntryID = entry.id
        presentation.beginSelectedEntryEdit(in: database)
        let editor = try XCTUnwrap(presentation.commandEditor)
        XCTAssertEqual(editor.mode, .edit(entryID: entry.id))
        editor.title = "Unsaved edit"

        presentation.beginNewEntry(in: database)
        presentation.beginEntryEdit(entryID: entry.id, in: database)
        let duplicate = EntryEditViewModel(createIn: try XCTUnwrap(database.visibleRootGroupID))
        presentation.beginEntryDuplicate(duplicate)
        XCTAssertTrue(presentation.commandEditor === editor)
        XCTAssertEqual(editor.title, "Unsaved edit")

        presentation.commandEditor = nil
        database.workspace.beginEntrySelection(with: entry.id)
        presentation.beginSelectedEntryEdit(in: database)
        XCTAssertNil(presentation.commandEditor, "Bulk selection has no single-entry edit target")
        database.workspace.endEntrySelection()
        presentation.beginEntryDuplicate(duplicate)
        XCTAssertTrue(presentation.commandEditor === duplicate)
    }

    func testADuplicateFromAListAcrossGroupsSelectsTheCopyInPlaceAndOthersRevealIt() async throws {
        let entry = KPEntry(title: "Original")
        let group = KPGroup(name: "Work", entries: [entry])
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [group]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let duplicate = EntryEditViewModel(createIn: group.id)

        database.workspace.selectedTag = "Shared"
        presentation.beginEntryDuplicate(duplicate, selectingInPlace: true)
        XCTAssertTrue(presentation.selectsCreatedEntryInPlace)
        presentation.showCreatedEntry(entry.id, in: database)
        XCTAssertEqual(database.workspace.selectedTag, "Shared", "The tag browser stays")
        XCTAssertEqual(database.workspace.selectedEntryID, entry.id)
        presentation.commandEditor = nil
        XCTAssertFalse(presentation.selectsCreatedEntryInPlace, "The placement ends with its editor")

        presentation.beginEntryDuplicate(duplicate)
        XCTAssertFalse(presentation.selectsCreatedEntryInPlace)
        presentation.showCreatedEntry(entry.id, in: database)
        XCTAssertNil(database.workspace.selectedTag)
        XCTAssertEqual(database.workspace.selectedGroupID, group.id, "A group-column duplicate is revealed")
        XCTAssertEqual(database.workspace.selectedEntryID, entry.id)
    }

    func testDeletionSnapshotsTheSelectedEntryOrGroupWithoutMutatingTheDraft() async throws {
        let entry = KPEntry(title: "Active")
        let recycledEntry = KPEntry(title: "Recycled")
        let child = KPGroup(name: "Nested")
        let group = KPGroup(name: "Active group", entries: [entry], groups: [child])
        let recycledGroup = KPGroup(name: "Recycled group", entries: [recycledEntry])
        let bin = KPGroup(name: "Recycle Bin", groups: [recycledGroup])
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [group, bin], recycleBinUUID: bin.id))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let revision = database.contentRevision

        for (selectedGroup, selectedEntry, recycles) in [(group, entry, true), (recycledGroup, recycledEntry, false)] {
            database.workspace.selectedGroupID = selectedGroup.id
            presentation.beginSelectionDeletion(in: database)
            guard case .group(let pendingGroup) = presentation.pendingDeletion else {
                return XCTFail("Expected the selected group's confirmation")
            }
            XCTAssertEqual(pendingGroup.groupID, selectedGroup.id)
            XCTAssertEqual(pendingGroup.groupName, selectedGroup.name)
            XCTAssertEqual(pendingGroup.entryCount, 1)
            XCTAssertEqual(pendingGroup.nestedGroupCount, recycles ? 1 : 0)
            XCTAssertEqual(pendingGroup.sendToRecycleBin, recycles)

            database.workspace.selectedEntryID = selectedEntry.id
            presentation.beginSelectionDeletion(in: database)
            guard case .entry(let pendingEntry) = presentation.pendingDeletion else {
                return XCTFail("The entry selection must take precedence over its group")
            }
            XCTAssertEqual(pendingEntry.entryID, selectedEntry.id)
            XCTAssertEqual(pendingEntry.sendToRecycleBin, recycles)
            XCTAssertNotNil(database.entry(withID: selectedEntry.id))
        }
        XCTAssertEqual(database.contentRevision, revision)
        XCTAssertFalse(database.isDirty)

        presentation.pendingDeletion = nil
        database.workspace.beginEntrySelection(with: entry.id)
        presentation.beginSelectionDeletion(in: database)
        XCTAssertNil(presentation.pendingDeletion)
        database.lock()
        presentation.beginSelectionDeletion(in: database)
        XCTAssertNil(presentation.pendingDeletion)
    }

    func testNewGroupResetsItsTargetAndRetainsTheFormOnFailure() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let missingParentID = UUID()
        presentation.beginNewGroup(parentID: missingParentID)
        presentation.newGroupName = "Keep this name"
        presentation.createGroup(named: presentation.newGroupName, in: database)
        XCTAssertTrue(presentation.isShowingNewGroupSheet)
        XCTAssertEqual(presentation.newGroupParentID, missingParentID)
        XCTAssertEqual(presentation.newGroupName, "Keep this name")
        XCTAssertNotNil(presentation.groupCreationErrorMessage)
        XCTAssertFalse(database.isDirty)

        presentation.beginNewGroup()
        XCTAssertTrue(presentation.isShowingNewGroupSheet)
        XCTAssertNil(presentation.newGroupParentID)
        XCTAssertEqual(presentation.newGroupName, "")
        XCTAssertNil(presentation.groupCreationErrorMessage)
        presentation.dismissNewGroup()
        XCTAssertFalse(presentation.isShowingNewGroupSheet)
    }

    func testNewGroupWithACollectionSelectedCreatesInTheVisibleRoot() async throws {
        let child = KPGroup(name: "Child")
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [child, KPGroup(name: "Sibling")]))
        defer { database.lock() }
        let rootID = try XCTUnwrap(database.visibleRootGroupID)
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedCollection = .allEntries
        presentation.beginNewGroup()
        presentation.createGroup(named: "From Collection", in: database)
        XCTAssertFalse(presentation.isShowingNewGroupSheet)
        let root = try XCTUnwrap(database.group(withID: rootID))
        XCTAssertTrue(root.groups.contains { $0.name == "From Collection" })
        XCTAssertEqual(database.group(withID: child.id)?.groups.isEmpty, true)
    }

    func testAWrapperHoldingOnlyTheRecycleBinStaysTheMacWorkspaceRoot() async throws {
        let recycleBin = KPGroup(name: "Recycle Bin")
        let root = KPGroup(name: "Root", groups: [recycleBin], recycleBinUUID: recycleBin.id)
        let database = try await makeDatabase(root: root)
        defer { database.lock() }
        XCTAssertEqual(database.visibleRootGroupID, recycleBin.id, "The shared visible root is unchanged")
        XCTAssertEqual(database.workspaceRootGroupID, root.id)
        XCTAssertEqual(database.workspace.selectedGroupID, root.id)

        let presentation = MacWorkspacePresentation()
        database.workspace.clearSelection()
        _ = MacWorkspaceSplitViewController(session: database, presentation: presentation, currentSession: { nil })
        XCTAssertEqual(database.workspace.selectedGroupID, root.id, "The window opened on the Recycle Bin")
        XCTAssertEqual(MacWindowWorkspace.subtitle(for: database), "Root")

        database.workspace.selectedCollection = .allEntries
        presentation.beginNewGroup()
        presentation.createGroup(named: "Fresh", in: database)
        XCTAssertEqual(database.group(withID: root.id)?.groups.map(\.name).sorted(), ["Fresh", "Recycle Bin"])
        XCTAssertEqual(database.group(withID: recycleBin.id)?.groups.isEmpty, true)
        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.commandEditor?.mode, .create(parentGroupID: root.id))

        let fresh = try XCTUnwrap(database.group(withID: root.id)?.groups.first { $0.name == "Fresh" })
        database.workspace.selectedGroupID = fresh.id
        try database.deleteGroup(fresh.id, sendToRecycleBin: false)
        XCTAssertEqual(database.workspace.selectedGroupID, root.id, "Deleting the selection fell back to the Recycle Bin")
    }

    func testGroupEditRefusesTheSyntheticRootWhoseFieldsAreNotSaved() async throws {
        let work = KPGroup(name: "Work")
        let root = KPGroup(name: "Root", groups: [work, KPGroup(name: "Home")])
        let database = try await makeDatabase(root: root)
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()

        presentation.beginGroupEdit(groupID: root.id, in: database)
        XCTAssertNil(presentation.groupEditor)
        presentation.beginGroupEdit(groupID: work.id, in: database)
        XCTAssertEqual(presentation.groupEditor?.name, "Work")
    }

    func testImportIntoTheWorkspaceRootOfAWrapperHoldingOnlyTheBinSucceeds() async throws {
        let recycleBin = KPGroup(name: "Recycle Bin")
        let root = KPGroup(name: "Root", groups: [recycleBin], recycleBinUUID: recycleBin.id)
        let database = try await makeDatabase(root: root)
        defer { database.lock() }
        let drafts = try ApplePasswordsCSVImporter.preview(
            from: Data("Title,URL,Username,Password,Notes,OTPAuth\nImported,https://a.example,user,secret,,\n".utf8)
        ).items.map(\.draft)
        let destination = try XCTUnwrap(database.workspaceRootGroupID)

        let outcome = try await database.importEntries(drafts, into: destination)

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(database.group(withID: root.id)?.entries.map(\.title), ["Imported"])
        XCTAssertEqual(database.group(withID: recycleBin.id)?.entries.isEmpty, true)
    }

    func testResetClearsSessionPresentationsWithoutTouchingAnotherWindow() async throws {
        let group = KPGroup(name: "Group")
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [group]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let otherWindow = MacWorkspacePresentation()
        let lifetimeID = presentation.lifetimeID
        presentation.beginNewEntry(in: database)
        presentation.beginGroupEdit(groupID: group.id, in: database)
        XCTAssertNotNil(presentation.commandEditor)
        XCTAssertNotNil(presentation.groupEditor)
        presentation.beginNewGroup(parentID: group.id)
        presentation.newGroupName = "Unsaved"
        presentation.groupCreationErrorMessage = "Error"
        presentation.pendingMove = .group(group.id)
        database.workspace.selectedGroupID = group.id
        presentation.beginSelectionDeletion(in: database)
        presentation.collapsedGroupIDs = [group.id]
        presentation.isShowingDatabaseDetails = true
        presentation.presentedSaveError = .networkUnavailable
        presentation.isCloudReconnectInFlight = true
        otherWindow.beginNewGroup()
        otherWindow.newGroupName = "Other window"

        presentation.reset()

        XCTAssertNotEqual(presentation.lifetimeID, lifetimeID)
        XCTAssertNil(presentation.commandEditor)
        XCTAssertNil(presentation.groupEditor)
        XCTAssertFalse(presentation.isShowingNewGroupSheet)
        XCTAssertNil(presentation.newGroupParentID)
        XCTAssertEqual(presentation.newGroupName, "")
        XCTAssertNil(presentation.groupCreationErrorMessage)
        XCTAssertNil(presentation.pendingMove)
        XCTAssertNil(presentation.pendingDeletion)
        XCTAssertEqual(presentation.collapsedGroupIDs, [group.id], "Expansion lasts for the window's life")
        XCTAssertFalse(presentation.isShowingDatabaseDetails)
        XCTAssertNil(presentation.presentedSaveError)
        XCTAssertFalse(presentation.isCloudReconnectInFlight)
        XCTAssertTrue(otherWindow.isShowingNewGroupSheet)
        XCTAssertEqual(otherWindow.newGroupName, "Other window")
    }

    func testReconnectCompletionCannotChangeAReplacementWorkspace() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let firstStarted = expectation(description: "First reconnect started")
        var finishFirst: CheckedContinuation<Void, any Error>?
        let first = try XCTUnwrap(presentation.reconnectCloud(in: database) {
            try await withCheckedThrowingContinuation {
                finishFirst = $0
                firstStarted.fulfill()
            }
        })
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertNil(presentation.reconnectCloud(in: database) { XCTFail("Overlapping reconnect") })
        presentation.reset()

        let secondStarted = expectation(description: "Replacement reconnect started")
        var finishSecond: CheckedContinuation<Void, any Error>?
        let second = try XCTUnwrap(presentation.reconnectCloud(in: database) {
            try await withCheckedThrowingContinuation {
                finishSecond = $0
                secondStarted.fulfill()
            }
        })
        await fulfillment(of: [secondStarted], timeout: 2)
        finishFirst?.resume(throwing: CloudProviderError.networkUnavailable)
        await first.value
        XCTAssertTrue(presentation.isCloudReconnectInFlight, "Old completion must not clear the replacement's flag")
        XCTAssertNil(database.saveError, "Old authentication errors must not surface in a replacement workspace")
        finishSecond?.resume()
        await second.value
        XCTAssertFalse(presentation.isCloudReconnectInFlight)
    }

    func testReconnectCancellationPreservesTheErrorAndSuccessClearsIt() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        database.presentSaveError(CloudProviderError.networkUnavailable)
        let cancelled = try XCTUnwrap(presentation.reconnectCloud(in: database) {
            throw CloudProviderError.authenticationCancelled
        })
        await cancelled.value
        XCTAssertEqual(database.saveError, .networkUnavailable)
        XCTAssertFalse(presentation.isCloudReconnectInFlight)

        let success = try XCTUnwrap(presentation.reconnectCloud(in: database) {})
        await success.value
        XCTAssertNil(database.saveError)
        XCTAssertFalse(presentation.isCloudReconnectInFlight)

        let failed = try XCTUnwrap(presentation.reconnectCloud(in: database) {
            throw CloudProviderError.networkUnavailable
        })
        await failed.value
        XCTAssertEqual(database.saveError, .networkUnavailable)
        XCTAssertFalse(presentation.isCloudReconnectInFlight)
    }

    func testLockBeforeReconnectStartsPreventsAuthentication() async throws {
        let database = try await makeDatabase()
        let presentation = MacWorkspacePresentation()
        let task = try XCTUnwrap(presentation.reconnectCloud(in: database) {
            XCTFail("A queued reconnect must not prompt after lock")
        })
        database.lock()
        await task.value
        XCTAssertNil(database.saveError)
        XCTAssertFalse(presentation.isCloudReconnectInFlight)
    }

    private func makeDatabase(
        root: KPGroup = KPGroup(name: "Root"), readOnly: Bool = false
    ) async throws -> DatabaseViewModel {
        let fixture = KDBXTestFixture.test
        var reference = try TestDatabaseSupport.makeReference(for: fixture.url(in: Bundle(for: Self.self)), autoFillEnabled: false)
        reference.isReadOnly = readOnly
        let key = SymmetricKey(size: .bits256)
        let database = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) },
            reloadOperation: { reference, _ in
                DatabaseViewModel.ReloadedDatabase(
                    reference: reference, rootGroup: root,
                    meta: KPMeta(recycleBin: root.recycleBinUUID.map { .group($0) }),
                    formatVersion: .kdbx4(minor: 1), sessionKey: key,
                    openTimeSHA512: Data("presentation-tree".utf8), binaryPool: BinaryPool(rawFields: [])
                )
            },
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false }
        )
        await database.unlock(password: fixture.password)
        try await database.reloadDiscardingDraft()
        XCTAssertEqual(database.state, .unlocked)
        return database
    }
}
#endif
