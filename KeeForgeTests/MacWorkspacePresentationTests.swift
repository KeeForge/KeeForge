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
        XCTAssertEqual(presentation.entryEditor?.form.mode, .create(parentGroupID: group.id))

        presentation.closeEntryEditor()
        database.workspace.selectedGroupID = nil
        let rootID = try XCTUnwrap(database.visibleRootGroupID)
        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.entryEditor?.form.mode, .create(parentGroupID: rootID))

        presentation.closeEntryEditor()
        database.workspace.selectedCollection = .verificationCodes
        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.entryEditor?.form.mode, .create(parentGroupID: rootID), "A collection creates in the root")

        presentation.closeEntryEditor()
        database.workspace.selectedGroupID = UUID()
        presentation.beginNewEntry(in: database)
        XCTAssertNil(presentation.entryEditor, "A vanished target must not open an unusable editor")

        database.lock()
        presentation.beginNewEntry(in: database)
        XCTAssertNil(presentation.entryEditor)
        let readOnly = try await makeDatabase(readOnly: true)
        defer { readOnly.lock() }
        presentation.beginNewEntry(in: readOnly)
        XCTAssertNil(presentation.entryEditor)
    }

    func testEntryRequestsKeepTheOpenEditorAndItsUnsavedFields() async throws {
        let entry = KPEntry(title: "Original")
        let database = try await makeDatabase(root: KPGroup(name: "Root", entries: [entry]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedEntryID = entry.id
        presentation.beginSelectedEntryEdit(in: database)
        let editor = try XCTUnwrap(presentation.entryEditor?.form)
        XCTAssertEqual(editor.mode, .edit(entryID: entry.id))
        editor.title = "Unsaved edit"

        presentation.beginNewEntry(in: database)
        presentation.beginEntryEdit(entryID: entry.id, in: database)
        let duplicate = EntryEditViewModel(createIn: try XCTUnwrap(database.visibleRootGroupID))
        presentation.beginEntryDuplicate(duplicate, in: database)
        XCTAssertTrue(presentation.entryEditor?.form === editor)
        XCTAssertEqual(editor.title, "Unsaved edit")

        presentation.closeEntryEditor()
        database.workspace.beginEntrySelection(with: entry.id)
        presentation.beginSelectedEntryEdit(in: database)
        XCTAssertNil(presentation.entryEditor, "Bulk selection has no single-entry edit target")
        database.workspace.endEntrySelection()
        presentation.beginEntryDuplicate(duplicate, in: database)
        XCTAssertTrue(presentation.entryEditor?.form === duplicate)
    }

    func testADuplicateFromAListAcrossGroupsSelectsTheCopyInPlaceAndOthersRevealIt() async throws {
        let entry = KPEntry(title: "Original")
        let group = KPGroup(name: "Work", entries: [entry])
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [group]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let duplicate = EntryEditViewModel(createIn: group.id)

        database.workspace.selectedTag = "Shared"
        presentation.beginEntryDuplicate(duplicate, in: database, selectingInPlace: true)
        XCTAssertTrue(presentation.selectsCreatedEntryInPlace)
        presentation.showCreatedEntry(entry.id, in: database)
        XCTAssertEqual(database.workspace.selectedTag, "Shared", "The tag browser stays")
        XCTAssertEqual(database.workspace.selectedEntryID, entry.id)
        presentation.closeEntryEditor()
        XCTAssertFalse(presentation.selectsCreatedEntryInPlace, "The placement ends with its editor")

        presentation.beginEntryDuplicate(duplicate, in: database)
        XCTAssertFalse(presentation.selectsCreatedEntryInPlace)
        presentation.showCreatedEntry(entry.id, in: database)
        XCTAssertNil(database.workspace.selectedTag)
        XCTAssertEqual(database.workspace.selectedGroupID, group.id, "A group-column duplicate is revealed")
        XCTAssertEqual(database.workspace.selectedEntryID, entry.id)
    }

    // MARK: - Inline editor

    func testTheInlineEditorKeepsItsRegistrationAcrossRedrawsUntilCancelOrReset() async throws {
        let entry = KPEntry(title: "Original")
        let database = try await makeDatabase(root: KPGroup(name: "Root", entries: [entry]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedEntryID = entry.id
        XCTAssertFalse(presentation.freezesWorkspace(database))
        XCTAssertEqual(presentation.openEditor(in: database), .none)

        presentation.beginSelectedEntryEdit(in: database)
        let editor = try XCTUnwrap(presentation.currentEntryEditor(in: database))
        XCTAssertTrue(presentation.freezesWorkspace(database))
        XCTAssertEqual(presentation.openEditor(in: database), .entry(entry.id))
        editor.form.title = "Unsaved"
        editor.coordinator.synchronizeUnsavedChanges()
        XCTAssertTrue(database.hasUnsavedEditor, "The presentation activated the coordinator; no view is needed")
        XCTAssertTrue(presentation.currentEntryEditor(in: database) === editor, "A redraw finds the same editor")
        XCTAssertEqual(presentation.currentEntryEditor(in: database)?.form.title, "Unsaved")

        editor.discard()
        XCTAssertNil(presentation.entryEditor, "Discard Changes closes the editor")
        XCTAssertFalse(database.hasUnsavedEditor)
        XCTAssertFalse(presentation.freezesWorkspace(database))
        XCTAssertEqual(database.entry(withID: entry.id)?.title, "Original")
        XCTAssertEqual(database.workspace.selectedEntryID, entry.id, "Cancel returns to the same entry")

        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.openEditor(in: database), .newEntry)
        let creator = try XCTUnwrap(presentation.entryEditor)
        creator.form.title = "Draft"
        creator.coordinator.synchronizeUnsavedChanges()
        XCTAssertTrue(database.hasUnsavedEditor)
        presentation.reset()
        XCTAssertNil(presentation.entryEditor)
        XCTAssertFalse(database.hasUnsavedEditor, "Reset deactivates the coordinator")
        XCTAssertFalse(presentation.freezesWorkspace(database))
    }

    func testSaveAndFileSaveWriteTheEditorCloseItAndSelectACreatedEntry() async throws {
        let entry = KPEntry(title: "Original")
        let database = try await makeDatabase(root: KPGroup(name: "Root", entries: [entry]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let commands = MacWorkspaceCommands(session: database, presentation: presentation)
        database.workspace.selectedEntryID = entry.id
        XCTAssertFalse(commands.canSave, "A clean database with no editor has nothing to save")

        presentation.beginEntryEdit(entryID: entry.id, in: database)
        let editor = try XCTUnwrap(presentation.entryEditor)
        XCTAssertFalse(commands.canSave, "An unchanged editor has nothing to save")
        editor.form.title = "Renamed"
        XCTAssertTrue(commands.canSave)
        await commands.save()?.value
        XCTAssertNil(presentation.entryEditor)
        XCTAssertEqual(database.entry(withID: entry.id)?.title, "Renamed")
        XCTAssertFalse(database.isDirty)
        XCTAssertFalse(presentation.freezesWorkspace(database))
        XCTAssertEqual(database.workspace.selectedEntryID, entry.id)

        presentation.beginNewEntry(in: database)
        let creator = try XCTUnwrap(presentation.entryEditor)
        XCTAssertFalse(presentation.canSaveEntryEditor, "Create waits for something to be entered")
        creator.form.title = "Fresh"
        await presentation.saveEntryEditor()?.value
        let fresh = try XCTUnwrap(database.rootGroup?.allEntries.first { $0.title == "Fresh" })
        XCTAssertEqual(database.workspace.selectedEntryID, fresh.id, "The created entry is selected")
        XCTAssertNil(presentation.entryEditor)
    }

    func testAFailedSaveOrAConflictKeepsTheEditorItsFieldsAndTheFreezeUntilCancel() async throws {
        let entry = KPEntry(title: "Original")
        let outcomes = SaveOutcomes([.fail, .conflict])
        let database = try await makeDatabase(root: KPGroup(name: "Root", entries: [entry])) { _, _, _, hash, _, _, _ in
            try await outcomes.next(hash: hash)
        }
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedEntryID = entry.id
        presentation.beginEntryEdit(entryID: entry.id, in: database)
        let editor = try XCTUnwrap(presentation.entryEditor)
        editor.form.title = "Kept"

        await editor.save().value
        XCTAssertTrue(presentation.entryEditor === editor, "A failed save keeps the editor open")
        XCTAssertNotNil(editor.coordinator.errorMessage)
        XCTAssertTrue(presentation.freezesWorkspace(database))
        XCTAssertTrue(database.hasUnsavedEditor, "A later lock still asks this editor")

        editor.coordinator.errorMessage = nil
        await editor.save().value
        XCTAssertNotNil(database.saveConflict)
        XCTAssertTrue(presentation.entryEditor === editor, "The conflict holds the editor; Cancel returns to it")
        XCTAssertEqual(editor.form.title, "Kept")
        XCTAssertTrue(presentation.freezesWorkspace(database))

        editor.discard()
        XCTAssertNil(presentation.entryEditor)
        XCTAssertFalse(presentation.freezesWorkspace(database), "Cancel releases the freeze after a failed save")
    }

    func testLockPromptAnswersAndLockItselfAlwaysReleaseTheFreeze() async throws {
        let entry = KPEntry(title: "Original")
        let root = KPGroup(name: "Root", entries: [entry])
        for answer in ["save", "discard", "keep", "close"] {
            let database = try await makeDatabase(root: root)
            defer { database.lock() }
            let presentation = MacWorkspacePresentation()
            database.workspace.selectedEntryID = entry.id
            presentation.beginEntryEdit(entryID: entry.id, in: database)
            let editor = try XCTUnwrap(presentation.entryEditor)
            editor.form.title = "Edited before \(answer)"
            editor.coordinator.synchronizeUnsavedChanges()

            if answer == "close" {
                XCTAssertEqual(database.requestWindowClose(), .waitForEditorPrompt, "⌘W asks the inline editor")
            } else {
                database.lockRequest(manuallyTriggered: true)
            }
            XCTAssertEqual(database.state, .unlocked)
            let request = try XCTUnwrap(editor.coordinator.pendingLockRequest, answer)
            switch answer {
            case "save", "close":
                await editor.save(resuming: request).value
                XCTAssertEqual(database.state, .locked, answer)
            case "discard":
                editor.discard(resuming: request)
                XCTAssertEqual(database.state, .locked)
            default:
                await editor.coordinator.continueEditingAfterLockRequest()
                XCTAssertEqual(database.state, .unlocked)
                XCTAssertTrue(presentation.entryEditor === editor, "Keep Editing keeps the editor")
                XCTAssertTrue(presentation.freezesWorkspace(database))
                database.lockRequest(force: true)
            }
            XCTAssertNil(presentation.currentEntryEditor(in: database), "\(answer): a locked session has no editor")
            XCTAssertFalse(presentation.freezesWorkspace(database), answer)
            presentation.closeEntryEditor()
            XCTAssertNil(presentation.entryEditor)
        }
    }

    func testEnrollmentOpensTheInlineEditorOnItsEntryAndRefusesWhileOneIsOpen() async throws {
        let entry = KPEntry(title: "Mail")
        let work = KPGroup(name: "Work", entries: [entry])
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [work, KPGroup(name: "Home")]))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        let key = try XCTUnwrap(database.sessionKey)
        let form = EntryEditViewModel(editing: try XCTUnwrap(database.entry(withID: entry.id)), sessionKey: key)
        form.title = "Mail with a code"

        XCTAssertTrue(presentation.beginEnrollmentEditor(form, in: database))
        XCTAssertTrue(presentation.entryEditor?.form === form)
        XCTAssertEqual(database.workspace.selectedGroupID, work.id)
        XCTAssertEqual(database.workspace.selectedEntryID, entry.id, "The edited entry is selected under the editor")
        let other = EntryEditViewModel(createIn: work.id)
        XCTAssertFalse(presentation.beginEnrollmentEditor(other, in: database), "One editor per window")
        XCTAssertTrue(presentation.entryEditor?.form === form)
        presentation.closeEntryEditor()

        let readOnly = try await makeDatabase(readOnly: true)
        defer { readOnly.lock() }
        XCTAssertFalse(presentation.beginEnrollmentEditor(EntryEditViewModel(createIn: try XCTUnwrap(readOnly.visibleRootGroupID)),
                                                          in: readOnly))
    }

    func testTheGroupPathWalksUpTheDepthFirstOptions() {
        let ids = (0..<4).map { _ in UUID() }
        let options = [
            DatabaseViewModel.MoveDestinationOption(id: ids[0], name: "Root", depth: 0, isCurrentParent: false),
            DatabaseViewModel.MoveDestinationOption(id: ids[1], name: "Work", depth: 1, isCurrentParent: false),
            DatabaseViewModel.MoveDestinationOption(id: ids[2], name: "Development", depth: 2, isCurrentParent: false),
            DatabaseViewModel.MoveDestinationOption(id: ids[3], name: "Home", depth: 1, isCurrentParent: false),
        ]
        XCTAssertEqual(MacEntryEditorSession.groupPath(of: ids[2], in: options), ["Work", "Development"])
        XCTAssertEqual(MacEntryEditorSession.groupPath(of: ids[3], in: options), ["Home"])
        XCTAssertEqual(MacEntryEditorSession.groupPath(of: ids[0], in: options), [], "Paths start below the root")
        XCTAssertEqual(MacEntryEditorSession.groupLabel(of: ids[0], in: options), "Root")
        XCTAssertEqual(MacEntryEditorSession.groupLabel(of: ids[2], in: options), "Work › Development")
        XCTAssertEqual(MacEntryEditorSession.groupPath(of: UUID(), in: options), [])
    }

    func testTheEditorGroupPathMatchesTheDetailPaneFolderPath() async throws {
        let nested = KPEntry(title: "Nested")
        let top = KPEntry(title: "Top")
        let development = KPGroup(name: "Development", entries: [nested])
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Personal", entries: [top],
                          groups: [KPGroup(name: "Work", groups: [development]), KPGroup(name: "Home")]),
            bundle: Bundle(for: Self.self)
        )
        defer { session.lockRequest(force: true) }
        for entryID in [nested.id, top.id] {
            let groupID = try XCTUnwrap(session.parentGroupID(forEntryID: entryID))
            XCTAssertEqual(MacEntryEditorSession.groupPath(of: groupID, in: session.groupDestinationOptions(currentGroupID: groupID)),
                           session.folderPathComponents(forEntryID: entryID) ?? [])
        }
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
        database.workspace.setEntrySelection([recycledEntry.id])
        presentation.beginSelectionDeletion(in: database)
        XCTAssertNil(presentation.pendingDeletion, "Picks in the bin are never recycled again")
        // The shared rule, before the Mac list's own pruning of picks it does not show.
        database.workspace.setEntrySelection([entry.id, recycledEntry.id])
        XCTAssertEqual(database.deletableSelection, .entries([entry.id]),
                       "Never the entry or group left selected underneath, and never a pick in the bin")
        XCTAssertNotNil(database.entry(withID: entry.id))
        database.lock()
        presentation.pendingDeletion = nil
        presentation.beginSelectionDeletion(in: database)
        XCTAssertNil(presentation.pendingDeletion)
    }

    func testConfirmingABulkDeletionRecyclesEveryPickSavesAndEndsTheSelection() async throws {
        let first = KPEntry(title: "First")
        let second = KPEntry(title: "Second")
        let kept = KPEntry(title: "Kept")
        let group = KPGroup(name: "Work", entries: [first, second, kept])
        let bin = KPGroup(name: "Recycle Bin")
        let database = try await makeDatabase(root: KPGroup(name: "Root", groups: [group, bin], recycleBinUUID: bin.id))
        defer { database.lock() }
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedGroupID = group.id
        database.workspace.selectedEntryID = first.id
        database.workspace.setEntrySelection([first.id, second.id])

        DatabaseCommands(session: database).deleteSelection()
        XCTAssertEqual(database.workspace.deleteSelectionRequestID, 1, "The menu bar's Delete raises the confirmation")
        presentation.beginSelectionDeletion(in: database)
        let deletion = try XCTUnwrap(presentation.pendingDeletion)
        XCTAssertEqual(deletion.confirmationTitle, String(localized: "Delete \(2) Entries?"))
        XCTAssertEqual(deletion.confirmationTitle, "Delete 2 Entries?")
        XCTAssertEqual(deletion.confirmationMessage, "The selected entries will be moved to the recycle bin.")
        XCTAssertEqual(deletion.confirmActionTitle, String(localized: "Delete"))

        deletion.performDeletion(viewModel: database)
        XCTAssertTrue(database.isEntryInRecycleBin(entryID: first.id))
        XCTAssertTrue(database.isEntryInRecycleBin(entryID: second.id))
        XCTAssertFalse(database.isEntryInRecycleBin(entryID: kept.id))
        XCTAssertNil(database.workspace.entrySelection)
        XCTAssertNil(database.workspace.selectedEntryID, "The recycled entry no longer shows in the detail")
        try await waitUntilSaved(database)
        XCTAssertFalse(database.isDirty)
    }

    private func waitUntilSaved(_ database: DatabaseViewModel) async throws {
        for _ in 0..<200 where database.isDirty || database.isSaving {
            try await Task.sleep(for: .milliseconds(10))
        }
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
        let gone = KPEntry(title: "Gone")
        let recycleBin = KPGroup(name: "Recycle Bin", entries: [gone])
        let root = KPGroup(name: "Root", groups: [recycleBin], recycleBinUUID: recycleBin.id)
        let database = try await makeDatabase(root: root)
        defer { database.lock() }
        XCTAssertEqual(database.visibleRootGroupID, recycleBin.id, "The shared visible root is unchanged")
        XCTAssertEqual(database.workspaceRootGroupID, root.id)
        XCTAssertEqual(database.workspace.selectedGroupID, root.id)

        let presentation = MacWorkspacePresentation()
        database.workspace.clearSelection()
        _ = MacWorkspaceSplitViewController(session: database, presentation: presentation,
            attachmentPreview: .unshown(database), currentSession: { nil })
        XCTAssertEqual(database.workspace.selectedGroupID, root.id, "The window opened on the Recycle Bin")
        XCTAssertEqual(MacWindowWorkspace.subtitle(for: database), "Root")
        XCTAssertEqual(database.restoreDestinationOptions(for: .entry(gone.id)).map(\.id), [root.id],
                       "The restore picker offers the wrapper")
        database.workspace.selectedGroupID = recycleBin.id
        XCTAssertEqual(MacWindowWorkspace.subtitle(for: database), String(localized: "Deleted Entries"))
        database.workspace.selectedGroupID = root.id

        database.workspace.selectedCollection = .allEntries
        presentation.beginNewGroup()
        presentation.createGroup(named: "Fresh", in: database)
        XCTAssertEqual(database.group(withID: root.id)?.groups.map(\.name).sorted(), ["Fresh", "Recycle Bin"])
        XCTAssertEqual(database.group(withID: recycleBin.id)?.groups.isEmpty, true)
        presentation.beginNewEntry(in: database)
        XCTAssertEqual(presentation.entryEditor?.form.mode, .create(parentGroupID: root.id))

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
        XCTAssertEqual(database.groupDestinationOptions(currentGroupID: destination).map(\.id), [root.id],
                       "The import picker offers the wrapper, never the bin")

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
        XCTAssertNotNil(presentation.entryEditor)
        XCTAssertNotNil(presentation.groupEditor)
        presentation.beginNewGroup(parentID: group.id)
        presentation.newGroupName = "Unsaved"
        presentation.groupCreationErrorMessage = "Error"
        presentation.pendingMove = .group(group.id)
        database.workspace.selectedGroupID = group.id
        presentation.beginSelectionDeletion(in: database)
        presentation.collapsedGroupIDs = [group.id]
        presentation.collapsedSidebarSections = [.tags]
        presentation.isSidebarCollapsed = true
        presentation.isShowingDatabaseDetails = true
        presentation.presentedSaveError = .networkUnavailable
        presentation.isCloudReconnectInFlight = true
        otherWindow.beginNewGroup()
        otherWindow.newGroupName = "Other window"

        presentation.reset()

        XCTAssertNotEqual(presentation.lifetimeID, lifetimeID)
        XCTAssertNil(presentation.entryEditor)
        XCTAssertNil(presentation.groupEditor)
        XCTAssertFalse(presentation.isShowingNewGroupSheet)
        XCTAssertNil(presentation.newGroupParentID)
        XCTAssertEqual(presentation.newGroupName, "")
        XCTAssertNil(presentation.groupCreationErrorMessage)
        XCTAssertNil(presentation.pendingMove)
        XCTAssertNil(presentation.pendingDeletion)
        XCTAssertEqual(presentation.collapsedGroupIDs, [group.id], "Expansion lasts for the window's life")
        XCTAssertEqual(presentation.collapsedSidebarSections, [.tags], "So do folded sections")
        XCTAssertTrue(presentation.isSidebarCollapsed, "The split view still owns the sidebar's collapse")
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

    private actor SaveOutcomes {
        enum Outcome { case fail, conflict }
        private var outcomes: [Outcome]

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func next(hash: Data) throws -> SaveResult {
            guard outcomes.isEmpty == false else { return .saved(newSHA512: hash) }
            switch outcomes.removeFirst() {
            case .fail: throw DatabaseSaveError.networkUnavailable
            case .conflict: return .conflict(remoteSHA512: Data([1]), remoteData: Data([2]))
            }
        }
    }

    private func makeDatabase(
        root: KPGroup = KPGroup(name: "Root"), readOnly: Bool = false,
        save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) }
    ) async throws -> DatabaseViewModel {
        let fixture = KDBXTestFixture.test
        var reference = try TestDatabaseSupport.makeReference(for: fixture.url(in: Bundle(for: Self.self)), autoFillEnabled: false)
        reference.isReadOnly = readOnly
        let key = SymmetricKey(size: .bits256)
        let database = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: save,
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
