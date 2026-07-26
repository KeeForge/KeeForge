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
        XCTAssertEqual(updatedEntry.expires, originalEntry.expires)
        XCTAssertEqual(updatedEntry.expiryTime, originalEntry.expiryTime)
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

    func test_updateEntry_trimsHistoryToConfiguredMaxSize_oldestFirst() throws {
        // `estimatedHistorySize` is a 256-byte overhead per entry plus the
        // UTF-8 length of the fields it enumerates. With no username/url/tags/
        // TOTP/passkey these entries cost exactly 256 + title + notes +
        // password, so the retained set is arithmetic, not a guess.
        let padding = String(repeating: "x", count: 1_000)
        let entryID = UUID()
        let current = KPEntry(
            id: entryID,
            title: "Sized Current", // 256 + 13 + 1000 + 16 = 1285
            password: try EncryptedValue.encrypt("current-password", using: sessionKey),
            notes: padding,
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 2_000),
            history: [
                KPEntry(
                    id: UUID(),
                    title: "History Newest", // 256 + 14 + 1000 + 16 = 1286
                    password: try EncryptedValue.encrypt("history-password", using: sessionKey),
                    notes: padding,
                    lastModificationTime: Date(timeIntervalSince1970: 900)
                ),
                KPEntry(
                    id: UUID(),
                    title: "History Middle", // 256 + 14 + 1000 + 16 = 1286
                    password: try EncryptedValue.encrypt("history-password", using: sessionKey),
                    notes: padding,
                    lastModificationTime: Date(timeIntervalSince1970: 800)
                ),
                KPEntry(
                    id: UUID(),
                    title: "History Oldest Tiny", // 256 + 19 + 0 + 16 = 291
                    password: try EncryptedValue.encrypt("history-password", using: sessionKey),
                    lastModificationTime: Date(timeIntervalSince1970: 700)
                ),
            ]
        )
        // 1285 + 1286 = 2571 fits; adding the third (3857) does not.
        let tree = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: current,
            metaOverride: KPMeta(historyMaxSize: 2_900)
        )
        var updatedPayload = try makeDraftPayload(from: current)
        updatedPayload.title = "Sized Updated"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: entryID, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: entryID, in: updatedDraft.rootGroup))

        XCTAssertEqual(
            updatedEntry.history.map(\.title),
            ["Sized Current", "History Newest"],
            "Trimming keeps the newest-first prefix that fits the byte budget"
        )
        XCTAssertEqual(
            try updatedEntry.history[0].password.decrypt(using: sessionKey),
            "current-password"
        )
        // 2900 - 2571 = 329 bytes were still free and "History Oldest Tiny"
        // only costs 291, but the budget loop stops at the first entry that
        // does not fit rather than skipping past it.
        XCTAssertFalse(updatedEntry.history.contains { $0.title == "History Oldest Tiny" })
    }

    func test_updateEntry_historyMaxSizeOfZeroDropsHistoryEntirely() throws {
        let tree = try makeSyntheticTree(
            includeRecycleBin: false,
            metaOverride: KPMeta(historyMaxSize: 0)
        )
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.notes = "Updated note"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

        XCTAssertTrue(updatedEntry.history.isEmpty, "Every snapshot exceeds a zero-byte budget")
    }

    func test_updateEntry_negativeHistoryMaxSizeMeansUnlimited() throws {
        // KeePass encodes "unlimited" as -1; the byte budget must be skipped
        // rather than treated as a budget no entry can fit into.
        let tree = try makeSyntheticTree(
            includeRecycleBin: false,
            metaOverride: KPMeta(historyMaxSize: -1)
        )
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.notes = "Updated note"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

        XCTAssertEqual(updatedEntry.history.map(\.title), ["Original Entry"])
    }

    // MARK: - Legacy `otp` field preservation

    // A legacy `otpauth://` URI carries an issuer, label, and arbitrary query
    // parameters that the KeeForge TOTP model does not model. The writer emits
    // it verbatim when present, so an edit either keeps it byte-identical or
    // drops it — never rewrites it into something narrower.

    func test_updateEntry_editThatLeavesTOTPAloneKeepsLegacyOtpURL() throws {
        let legacyURL = "otpauth://totp/Legacy:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Legacy&period=30&digits=6"
        let tree = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: try makeLegacyOTPEntry(otpURL: legacyURL)
        )
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.notes = "Untouched TOTP, edited note"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

        XCTAssertEqual(updatedEntry.otpURL, legacyURL)
    }

    func test_updateEntry_editThatChangesTOTPInvalidatesLegacyOtpURL() throws {
        let legacyURL = "otpauth://totp/Legacy:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Legacy&period=30&digits=6"
        let mutations: [(name: String, mutate: (inout EntryDraftPayload) -> Void)] = [
            ("secret", { $0.totpConfig?.secret = "GEZDGNBVGY3TQOJQ" }),
            ("period", { $0.totpConfig?.period = 60 }),
            ("digits", { $0.totpConfig?.digits = 8 }),
            ("algorithm", { $0.totpConfig?.algorithm = .sha256 }),
            ("removal", { $0.totpConfig = nil }),
        ]

        for mutation in mutations {
            let tree = try makeSyntheticTree(
                includeRecycleBin: false,
                parentEntryOverride: try makeLegacyOTPEntry(otpURL: legacyURL)
            )
            var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
            mutation.mutate(&updatedPayload)

            let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
            let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
            let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

            XCTAssertNil(
                updatedEntry.otpURL,
                "A changed \(mutation.name) makes the legacy URI stale, so it must be dropped"
            )
        }
    }

    func test_updateEntry_keeOTPSourceOwnsTheOtpSlotOnlyUnderItsOwnFieldName() throws {
        let legacyURL = "otpauth://totp/Legacy?secret=JBSWY3DPEHPK3PXP"
        let rewrittenQuery = "key=JBSWY3DPEHPK3PXP&step=45&size=8&otpHashMode=SHA256"

        // A KeeOTP source stored under `otp` is what the writer emits there.
        let owning = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: try makeLegacyOTPEntry(otpURL: legacyURL)
        )
        var owningPayload = try makeDraftPayload(from: owning.parentEntry)
        owningPayload.totpConfig?.keeOTPSource = KeeOTPSource(fieldName: "otp", rawQuery: rewrittenQuery)
        let owningEntry = try XCTUnwrap(
            findEntry(
                withID: owning.parentEntry.id,
                in: try DatabaseDraft(rootGroup: owning.rootGroup, meta: owning.meta, sessionKey: sessionKey)
                    .apply(.updateEntry(entryID: owning.parentEntry.id, draft: owningPayload))
                    .rootGroup
            )
        )
        XCTAssertEqual(owningEntry.otpURL, rewrittenQuery)

        // A KeeOTP source in a differently named field must not evict whatever
        // the entry already stored in `otp`.
        let borrowing = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: try makeLegacyOTPEntry(otpURL: legacyURL)
        )
        var borrowingPayload = try makeDraftPayload(from: borrowing.parentEntry)
        borrowingPayload.totpConfig?.keeOTPSource = KeeOTPSource(fieldName: "OTP", rawQuery: rewrittenQuery)
        let borrowingEntry = try XCTUnwrap(
            findEntry(
                withID: borrowing.parentEntry.id,
                in: try DatabaseDraft(rootGroup: borrowing.rootGroup, meta: borrowing.meta, sessionKey: sessionKey)
                    .apply(.updateEntry(entryID: borrowing.parentEntry.id, draft: borrowingPayload))
                    .rootGroup
            )
        )
        XCTAssertEqual(borrowingEntry.otpURL, legacyURL)
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
        // The diverted passkey private key is not part of the draft payload
        // and must be inherited from the original entry, still sealed.
        XCTAssertNil(updatedEntry.customFields["KPEX_PASSKEY_PRIVATE_KEY_PEM"])
        XCTAssertEqual(
            try updatedEntry.passkeyPrivateKey?.decrypt(using: sessionKey),
            "pem-data"
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

    func test_setGroupSearchingEnabled_disablesGroupAndTouchesModificationTime() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        XCTAssertNil(originalGroup.searchingEnabled)

        let updatedDraft = try draft.apply(
            .setGroupSearchingEnabled(groupID: tree.parentGroupID, value: .disabled)
        )

        let updatedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedGroup.searchingEnabled, .disabled)
        XCTAssertGreaterThan(
            try XCTUnwrap(updatedGroup.lastModificationTime),
            try XCTUnwrap(originalGroup.lastModificationTime)
        )
        XCTAssertEqual(updatedGroup.name, originalGroup.name)
        XCTAssertEqual(updatedGroup.entries.count, originalGroup.entries.count)
        XCTAssertEqual(updatedGroup.groups.count, originalGroup.groups.count)
        XCTAssertTrue(updatedDraft.isDirty)
    }

    func test_setGroupSearchingEnabled_leavesSiblingsAndChildrenAlone() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft.apply(
            .setGroupSearchingEnabled(groupID: tree.parentGroupID, value: .disabled)
        )

        let originalUntouched = try XCTUnwrap(findGroup(withID: tree.untouchedGroupID, in: tree.rootGroup))
        let updatedUntouched = try XCTUnwrap(findGroup(withID: tree.untouchedGroupID, in: updatedDraft.rootGroup))
        try assertGroupsEqual(originalUntouched, updatedUntouched)

        let updatedParent = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        for subgroup in updatedParent.groups {
            XCTAssertNil(
                subgroup.searchingEnabled,
                "Children inherit at read time; the edit must not stamp them"
            )
        }
    }

    func test_setGroupSearchingEnabled_reEnablingWritesExplicitValue() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft
            .apply(.setGroupSearchingEnabled(groupID: tree.parentGroupID, value: .disabled))
            .apply(.setGroupSearchingEnabled(groupID: tree.parentGroupID, value: .enabled))

        let updatedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedGroup.searchingEnabled, .enabled)
    }

    func test_setGroupSearchingEnabled_unknownGroup_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let missingGroupID = UUID()

        XCTAssertThrowsError(
            try draft.apply(.setGroupSearchingEnabled(groupID: missingGroupID, value: .disabled))
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .groupNotFound(missingGroupID))
        }
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
            passkeyPrivateKey: try EncryptedValue.encrypt("pem-data", using: sessionKey),
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

    /// Entry whose TOTP arrived as a legacy `otpauth://` URI in the `otp`
    /// field, mirroring what `KDBXParser` produces for such a database.
    private func makeLegacyOTPEntry(otpURL: String) throws -> KPEntry {
        KPEntry(
            id: UUID(),
            title: "Legacy OTP Entry",
            username: "legacy-user",
            password: try EncryptedValue.encrypt("old-password", using: sessionKey),
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey),
                period: 30,
                digits: 6,
                algorithm: .sha1
            ),
            otpURL: otpURL,
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 2_000),
            protectedStringKeys: ["otp"]
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
        XCTAssertEqual(lhs.searchingEnabled, rhs.searchingEnabled, file: file, line: line)
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
