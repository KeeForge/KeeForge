import CryptoKit
import XCTest
@testable import KeeForge

final class DatabaseDraftTests: XCTestCase {
    private struct SyntheticTree {
        let rootGroup: KPGroup
        let meta: KPMeta
        let parentGroupID: UUID
        let parentEntry: KPEntry
        let untouchedGroupID: UUID
        let recycleBinGroupID: UUID?
    }

    private let sessionKey = SymmetricKey(size: .bits256)

    func test_createEntry_addsEntryToParentGroup_setsTimestamps() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let newEntryDraft = EntryDraftPayload(
            title: "Created Entry",
            username: "created-user",
            password: "created-password",
            url: "https://created.example.com",
            notes: "Created note",
            customFields: ["CustomKey": "CustomValue"],
            tags: ["new", "entry"],
            totpConfig: .init(secret: "BASE32SECRET", period: 45, digits: 8, algorithm: .sha256)
        )

        let updatedDraft = try draft.apply(.createEntry(parentGroupID: tree.parentGroupID, draft: newEntryDraft))

        let updatedParentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        let createdEntry = try XCTUnwrap(updatedParentGroup.entries.last)
        XCTAssertEqual(createdEntry.title, newEntryDraft.title)
        XCTAssertEqual(createdEntry.username, newEntryDraft.username)
        XCTAssertEqual(try createdEntry.password.decrypt(using: sessionKey), newEntryDraft.password)
        XCTAssertEqual(createdEntry.url, newEntryDraft.url)
        XCTAssertEqual(createdEntry.notes, newEntryDraft.notes)
        XCTAssertEqual(createdEntry.customFields, newEntryDraft.customFields)
        XCTAssertEqual(createdEntry.tags, newEntryDraft.tags)
        XCTAssertNotNil(createdEntry.creationTime)
        XCTAssertNotNil(createdEntry.lastModificationTime)

        let originalParentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        XCTAssertEqual(updatedParentGroup.entries.count, originalParentGroup.entries.count + 1)

        let originalUntouchedGroup = try XCTUnwrap(findGroup(withID: tree.untouchedGroupID, in: tree.rootGroup))
        let updatedUntouchedGroup = try XCTUnwrap(findGroup(withID: tree.untouchedGroupID, in: updatedDraft.rootGroup))
        try assertGroupsEqual(originalUntouchedGroup, updatedUntouchedGroup)

        if let recycleBinGroupID = tree.recycleBinGroupID {
            let originalRecycleBin = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: tree.rootGroup))
            let updatedRecycleBin = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: updatedDraft.rootGroup))
            try assertGroupsEqual(originalRecycleBin, updatedRecycleBin)
        }
    }

    func test_createEntry_intoRoot_succeeds() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let newEntryDraft = EntryDraftPayload(title: "Root Entry", password: "root-secret")

        let updatedDraft = try draft.apply(.createEntry(parentGroupID: tree.rootGroup.id, draft: newEntryDraft))

        XCTAssertTrue(updatedDraft.rootGroup.entries.contains(where: { $0.title == "Root Entry" }))
    }

    func test_createGroup_addsSubgroupToParentGroup() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft.apply(.createGroup(parentGroupID: tree.parentGroupID, name: "Created Group"))

        let updatedParentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        let createdGroup = try XCTUnwrap(updatedParentGroup.groups.last)
        XCTAssertEqual(createdGroup.name, "Created Group")
        XCTAssertNotNil(createdGroup.creationTime)
        XCTAssertNotNil(createdGroup.lastModificationTime)
    }

    func test_createGroup_duplicateNameInParent_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        XCTAssertThrowsError(
            try draft.apply(.createGroup(parentGroupID: tree.parentGroupID, name: "existing subgroup"))
        ) { error in
            XCTAssertEqual(
                error as? DatabaseDraft.DraftError,
                .duplicateGroupName(parentGroupID: tree.parentGroupID, name: "existing subgroup")
            )
        }
    }

    func test_updateEntry_updatesFields_preservesUnknownXML() throws {
        let parsed = try parseUnknownElementsFixture()
        let originalEntry = try controlledUnknownsEntry(in: parsed.rootGroup)
        var updatedPayload = try makeDraftPayload(from: originalEntry)
        updatedPayload.title = "Controlled Unknowns Updated"

        let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: originalEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: originalEntry.id, in: updatedDraft.rootGroup))

        XCTAssertEqual(updatedEntry.title, "Controlled Unknowns Updated")
        XCTAssertEqual(updatedEntry.unknownXML, originalEntry.unknownXML)
        XCTAssertFalse(originalEntry.attachments.isEmpty)
        XCTAssertEqual(updatedEntry.attachments, originalEntry.attachments)
    }

    func test_updateEntry_setsLastModificationTime() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.notes = "Updated note"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

        let originalTimestamp = try XCTUnwrap(tree.parentEntry.lastModificationTime)
        let updatedTimestamp = try XCTUnwrap(updatedEntry.lastModificationTime)
        XCTAssertGreaterThan(updatedTimestamp, originalTimestamp)
    }

    func test_updateEntry_pushesPreviousEntryStateIntoHistory() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.password = "new-password"
        updatedPayload.notes = "Updated note"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))
        let historicalEntry = try XCTUnwrap(updatedEntry.history.first)

        XCTAssertEqual(updatedEntry.history.count, 1)
        XCTAssertEqual(historicalEntry.title, tree.parentEntry.title)
        XCTAssertEqual(historicalEntry.username, tree.parentEntry.username)
        XCTAssertEqual(try historicalEntry.password.decrypt(using: sessionKey), "old-password")
        XCTAssertEqual(historicalEntry.notes, "Original notes")
        XCTAssertEqual(historicalEntry.lastModificationTime, tree.parentEntry.lastModificationTime)
        XCTAssertTrue(historicalEntry.history.isEmpty)
    }

    func test_updateEntry_trimsHistoryToConfiguredMaxItems() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let olderHistoryEntry = KPEntry(
            id: UUID(),
            title: "Older Snapshot",
            username: "older-user",
            password: try EncryptedValue.encrypt("older-password", using: sessionKey),
            notes: "Older note",
            creationTime: Date(timeIntervalSince1970: 500),
            lastModificationTime: Date(timeIntervalSince1970: 1_500)
        )
        let entryWithHistory = withUpdatedEntry(
            tree.parentEntry,
            history: [olderHistoryEntry]
        )
        let treeWithHistory = try makeSyntheticTree(
            includeRecycleBin: true,
            parentEntryOverride: entryWithHistory,
            metaOverride: KPMeta(
                recycleBinUUID: tree.recycleBinGroupID,
                hasRecycleBinUUIDElement: true,
                historyMaxItems: 1
            )
        )
        var updatedPayload = try makeDraftPayload(from: treeWithHistory.parentEntry)
        updatedPayload.title = "Updated Title"

        let draft = DatabaseDraft(
            rootGroup: treeWithHistory.rootGroup,
            meta: treeWithHistory.meta,
            sessionKey: sessionKey
        )
        let updatedDraft = try draft.apply(.updateEntry(entryID: treeWithHistory.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: treeWithHistory.parentEntry.id, in: updatedDraft.rootGroup))

        XCTAssertEqual(updatedEntry.history.count, 1)
        XCTAssertEqual(updatedEntry.history[0].title, treeWithHistory.parentEntry.title)
        XCTAssertEqual(try updatedEntry.history[0].password.decrypt(using: sessionKey), "old-password")
    }

    func test_updateEntry_reEncryptsPassword_underSessionKey() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.password = "new-password"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

        XCTAssertEqual(try updatedEntry.password.decrypt(using: sessionKey), "new-password")
        XCTAssertNotEqual(updatedEntry.password.sealedData, tree.parentEntry.password.sealedData)
        XCTAssertEqual(
            updatedEntry.customFields["KPEX_PASSKEY_PRIVATE_KEY_PEM"],
            tree.parentEntry.customFields["KPEX_PASSKEY_PRIVATE_KEY_PEM"]
        )
        XCTAssertTrue(updatedEntry.protectedStringKeys.contains("KPEX_PASSKEY_PRIVATE_KEY_PEM"))
    }

    func test_deleteEntry_softDelete_movesToRecycleBin() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft.apply(.deleteEntry(entryID: tree.parentEntry.id, sendToRecycleBin: true))

        let updatedParentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertFalse(updatedParentGroup.entries.contains(where: { $0.id == tree.parentEntry.id }))

        let recycleBinGroupID = try XCTUnwrap(tree.recycleBinGroupID)
        let recycleBinGroup = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: updatedDraft.rootGroup))
        XCTAssertTrue(recycleBinGroup.entries.contains(where: { $0.id == tree.parentEntry.id }))
    }

    func test_deleteEntry_softDelete_lazilyCreatesRecycleBin() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft.apply(.deleteEntry(entryID: tree.parentEntry.id, sendToRecycleBin: true))
        let recycleBinGroupID = try XCTUnwrap(updatedDraft.meta.recycleBinUUID)
        let recycleBinGroup = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: updatedDraft.rootGroup))

        XCTAssertEqual(updatedDraft.rootGroup.recycleBinUUID, recycleBinGroupID)
        XCTAssertTrue(updatedDraft.meta.hasRecycleBinUUIDElement)
        XCTAssertFalse(
            updatedDraft.rootGroup.groups.contains(where: { $0.id == recycleBinGroupID }),
            "Recycle Bin should not be a direct child of the synthetic root"
        )
        let visibleRoot = try XCTUnwrap(updatedDraft.rootGroup.groups.first)
        XCTAssertTrue(
            visibleRoot.groups.contains(where: { $0.id == recycleBinGroupID }),
            "Recycle Bin should be created under the visible root group"
        )
        XCTAssertTrue(recycleBinGroup.entries.contains(where: { $0.id == tree.parentEntry.id }))

        let updatedParentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertFalse(updatedParentGroup.entries.contains(where: { $0.id == tree.parentEntry.id }))
    }

    func test_deleteEntry_hardDelete_removesEntry_createsDeletedObject() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let recycleBinGroupID = try XCTUnwrap(tree.recycleBinGroupID)
        let originalRecycleBin = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: tree.rootGroup))

        let deletedEntryID = tree.parentEntry.id
        let beforeDelete = Date.now
        let updatedDraft = try draft.apply(.deleteEntry(entryID: deletedEntryID, sendToRecycleBin: false))

        XCTAssertFalse(updatedDraft.rootGroup.allEntries.contains(where: { $0.id == deletedEntryID }))

        let updatedRecycleBin = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: updatedDraft.rootGroup))
        try assertGroupsEqual(originalRecycleBin, updatedRecycleBin)

        let tombstone = try XCTUnwrap(
            updatedDraft.meta.deletedObjects.first(where: { $0.uuid == deletedEntryID }),
            "Hard delete should create a DeletedObject tombstone"
        )
        XCTAssertGreaterThanOrEqual(tombstone.deletionTime, beforeDelete)
    }

    func test_deleteGroup_softDelete_movesSubtreeToRecycleBin() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))

        let updatedDraft = try draft.apply(.deleteGroup(groupID: tree.parentGroupID, sendToRecycleBin: true))

        let visibleRoot = try XCTUnwrap(updatedDraft.rootGroup.groups.first)
        XCTAssertFalse(visibleRoot.groups.contains(where: { $0.id == tree.parentGroupID }))

        let recycleBinGroupID = try XCTUnwrap(tree.recycleBinGroupID)
        let recycleBinGroup = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: updatedDraft.rootGroup))
        let movedGroup = try XCTUnwrap(recycleBinGroup.groups.first(where: { $0.id == tree.parentGroupID }))
        try assertGroupsEqual(movedGroup, originalGroup)
    }

    func test_deleteGroup_softDelete_lazilyCreatesRecycleBin() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft.apply(.deleteGroup(groupID: tree.parentGroupID, sendToRecycleBin: true))

        let recycleBinGroupID = try XCTUnwrap(updatedDraft.meta.recycleBinUUID)
        let recycleBinGroup = try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedDraft.rootGroup.recycleBinUUID, recycleBinGroupID)
        XCTAssertTrue(updatedDraft.meta.hasRecycleBinUUIDElement)
        XCTAssertTrue(recycleBinGroup.groups.contains(where: { $0.id == tree.parentGroupID }))

        let visibleRoot = try XCTUnwrap(updatedDraft.rootGroup.groups.first)
        XCTAssertFalse(visibleRoot.groups.contains(where: { $0.id == tree.parentGroupID }))
        XCTAssertTrue(visibleRoot.groups.contains(where: { $0.id == recycleBinGroupID }))
    }

    func test_deleteGroup_softDelete_preservesDuplicateNamesInRecycleBin() throws {
        let recycleBinID = UUID()
        let firstGroupID = UUID()
        let secondGroupID = UUID()
        let visibleRoot = KPGroup(
            name: "Visible Root",
            groups: [
                KPGroup(id: firstGroupID, name: "Duplicate"),
                KPGroup(id: secondGroupID, name: "Duplicate"),
                KPGroup(id: recycleBinID, name: "Recycle Bin", iconID: 43),
            ]
        )
        let root = KPGroup(name: "Root", groups: [visibleRoot], recycleBinUUID: recycleBinID)
        let meta = KPMeta(recycleBinUUID: recycleBinID, hasRecycleBinUUIDElement: true)
        let draft = DatabaseDraft(rootGroup: root, meta: meta, sessionKey: sessionKey)

        let updatedDraft = try draft
            .apply(.deleteGroup(groupID: firstGroupID, sendToRecycleBin: true))
            .apply(.deleteGroup(groupID: secondGroupID, sendToRecycleBin: true))

        let recycleBinGroup = try XCTUnwrap(findGroup(withID: recycleBinID, in: updatedDraft.rootGroup))
        let duplicateGroups = recycleBinGroup.groups.filter { $0.name == "Duplicate" }
        XCTAssertEqual(duplicateGroups.count, 2)
        XCTAssertEqual(Set(duplicateGroups.map(\.id)), Set([firstGroupID, secondGroupID]))
    }

    func test_deleteGroup_hardDelete_removesSubtreeAndCreatesDeletedObjects() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalParentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        let childGroupID = try XCTUnwrap(originalParentGroup.groups.first?.id)
        let beforeDelete = Date.now

        let updatedDraft = try draft.apply(.deleteGroup(groupID: tree.parentGroupID, sendToRecycleBin: false))

        XCTAssertNil(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertNil(findGroup(withID: childGroupID, in: updatedDraft.rootGroup))
        XCTAssertFalse(updatedDraft.rootGroup.allEntries.contains(where: { $0.id == tree.parentEntry.id }))

        let tombstoneIDs = Set(updatedDraft.meta.deletedObjects.map(\.uuid))
        XCTAssertTrue(tombstoneIDs.isSuperset(of: [tree.parentGroupID, childGroupID, tree.parentEntry.id]))
        for tombstone in updatedDraft.meta.deletedObjects where [tree.parentGroupID, childGroupID, tree.parentEntry.id].contains(tombstone.uuid) {
            XCTAssertGreaterThanOrEqual(tombstone.deletionTime, beforeDelete)
        }
    }

    func test_deleteGroup_protectedAndMissingGroupsThrowWithoutMutatingDraft() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalRootGroup = draft.rootGroup
        let visibleRootID = try XCTUnwrap(tree.rootGroup.groups.first?.id)
        let recycleBinGroupID = try XCTUnwrap(tree.recycleBinGroupID)
        let missingGroupID = UUID()

        for protectedGroupID in [tree.rootGroup.id, visibleRootID, recycleBinGroupID] {
            XCTAssertThrowsError(
                try draft.apply(.deleteGroup(groupID: protectedGroupID, sendToRecycleBin: true))
            ) { error in
                XCTAssertEqual(error as? DatabaseDraft.DraftError, .protectedGroup(protectedGroupID))
            }
        }

        XCTAssertThrowsError(
            try draft.apply(.deleteGroup(groupID: missingGroupID, sendToRecycleBin: true))
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .groupNotFound(missingGroupID))
        }

        XCTAssertFalse(draft.isDirty)
        try assertGroupsEqual(draft.rootGroup, originalRootGroup)
    }

    func test_pendingEdits_recordsEveryAppliedOp_inOrder() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let createEdit = EntryEdit.createEntry(
            parentGroupID: tree.parentGroupID,
            draft: EntryDraftPayload(title: "Created", password: "secret")
        )

        let createdDraft = try draft.apply(createEdit)
        let createdEntry = try XCTUnwrap(createdDraft.rootGroup.allEntries.first(where: { $0.title == "Created" }))

        let updateEdit = EntryEdit.updateEntry(
            entryID: createdEntry.id,
            draft: EntryDraftPayload(title: "Created Updated", password: "new-secret")
        )
        let updatedDraft = try createdDraft.apply(updateEdit)

        let deleteEdit = EntryEdit.deleteEntry(entryID: createdEntry.id, sendToRecycleBin: false)
        let deletedDraft = try updatedDraft.apply(deleteEdit)

        XCTAssertEqual(deletedDraft.pendingEdits, [createEdit, updateEdit, deleteEdit])
    }

    func test_isDirty_falseInitially_trueAfterFirstApply() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        XCTAssertFalse(draft.isDirty)

        let updatedDraft = try draft.apply(
            .createEntry(
                parentGroupID: tree.parentGroupID,
                draft: EntryDraftPayload(title: "Dirty", password: "secret")
            )
        )

        XCTAssertTrue(updatedDraft.isDirty)
    }

    func test_discardingEdits_returnsFreshDraftOverOriginal() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let dirtyDraft = try draft.apply(
            .createEntry(
                parentGroupID: tree.parentGroupID,
                draft: EntryDraftPayload(title: "Created", password: "secret")
            )
        )

        let discardedDraft = dirtyDraft.discardingEdits()

        XCTAssertTrue(discardedDraft.pendingEdits.isEmpty)
        XCTAssertFalse(discardedDraft.isDirty)
        XCTAssertEqual(discardedDraft.meta, tree.meta)
        try assertGroupsEqual(discardedDraft.rootGroup, tree.rootGroup)
    }

    func test_entryEdit_codableRoundTrip() throws {
        let createParentID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let updateEntryID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let deleteEntryID = try XCTUnwrap(UUID(uuidString: "99999999-8888-7777-6666-555555555555"))
        let deleteGroupID = try XCTUnwrap(UUID(uuidString: "12345678-1234-5678-1234-567812345678"))
        let payload = EntryDraftPayload(
            title: "Codable",
            username: "user",
            password: "secret",
            url: "https://example.com",
            notes: "notes",
            customFields: ["Custom": "Value"],
            tags: ["one", "two"],
            totpConfig: .init(secret: "BASE32SECRET", period: 60, digits: 8, algorithm: .sha512),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let edits: [EntryEdit] = [
            .createEntry(parentGroupID: createParentID, draft: payload),
            .createGroup(parentGroupID: createParentID, name: "New Group"),
            .updateEntry(entryID: updateEntryID, draft: payload),
            .deleteEntry(entryID: deleteEntryID, sendToRecycleBin: true),
            .deleteGroup(groupID: deleteGroupID, sendToRecycleBin: false),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for edit in edits {
            let encoded = try encoder.encode(edit)
            let decoded = try decoder.decode(EntryEdit.self, from: encoded)
            XCTAssertEqual(decoded, edit)
        }
    }

    func test_apply_unknownParentGroupID_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalRootGroup = draft.rootGroup
        let missingGroupID = UUID()

        XCTAssertThrowsError(
            try draft.apply(
                .createEntry(
                    parentGroupID: missingGroupID,
                    draft: EntryDraftPayload(title: "Missing", password: "secret")
                )
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .groupNotFound(missingGroupID))
        }

        XCTAssertFalse(draft.isDirty)
        try assertGroupsEqual(draft.rootGroup, originalRootGroup)
    }

    func test_apply_unknownEntryID_onUpdate_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalRootGroup = draft.rootGroup
        let missingEntryID = UUID()

        XCTAssertThrowsError(
            try draft.apply(
                .updateEntry(
                    entryID: missingEntryID,
                    draft: EntryDraftPayload(title: "Missing", password: "secret")
                )
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .entryNotFound(missingEntryID))
        }

        XCTAssertFalse(draft.isDirty)
        try assertGroupsEqual(draft.rootGroup, originalRootGroup)
    }

    func test_apply_1000Edits_completesWithinOneSecond() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        var draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let clock = ContinuousClock()
        let start = clock.now

        for index in 0..<1_000 {
            draft = try draft.apply(
                .createEntry(
                    parentGroupID: tree.parentGroupID,
                    draft: EntryDraftPayload(title: "Entry \(index)", password: "secret")
                )
            )
        }

        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(1))
        let updatedParentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: draft.rootGroup))
        XCTAssertEqual(updatedParentGroup.entries.count, 1_001)
    }

    private func makeSyntheticTree(
        includeRecycleBin: Bool,
        parentEntryOverride: KPEntry? = nil,
        metaOverride: KPMeta? = nil
    ) throws -> SyntheticTree {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let modifiedAt = Date(timeIntervalSince1970: 2_000)
        let defaultParentEntry = KPEntry(
            id: UUID(),
            title: "Original Entry",
            username: "original-user",
            password: try EncryptedValue.encrypt("old-password", using: sessionKey),
            url: "https://example.com",
            notes: "Original notes",
            tags: ["existing"],
            customFields: ["KPEX_PASSKEY_PRIVATE_KEY_PEM": "pem-data"],
            creationTime: createdAt,
            lastModificationTime: modifiedAt,
            protectedStringKeys: ["KPEX_PASSKEY_PRIVATE_KEY_PEM"]
        )
        let parentEntry = parentEntryOverride ?? defaultParentEntry
        let parentGroupID = UUID()
        let parentGroup = KPGroup(
            id: parentGroupID,
            name: "Parent",
            entries: [parentEntry],
            groups: [
                KPGroup(
                    id: UUID(),
                    name: "Existing Subgroup",
                    creationTime: createdAt,
                    lastModificationTime: modifiedAt
                )
            ],
            creationTime: createdAt,
            lastModificationTime: modifiedAt
        )

        let untouchedGroupID = UUID()
        let untouchedGroup = KPGroup(
            id: untouchedGroupID,
            name: "Untouched",
            entries: [
                KPEntry(
                    id: UUID(),
                    title: "Untouched Entry",
                    username: "untouched-user",
                    password: try EncryptedValue.encrypt("untouched-password", using: sessionKey),
                    url: "https://untouched.example.com",
                    notes: "Untouched notes",
                    creationTime: createdAt,
                    lastModificationTime: modifiedAt
                )
            ],
            creationTime: createdAt,
            lastModificationTime: modifiedAt
        )

        let recycleBinGroupID = includeRecycleBin ? UUID() : nil
        let recycleBinGroup = recycleBinGroupID.map {
            KPGroup(
                id: $0,
                name: "Recycle Bin",
                iconID: 43,
                creationTime: createdAt,
                lastModificationTime: modifiedAt
            )
        }

        var visibleRootChildren = [parentGroup, untouchedGroup]
        if let recycleBinGroup {
            visibleRootChildren.append(recycleBinGroup)
        }

        let visibleRootGroup = KPGroup(
            id: UUID(),
            name: "Visible Root",
            entries: [
                KPEntry(
                    id: UUID(),
                    title: "Root Entry",
                    username: "root-user",
                    password: try EncryptedValue.encrypt("root-password", using: sessionKey),
                    creationTime: createdAt,
                    lastModificationTime: modifiedAt
                )
            ],
            groups: visibleRootChildren
        )

        let rootGroup = KPGroup(
            id: UUID(),
            name: "Root",
            groups: [visibleRootGroup],
            recycleBinUUID: recycleBinGroupID
        )
        let meta = metaOverride ?? KPMeta(
            recycleBinUUID: recycleBinGroupID,
            hasRecycleBinUUIDElement: includeRecycleBin
        )

        return SyntheticTree(
            rootGroup: rootGroup,
            meta: meta,
            parentGroupID: parentGroupID,
            parentEntry: parentEntry,
            untouchedGroupID: untouchedGroupID,
            recycleBinGroupID: recycleBinGroupID
        )
    }

    private func parseUnknownElementsFixture() throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let bundle = Bundle(for: Self.self)
        let databaseURL = try TestDatabaseSupport.fixtureURL(
            named: "unknown-elements",
            subdirectory: "round-trip",
            bundle: bundle
        )
        let databaseData = try Data(contentsOf: databaseURL)
        return try KDBXParser.parseWithMeta(
            data: databaseData,
            password: "test-round-trip",
            sessionKey: sessionKey
        )
    }

    private func controlledUnknownsEntry(in rootGroup: KPGroup) throws -> KPEntry {
        try XCTUnwrap(rootGroup.allEntries.first { $0.title == "Controlled Unknowns" })
    }

    private func makeDraftPayload(from entry: KPEntry) throws -> EntryDraftPayload {
        EntryDraftPayload(
            title: entry.title,
            username: entry.username,
            password: try entry.password.decrypt(using: sessionKey),
            url: entry.url,
            notes: entry.notes,
            customFields: entry.customFields,
            tags: entry.tags,
            totpConfig: try draftTOTPConfiguration(from: entry.totpConfig),
            lastModificationTime: entry.lastModificationTime
        )
    }

    private func draftTOTPConfiguration(
        from config: TOTPConfig?
    ) throws -> EntryDraftPayload.TOTPConfiguration? {
        guard let config else {
            return nil
        }

        return EntryDraftPayload.TOTPConfiguration(
            secret: try config.secret.decrypt(using: sessionKey),
            period: config.period,
            digits: config.digits,
            algorithm: config.algorithm
        )
    }

    private func findGroup(withID groupID: UUID, in group: KPGroup) -> KPGroup? {
        if group.id == groupID {
            return group
        }

        for childGroup in group.groups {
            if let match = findGroup(withID: groupID, in: childGroup) {
                return match
            }
        }

        return nil
    }

    private func findEntry(withID entryID: UUID, in group: KPGroup) -> KPEntry? {
        if let match = group.entries.first(where: { $0.id == entryID }) {
            return match
        }

        for childGroup in group.groups {
            if let match = findEntry(withID: entryID, in: childGroup) {
                return match
            }
        }

        return nil
    }

    private func assertGroupsEqual(
        _ lhs: KPGroup,
        _ rhs: KPGroup,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(lhs.id, rhs.id, file: file, line: line)
        XCTAssertEqual(lhs.name, rhs.name, file: file, line: line)
        XCTAssertEqual(lhs.iconID, rhs.iconID, file: file, line: line)
        XCTAssertEqual(lhs.isExpanded, rhs.isExpanded, file: file, line: line)
        XCTAssertEqual(lhs.creationTime, rhs.creationTime, file: file, line: line)
        XCTAssertEqual(lhs.lastModificationTime, rhs.lastModificationTime, file: file, line: line)
        XCTAssertEqual(lhs.recycleBinUUID, rhs.recycleBinUUID, file: file, line: line)
        XCTAssertEqual(lhs.unknownXML, rhs.unknownXML, file: file, line: line)
        XCTAssertEqual(lhs.entries.count, rhs.entries.count, file: file, line: line)
        XCTAssertEqual(lhs.groups.count, rhs.groups.count, file: file, line: line)

        for (lhsEntry, rhsEntry) in zip(lhs.entries, rhs.entries) {
            try assertEntriesEqual(lhsEntry, rhsEntry, file: file, line: line)
        }

        for (lhsGroup, rhsGroup) in zip(lhs.groups, rhs.groups) {
            try assertGroupsEqual(lhsGroup, rhsGroup, file: file, line: line)
        }
    }

    private func assertEntriesEqual(
        _ lhs: KPEntry,
        _ rhs: KPEntry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(lhs.id, rhs.id, file: file, line: line)
        XCTAssertEqual(lhs.title, rhs.title, file: file, line: line)
        XCTAssertEqual(lhs.username, rhs.username, file: file, line: line)
        XCTAssertEqual(try lhs.password.decrypt(using: sessionKey), try rhs.password.decrypt(using: sessionKey), file: file, line: line)
        XCTAssertEqual(lhs.url, rhs.url, file: file, line: line)
        XCTAssertEqual(lhs.notes, rhs.notes, file: file, line: line)
        XCTAssertEqual(lhs.iconID, rhs.iconID, file: file, line: line)
        XCTAssertEqual(lhs.tags, rhs.tags, file: file, line: line)
        XCTAssertEqual(lhs.customFields, rhs.customFields, file: file, line: line)
        XCTAssertEqual(lhs.creationTime, rhs.creationTime, file: file, line: line)
        XCTAssertEqual(lhs.lastModificationTime, rhs.lastModificationTime, file: file, line: line)
        XCTAssertEqual(lhs.unknownXML, rhs.unknownXML, file: file, line: line)
        XCTAssertEqual(lhs.protectedStringKeys, rhs.protectedStringKeys, file: file, line: line)
        XCTAssertEqual(lhs.history.count, rhs.history.count, file: file, line: line)
        for (lhsHistoryEntry, rhsHistoryEntry) in zip(lhs.history, rhs.history) {
            try assertEntriesEqual(lhsHistoryEntry, rhsHistoryEntry, file: file, line: line)
        }
        try assertTOTPConfigsEqual(lhs.totpConfig, rhs.totpConfig, file: file, line: line)
    }

    private func withUpdatedEntry(
        _ entry: KPEntry,
        history: [KPEntry]
    ) -> KPEntry {
        KPEntry(
            id: entry.id,
            title: entry.title,
            username: entry.username,
            password: entry.password,
            url: entry.url,
            notes: entry.notes,
            iconID: entry.iconID,
            tags: entry.tags,
            hasTagsElement: entry.hasTagsElement,
            customFields: entry.customFields,
            totpConfig: entry.totpConfig,
            otpURL: entry.otpURL,
            creationTime: entry.creationTime,
            lastModificationTime: entry.lastModificationTime,
            history: history,
            unknownXML: entry.unknownXML,
            protectedStringKeys: entry.protectedStringKeys
        )
    }

    private func assertTOTPConfigsEqual(
        _ lhs: TOTPConfig?,
        _ rhs: TOTPConfig?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        switch (lhs, rhs) {
        case (nil, nil):
            return
        case let (lhs?, rhs?):
            XCTAssertEqual(lhs.period, rhs.period, file: file, line: line)
            XCTAssertEqual(lhs.digits, rhs.digits, file: file, line: line)
            XCTAssertEqual(lhs.algorithm.rawValue, rhs.algorithm.rawValue, file: file, line: line)
            XCTAssertEqual(
                try lhs.secret.decrypt(using: sessionKey),
                try rhs.secret.decrypt(using: sessionKey),
                file: file,
                line: line
            )
        default:
            XCTFail("TOTP config mismatch", file: file, line: line)
        }
    }
}
