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

    func test_createEntry_protectedCustomFieldKeys_protectPasskeyFieldsThroughSerialization() throws {
        let pem = "-----BEGIN PRIVATE KEY-----\nDRAFT-PROTECTED-PEM\n-----END PRIVATE KEY-----"
        let protectedKeys: Set<String> = [
            PasskeyCredential.credentialIDKey,
            PasskeyCredential.privateKeyPEMKey,
            PasskeyCredential.userHandleKey,
        ]
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let payload = EntryDraftPayload(
            title: "Registered Passkey",
            username: "alice@example.com",
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "3q2-7wEj",
                PasskeyCredential.privateKeyPEMKey: pem,
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "AAEC-_z9",
            ],
            protectedCustomFieldKeys: protectedKeys.union(["Not A Draft Field"])
        )

        let updatedDraft = try draft.apply(.createEntry(parentGroupID: tree.parentGroupID, draft: payload))
        let parentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        let created = try XCTUnwrap(parentGroup.entries.last)

        XCTAssertNil(created.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertEqual(try created.passkeyPrivateKey?.decrypt(using: sessionKey), pem)
        // Keys absent from the entry's fields are dropped; the requested
        // passkey keys survive, including the diverted PEM key.
        XCTAssertEqual(created.protectedStringKeys, protectedKeys)

        let innerStreamKey = Data("KeeForge Draft Inner Stream Key".utf8)
        var serializer = KDBXXMLSerializer(
            rootGroup: updatedDraft.rootGroup,
            meta: updatedDraft.meta,
            innerStreamKey: innerStreamKey,
            sessionKey: sessionKey
        )
        let xml = try serializer.serialize()
        let xmlString = String(decoding: xml, as: UTF8.self)

        for key in protectedKeys {
            XCTAssertTrue(
                xmlString.contains("<Key>\(key)</Key><Value Protected=\"True\">"),
                "\(key) must serialize with Protected=True"
            )
        }
        XCTAssertTrue(xmlString.contains("<Key>\(PasskeyCredential.relyingPartyKey)</Key><Value>example.com</Value>"))
        XCTAssertTrue(xmlString.contains("<Key>\(PasskeyCredential.usernameKey)</Key><Value>alice@example.com</Value>"))
        XCTAssertFalse(xmlString.contains("DRAFT-PROTECTED-PEM"))
        XCTAssertFalse(xmlString.contains("3q2-7wEj"))
        XCTAssertFalse(xmlString.contains("AAEC-_z9"))

        let reparsed = try KDBXXMLParser(
            data: xml,
            innerStreamKey: innerStreamKey,
            innerStreamID: KDBXParser.innerStreamChaCha20,
            sessionKey: sessionKey
        ).parse()
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first { $0.title == "Registered Passkey" })

        XCTAssertEqual(reloaded.protectedStringKeys.intersection(PasskeyCredential.allFieldKeys), protectedKeys)
        XCTAssertNil(reloaded.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertEqual(try XCTUnwrap(reloaded.passkeyPrivateKey).decrypt(using: sessionKey), pem)
        XCTAssertEqual(reloaded.customFields[PasskeyCredential.credentialIDKey], "3q2-7wEj")
        XCTAssertEqual(reloaded.customFields[PasskeyCredential.relyingPartyKey], "example.com")
        XCTAssertEqual(reloaded.customFields[PasskeyCredential.usernameKey], "alice@example.com")
        XCTAssertEqual(reloaded.customFields[PasskeyCredential.userHandleKey], "AAEC-_z9")
        XCTAssertNotNil(reloaded.passkeyCredential)
    }

    func test_createEntry_withoutProtectedCustomFieldKeys_leavesFieldsUnprotected() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let payload = EntryDraftPayload(
            title: "Unprotected Fields",
            password: "secret",
            customFields: ["CustomKey": "CustomValue"]
        )

        let updatedDraft = try draft.apply(.createEntry(parentGroupID: tree.parentGroupID, draft: payload))
        let parentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        let created = try XCTUnwrap(parentGroup.entries.last)

        XCTAssertTrue(created.protectedStringKeys.isEmpty)
    }

    func test_updateEntry_protectedCustomFieldKeys_addProtectionForNewPasskeyFields() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        var payload = try makeDraftPayload(from: tree.parentEntry)
        payload.customFields[PasskeyCredential.credentialIDKey] = "Y3JlZA"
        payload.customFields[PasskeyCredential.userHandleKey] = "aGFuZGxl"
        payload.protectedCustomFieldKeys = [
            PasskeyCredential.credentialIDKey,
            PasskeyCredential.userHandleKey,
        ]

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: payload))
        let updated = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

        XCTAssertTrue(updated.protectedStringKeys.contains(PasskeyCredential.credentialIDKey))
        XCTAssertTrue(updated.protectedStringKeys.contains(PasskeyCredential.userHandleKey))
        // The original entry's protected diverted PEM stays protected.
        XCTAssertTrue(updated.protectedStringKeys.contains(PasskeyCredential.privateKeyPEMKey))
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

    /// A KeePass-authored `<History>` is oldest-first, so trimming by position
    /// discarded the newest versions and kept the oldest.
    func test_updateEntry_maxItemsKeepsTheNewestVersionsOfAnOldestFirstHistory() throws {
        let updatedEntry = try applyTitleEdit(
            toEntryWithHistory: [
                historyVersion("v1-oldest", at: 700),
                historyVersion("v2", at: 800),
                historyVersion("v3-newest", at: 900),
            ],
            meta: KPMeta(historyMaxItems: 3)
        )

        XCTAssertEqual(
            updatedEntry.history.map(\.title),
            ["Original Entry", "v2", "v3-newest"],
            "the cap must drop the oldest version, not the second-newest"
        )
    }

    /// The app's own files are newest-first; the recency selection must leave that
    /// long-standing behavior exactly as it was.
    func test_updateEntry_maxItemsStillKeepsTheNewestVersionsOfANewestFirstHistory() throws {
        let updatedEntry = try applyTitleEdit(
            toEntryWithHistory: [
                historyVersion("v3-newest", at: 900),
                historyVersion("v2", at: 800),
                historyVersion("v1-oldest", at: 700),
            ],
            meta: KPMeta(historyMaxItems: 3)
        )

        XCTAssertEqual(updatedEntry.history.map(\.title), ["Original Entry", "v3-newest", "v2"])
    }

    /// Survivors keep the order the file had; only the selection is by recency.
    func test_updateEntry_trimmingPreservesStorageOrder() throws {
        let updatedEntry = try applyTitleEdit(
            toEntryWithHistory: [
                historyVersion("v1-oldest", at: 700),
                historyVersion("v3-newest", at: 900),
                historyVersion("v2", at: 800),
            ],
            meta: KPMeta(historyMaxItems: 3)
        )

        XCTAssertEqual(
            updatedEntry.history.map(\.title),
            ["Original Entry", "v3-newest", "v2"],
            "v3 stays ahead of v2 because that is where the file had them"
        )
    }

    /// KDBX timestamps are second-resolution, so equal stamps must still give a
    /// total order rather than depending on `sorted` being stable.
    func test_updateEntry_maxItemsBreaksTimestampTiesByStorageOrder() throws {
        let updatedEntry = try applyTitleEdit(
            toEntryWithHistory: [
                historyVersion("tied-first", at: 800),
                historyVersion("tied-second", at: 800),
            ],
            meta: KPMeta(historyMaxItems: 2)
        )

        XCTAssertEqual(updatedEntry.history.map(\.title), ["Original Entry", "tied-first"])
    }

    func test_updateEntry_versionsWithoutATimestampAreDroppedFirst() throws {
        let updatedEntry = try applyTitleEdit(
            toEntryWithHistory: [
                historyVersion("undated", at: nil),
                historyVersion("dated", at: 700),
            ],
            meta: KPMeta(historyMaxItems: 2)
        )

        XCTAssertEqual(
            updatedEntry.history.map(\.title),
            ["Original Entry", "dated"],
            "a version with no timestamp is the weakest claim to a slot"
        )
    }

    /// The byte budget walks the same recency order, so an oldest-first file no
    /// longer spends its budget on the versions it should have dropped.
    func test_updateEntry_maxSizeSpendsTheBudgetOnTheNewestVersions() throws {
        let padding = String(repeating: "x", count: 1_000)
        // Each padded version costs 256 + title + 1000 + 7 ("history" password),
        // so the budget covers the snapshot and one padded version, not two.
        let updatedEntry = try applyTitleEdit(
            toEntryWithHistory: [
                historyVersion("v1-oldest", at: 700, notes: padding),
                historyVersion("v2", at: 800, notes: padding),
                historyVersion("v3-newest", at: 900, notes: padding),
            ],
            meta: KPMeta(historyMaxSize: 2_800)
        )

        XCTAssertEqual(
            updatedEntry.history.map(\.title),
            ["Original Entry", "v3-newest"],
            "the budget must go to the newest versions, not the ones stored first"
        )
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

    func test_updateEntry_addingAdditionalURLPreservesTOTPConfigAndLegacyOtpURL() throws {
        let legacyURL = "otpauth://totp/Legacy:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Legacy&period=30&digits=6"
        let tree = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: try makeLegacyOTPEntry(otpURL: legacyURL)
        )
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.customFields["KP2A_URL_1"] = "https://legacy.example.com"

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))
        let updatedTOTP = try XCTUnwrap(updatedEntry.totpConfig)

        XCTAssertEqual(try updatedTOTP.secret.decrypt(using: sessionKey), "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(updatedTOTP.period, 30)
        XCTAssertEqual(updatedTOTP.digits, 6)
        XCTAssertEqual(updatedTOTP.algorithm, .sha1)
        XCTAssertEqual(updatedEntry.otpURL, legacyURL)
        XCTAssertEqual(updatedEntry.additionalURLs, ["https://legacy.example.com"])
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

    func test_payloadCarryingBothOtpauthURIAndKeeOTPSource_keeOTPSourceWinsTheOtpSlot() throws {
        // The serializer gives `keeOTPSource` precedence over a fresh URI; the
        // otp slot must agree in both the create and update paths, or a
        // payload carrying both would emit divergent sources. The view model
        // never emits both today — this pins the invariant at the consumer.
        let query = "key=JBSWY3DPEHPK3PXP&step=30&size=6"
        let staleURI = "otpauth://totp/Stale?secret=GEZDGNBVGY3TQOJQ"
        let bothConfig = EntryDraftPayload.TOTPConfiguration(
            secret: "JBSWY3DPEHPK3PXP",
            keeOTPSource: KeeOTPSource(fieldName: "otp", rawQuery: query),
            otpauthURI: staleURI
        )

        let createTree = try makeSyntheticTree(includeRecycleBin: false)
        let createDraft = DatabaseDraft(rootGroup: createTree.rootGroup, meta: createTree.meta, sessionKey: sessionKey)
        let createdDraft = try createDraft.apply(
            .createEntry(
                parentGroupID: createTree.parentGroupID,
                draft: EntryDraftPayload(title: "Both Sources", totpConfig: bothConfig)
            )
        )
        let createdGroup = try XCTUnwrap(findGroup(withID: createTree.parentGroupID, in: createdDraft.rootGroup))
        let created = try XCTUnwrap(createdGroup.entries.last)
        XCTAssertEqual(created.otpURL, query)
        XCTAssertFalse(
            created.protectedStringKeys.contains("otp"),
            "The stale URI must not force protection onto the KeeOTP-owned slot"
        )

        let updateTree = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: try makeLegacyOTPEntry(otpURL: staleURI)
        )
        var updatePayload = try makeDraftPayload(from: updateTree.parentEntry)
        updatePayload.totpConfig = bothConfig
        let updatedDraft = try DatabaseDraft(rootGroup: updateTree.rootGroup, meta: updateTree.meta, sessionKey: sessionKey)
            .apply(.updateEntry(entryID: updateTree.parentEntry.id, draft: updatePayload))
        let updated = try XCTUnwrap(findEntry(withID: updateTree.parentEntry.id, in: updatedDraft.rootGroup))
        XCTAssertEqual(updated.otpURL, query)
    }

    func test_createEntry_withOTPAuthURI_setsOtpURLVerbatimAndProtectsTheOtpKey() throws {
        let uri = "otpauth://totp/Fresh:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Fresh&period=45&digits=8&algorithm=SHA256"
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let payload = EntryDraftPayload(
            title: "Fresh Enrollment",
            totpConfig: .init(
                secret: "JBSWY3DPEHPK3PXP",
                period: 45,
                digits: 8,
                algorithm: .sha256,
                otpauthURI: uri
            )
        )

        let updatedDraft = try draft.apply(.createEntry(parentGroupID: tree.parentGroupID, draft: payload))
        let parentGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        let created = try XCTUnwrap(parentGroup.entries.last)

        XCTAssertEqual(created.otpURL, uri)
        XCTAssertTrue(created.protectedStringKeys.contains("otp"))

        let innerStreamKey = Data("KeeForge Draft Inner Stream Key".utf8)
        var serializer = KDBXXMLSerializer(
            rootGroup: updatedDraft.rootGroup,
            meta: updatedDraft.meta,
            innerStreamKey: innerStreamKey,
            sessionKey: sessionKey
        )
        let xmlString = String(decoding: try serializer.serialize(), as: UTF8.self)
        XCTAssertTrue(
            xmlString.contains("<Key>otp</Key><Value Protected=\"True\">"),
            "A freshly enrolled otpauth URI must serialize protected"
        )
        XCTAssertFalse(xmlString.contains("TimeOtp-"), "URI enrollment must not also author TimeOtp-* fields")
    }

    func test_updateEntry_reEnrollmentReplacesTheStoredOtpURL() throws {
        let legacyURL = "otpauth://totp/Legacy:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Legacy&period=30&digits=6"
        let freshURL = "otpauth://totp/Fresh:user@example.com?secret=GEZDGNBVGY3TQOJQ&issuer=Fresh&period=60"
        let tree = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: try makeLegacyOTPEntry(otpURL: legacyURL)
        )
        var updatedPayload = try makeDraftPayload(from: tree.parentEntry)
        updatedPayload.totpConfig = .init(
            secret: "GEZDGNBVGY3TQOJQ",
            period: 60,
            otpauthURI: freshURL
        )

        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: tree.parentEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updatedDraft.rootGroup))

        XCTAssertEqual(updatedEntry.otpURL, freshURL)
        XCTAssertTrue(updatedEntry.protectedStringKeys.contains("otp"))
        XCTAssertEqual(try XCTUnwrap(updatedEntry.totpConfig).period, 60)
        XCTAssertEqual(try XCTUnwrap(updatedEntry.totpConfig).secret.decrypt(using: sessionKey), "GEZDGNBVGY3TQOJQ")
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
        XCTAssertNotNil(movedGroup.locationChanged, "Recycling is a move and must stamp <LocationChanged>")
        // Everything except that one field has to survive the move untouched.
        let normalized = movedGroup.deepCopy()
        normalized.locationChanged = originalGroup.locationChanged
        try assertGroupsEqual(normalized, originalGroup)
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

    // MARK: - Restore entry version

    /// Builds a draft whose entry has one earlier version, by editing it once.
    private func makeDraftWithHistory() throws -> (draft: DatabaseDraft, entryID: UUID, tree: SyntheticTree) {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let entryID = tree.parentEntry.id

        var payload = try makeDraftPayload(from: tree.parentEntry)
        payload.title = "Edited Title"
        payload.username = "edited-user"
        payload.password = "edited-password"
        let edited = try draft.apply(.updateEntry(entryID: entryID, draft: payload))

        return (edited, entryID, tree)
    }

    func test_restoreEntryVersion_bringsBackTheEarlierFieldValues() throws {
        let (draft, entryID, tree) = try makeDraftWithHistory()
        let beforeRestore = try XCTUnwrap(findEntry(withID: entryID, in: draft.rootGroup))
        XCTAssertEqual(beforeRestore.title, "Edited Title")
        XCTAssertEqual(beforeRestore.history.count, 1)

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entryID, historyIndex: 0))

        let restored = try XCTUnwrap(findEntry(withID: entryID, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.title, tree.parentEntry.title)
        XCTAssertEqual(restored.username, tree.parentEntry.username)
        XCTAssertEqual(
            try restored.password.decrypt(using: sessionKey),
            try tree.parentEntry.password.decrypt(using: sessionKey)
        )
    }

    /// A restore must be undoable: the state it replaced becomes the newest version,
    /// otherwise restoring the wrong version silently destroys the current contents.
    func test_restoreEntryVersion_keepsTheReplacedStateAsNewestHistory() throws {
        let (draft, entryID, _) = try makeDraftWithHistory()

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entryID, historyIndex: 0))

        let restored = try XCTUnwrap(findEntry(withID: entryID, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.history.count, 2)
        XCTAssertEqual(restored.history[0].title, "Edited Title", "the replaced state must be kept")

        // And restoring that newest version again returns to where we started.
        let undoneDraft = try restoredDraft.apply(.restoreEntryVersion(entryID: entryID, historyIndex: 0))
        let undone = try XCTUnwrap(findEntry(withID: entryID, in: undoneDraft.rootGroup))
        XCTAssertEqual(undone.title, "Edited Title")
    }

    func test_restoreEntryVersion_keepsIdentityCreationTimeAndPreservedXML() throws {
        let (draft, entryID, _) = try makeDraftWithHistory()
        let beforeRestore = try XCTUnwrap(findEntry(withID: entryID, in: draft.rootGroup))

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entryID, historyIndex: 0))

        let restored = try XCTUnwrap(findEntry(withID: entryID, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.id, entryID, "restoring must not re-identify the entry")
        XCTAssertEqual(restored.creationTime, beforeRestore.creationTime, "the entry was created once")
        XCTAssertEqual(
            restored.unknownXML,
            beforeRestore.unknownXML,
            "the live entry's preserved XML describes today's element layout and must survive"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(restored.lastModificationTime),
            try XCTUnwrap(beforeRestore.lastModificationTime)
        )
    }

    /// KDBX fixes no order for `<History>`, and the two conventions in the wild disagree:
    /// KeePass and KeePassXC append chronologically (oldest first), while this app's edit
    /// path prepends the newest. Verified against a database written by KeePassXC 2.7.12,
    /// whose oldest version arrives at index 0. The viewer therefore sorts by modification
    /// time and carries each version's storage index along, because restoring addresses
    /// the raw array — sorting without keeping the index would restore the wrong version.
    func test_restoreEntryVersion_indexAddressesStorageOrderNotDisplayOrder() throws {
        let sessionKey = self.sessionKey
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        // Foreign layout: oldest first, exactly how KeePassXC writes it.
        let entry = KPEntry(
            id: UUID(),
            title: "Foreign",
            username: "current",
            password: try EncryptedValue.encrypt("current-pw", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            history: [
                KPEntry(
                    title: "Foreign", username: "oldest",
                    password: try EncryptedValue.encrypt("oldest-pw", using: sessionKey),
                    lastModificationTime: timestamp.addingTimeInterval(-7_200)
                ),
                KPEntry(
                    title: "Foreign", username: "newer",
                    password: try EncryptedValue.encrypt("newer-pw", using: sessionKey),
                    lastModificationTime: timestamp.addingTimeInterval(-3_600)
                )
            ]
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        // Index 1 is the newer stored version, whatever a sorted view would show first.
        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entry.id, historyIndex: 1))

        let restored = try XCTUnwrap(findEntry(withID: entry.id, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.username, "newer")
    }

    /// A database can carry stored versions while capping history at zero, and the cap wins
    /// — KeePass trims the same way, and someone who set it does not want old secrets kept.
    /// The restore therefore cannot be undone here, and `restoreKeepsReplacedState` has to
    /// report that so the confirmation stops promising one.
    func test_restoreEntryVersion_historyCapAtZeroDiscardsReplacedStateAndIsReported() throws {
        let sessionKey = self.sessionKey
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = KPEntry(
            id: UUID(),
            title: "Capped",
            username: "current",
            password: try EncryptedValue.encrypt("current-pw", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            history: [
                KPEntry(
                    title: "Capped", username: "previous",
                    password: try EncryptedValue.encrypt("previous-pw", using: sessionKey),
                    lastModificationTime: timestamp.addingTimeInterval(-3_600)
                )
            ]
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let meta = KPMeta(historyMaxItems: 0)
        let draft = DatabaseDraft(rootGroup: root, meta: meta, sessionKey: sessionKey)

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entry.id, historyIndex: 0))

        let restored = try XCTUnwrap(findEntry(withID: entry.id, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.username, "previous", "the chosen version becomes current")
        XCTAssertTrue(restored.history.isEmpty, "the cap wins over keeping the replaced state")
        XCTAssertFalse(
            draft.restoreKeepsReplacedState(entryID: entry.id),
            "the UI must be told the restore is not undoable here"
        )
    }

    /// Same, via the size cap — the likelier trigger in practice, since one large replaced
    /// entry can exceed `HistoryMaxSize` on its own.
    func test_restoreEntryVersion_historySizeCapDiscardsReplacedStateAndIsReported() throws {
        let sessionKey = self.sessionKey
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = KPEntry(
            id: UUID(),
            title: "Sized",
            username: "current",
            password: try EncryptedValue.encrypt("current-pw", using: sessionKey),
            notes: String(repeating: "x", count: 4_096),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            history: [
                KPEntry(
                    title: "Sized", username: "previous",
                    password: try EncryptedValue.encrypt("previous-pw", using: sessionKey),
                    lastModificationTime: timestamp.addingTimeInterval(-3_600)
                )
            ]
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let meta = KPMeta(historyMaxSize: 1)
        let draft = DatabaseDraft(rootGroup: root, meta: meta, sessionKey: sessionKey)

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entry.id, historyIndex: 0))

        let restored = try XCTUnwrap(findEntry(withID: entry.id, in: restoredDraft.rootGroup))
        XCTAssertTrue(restored.history.isEmpty, "the size cap wins too")
        XCTAssertFalse(draft.restoreKeepsReplacedState(entryID: entry.id))
    }

    /// The ordinary case: with room in the history, the replaced state is kept and the UI is
    /// told it may promise an undo.
    func test_restoreEntryVersion_reportsUndoableWhenHistoryHasRoom() throws {
        let (draft, entryID, _) = try makeDraftWithHistory()

        XCTAssertTrue(draft.restoreKeepsReplacedState(entryID: entryID))

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entryID, historyIndex: 0))
        let restored = try XCTUnwrap(findEntry(withID: entryID, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.history.first?.title, "Edited Title")
    }

    func test_restoreEntryVersion_outOfRangeIndex_throws() throws {
        let (draft, entryID, _) = try makeDraftWithHistory()

        for index in [1, -1, Int.max] {
            XCTAssertThrowsError(
                try draft.apply(.restoreEntryVersion(entryID: entryID, historyIndex: index)),
                "index \(index) should not resolve"
            ) { error in
                XCTAssertEqual(
                    error as? DatabaseDraft.DraftError,
                    .historyVersionNotFound(entryID: entryID, index: index)
                )
            }
        }
    }

    /// The written `<CustomIconUUID>` element lives in the live entry's preserved XML,
    /// which a restore keeps, so the display copy must stay with the live entry too —
    /// taking the snapshot's would show an icon the saved file does not carry.
    func test_restoreEntryVersion_keepsTheLiveEntrysCustomIcon() throws {
        let sessionKey = self.sessionKey
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let liveIcon = UUID()
        let entry = KPEntry(
            id: UUID(),
            title: "Icon",
            username: "current",
            password: try EncryptedValue.encrypt("current-pw", using: sessionKey),
            customIconUUID: liveIcon,
            creationTime: timestamp,
            lastModificationTime: timestamp,
            history: [
                KPEntry(
                    title: "Icon", username: "previous",
                    password: try EncryptedValue.encrypt("previous-pw", using: sessionKey),
                    customIconUUID: UUID(),
                    lastModificationTime: timestamp.addingTimeInterval(-3_600)
                )
            ]
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entry.id, historyIndex: 0))

        let restored = try XCTUnwrap(findEntry(withID: entry.id, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.username, "previous")
        XCTAssertEqual(restored.customIconUUID, liveIcon)
    }

    /// A stored version stamped ahead of the live entry (a device with a skewed clock
    /// can write one) outranks the pushed snapshot in the recency trim, so a tight cap
    /// can discard the snapshot while the trimmed history stays non-empty. The probe
    /// must report the snapshot's own survival, not "something survived".
    func test_restoreEntryVersion_futureDatedVersionEvictingTheSnapshotIsReported() throws {
        let sessionKey = self.sessionKey
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = KPEntry(
            id: UUID(),
            title: "Skewed",
            username: "current",
            password: try EncryptedValue.encrypt("current-pw", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            history: [
                KPEntry(
                    title: "Skewed", username: "future",
                    password: try EncryptedValue.encrypt("future-pw", using: sessionKey),
                    lastModificationTime: timestamp.addingTimeInterval(3_600)
                ),
                KPEntry(
                    title: "Skewed", username: "old",
                    password: try EncryptedValue.encrypt("old-pw", using: sessionKey),
                    lastModificationTime: timestamp.addingTimeInterval(-3_600)
                )
            ]
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let meta = KPMeta(historyMaxItems: 1)
        let draft = DatabaseDraft(rootGroup: root, meta: meta, sessionKey: sessionKey)

        XCTAssertFalse(
            draft.restoreKeepsReplacedState(entryID: entry.id),
            "the snapshot loses to the future-dated version, so no undo may be promised"
        )

        let restoredDraft = try draft.apply(.restoreEntryVersion(entryID: entry.id, historyIndex: 1))
        let restored = try XCTUnwrap(findEntry(withID: entry.id, in: restoredDraft.rootGroup))
        XCTAssertEqual(restored.username, "old")
        XCTAssertEqual(
            restored.history.map(\.username),
            ["future"],
            "the recency cap keeps the future-dated version; the snapshot is gone"
        )
    }

    func test_restoreEntryVersion_unknownEntry_throws() throws {
        let (draft, _, _) = try makeDraftWithHistory()
        let missingEntryID = UUID()

        XCTAssertThrowsError(
            try draft.apply(.restoreEntryVersion(entryID: missingEntryID, historyIndex: 0))
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .entryNotFound(missingEntryID))
        }
    }

    func test_setGroupIcon_changesIconAndTouchesModificationTime() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        XCTAssertNotEqual(originalGroup.iconID, 37)

        let updatedDraft = try draft.apply(.setGroupIcon(groupID: tree.parentGroupID, iconID: 37))

        let updatedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedGroup.iconID, 37)
        XCTAssertGreaterThan(
            try XCTUnwrap(updatedGroup.lastModificationTime),
            try XCTUnwrap(originalGroup.lastModificationTime)
        )
        XCTAssertEqual(updatedGroup.name, originalGroup.name)
        XCTAssertEqual(updatedGroup.entries.count, originalGroup.entries.count)
        XCTAssertEqual(updatedGroup.groups.count, originalGroup.groups.count)
        XCTAssertTrue(updatedDraft.isDirty)
    }

    /// A `<CustomIconUUID>` outranks `<IconID>` in KeePass, and the parser keeps the
    /// source element in `unknownXML` for verbatim round-tripping. If either survives
    /// the edit, the newly chosen standard icon is written but never displayed — the
    /// pick silently does nothing in this app and in every other client.
    func test_setGroupIcon_clearsCustomIconSoTheStandardIconActuallyShows() throws {
        let customIconUUID = UUID()
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(
            xml: "<CustomIconUUID>3q2+7w==</CustomIconUUID>",
            insertionIndex: 0
        )
        let group = KPGroup(
            name: "Has Custom Icon",
            iconID: 48,
            customIconUUID: customIconUUID,
            lastModificationTime: Date(timeIntervalSince1970: 0),
            unknownXML: unknownXML
        )
        let root = KPGroup(name: "Root", groups: [group])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        let updatedDraft = try draft.apply(.setGroupIcon(groupID: group.id, iconID: 37))

        let updatedGroup = try XCTUnwrap(findGroup(withID: group.id, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedGroup.iconID, 37)
        XCTAssertNil(updatedGroup.customIconUUID)
        XCTAssertFalse(
            updatedGroup.unknownXML.nodes.contains { $0.elementName == "CustomIconUUID" },
            "the preserved element would be written back verbatim and keep overriding IconID"
        )
    }

    func test_setGroupIcon_leavesSiblingsAndChildrenAlone() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft.apply(.setGroupIcon(groupID: tree.parentGroupID, iconID: 37))

        let originalUntouched = try XCTUnwrap(findGroup(withID: tree.untouchedGroupID, in: tree.rootGroup))
        let updatedUntouched = try XCTUnwrap(findGroup(withID: tree.untouchedGroupID, in: updatedDraft.rootGroup))
        try assertGroupsEqual(originalUntouched, updatedUntouched)

        let originalParent = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        let updatedParent = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        for (original, updated) in zip(originalParent.groups, updatedParent.groups) {
            XCTAssertEqual(updated.iconID, original.iconID, "the edit must not restyle children")
        }
    }

    func test_setGroupIcon_unknownGroup_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let missingGroupID = UUID()

        XCTAssertThrowsError(
            try draft.apply(.setGroupIcon(groupID: missingGroupID, iconID: 37))
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .groupNotFound(missingGroupID))
        }
    }

    // MARK: - Set entry icon

    /// Builds a one-entry draft, optionally carrying a custom icon the way a
    /// parsed file does: the display copy *and* the preserved element, which is
    /// the only one the writer emits.
    private func makeEntryIconDraft(
        customIconUUID: UUID? = nil,
        iconID: Int = 0
    ) throws -> (draft: DatabaseDraft, entryID: UUID) {
        var unknownXML = OpaqueXMLNodes()
        if let customIconUUID {
            unknownXML.append(
                xml: "<CustomIconUUID>\(customIconUUID.kdbxBase64String)</CustomIconUUID>",
                insertionIndex: 2
            )
        }
        let entry = KPEntry(
            title: "Icon",
            password: try EncryptedValue.encrypt("pw", using: sessionKey),
            iconID: iconID,
            customIconUUID: customIconUUID,
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 0),
            unknownXML: unknownXML
        )
        let root = KPGroup(name: "Root", entries: [entry])
        return (DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey), entry.id)
    }

    private func serializedXML(of draft: DatabaseDraft) throws -> String {
        var serializer = KDBXXMLSerializer(
            rootGroup: draft.rootGroup,
            meta: draft.meta,
            innerStreamKey: Data("KeeForge Draft Inner Stream Key".utf8),
            sessionKey: sessionKey
        )
        return String(decoding: try serializer.serialize(), as: UTF8.self)
    }

    /// The live entry's own children, i.e. everything the serializer writes
    /// before `<History>`. Stored versions are full `<Entry>` elements that keep
    /// the icon they were saved with, so a document-wide search would count
    /// theirs too and no assertion about the current icon would mean anything.
    private func liveEntryXML(of draft: DatabaseDraft) throws -> String {
        let xml = try serializedXML(of: draft)
        return xml.components(separatedBy: "<History>")[0]
    }

    /// Same reason the group edit clears it: a surviving `<CustomIconUUID>`
    /// outranks `<IconID>` in every client, so the newly chosen standard icon
    /// would be written and never displayed.
    func test_setEntryIcon_standardClearsTheCustomIconSoItActuallyShows() throws {
        let (draft, entryID) = try makeEntryIconDraft(customIconUUID: UUID(), iconID: 48)
        let original = try XCTUnwrap(findEntry(withID: entryID, in: draft.rootGroup))

        let updatedDraft = try draft.apply(.setEntryIcon(entryID: entryID, icon: .standard(iconID: 37)))

        let updated = try XCTUnwrap(findEntry(withID: entryID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updated.iconID, 37)
        XCTAssertNil(updated.customIconUUID)
        XCTAssertFalse(
            updated.unknownXML.nodes.contains { $0.elementName == "CustomIconUUID" },
            "the preserved element would be written back verbatim and keep overriding IconID"
        )
        XCTAssertFalse(try liveEntryXML(of: updatedDraft).contains("<CustomIconUUID>"))
        XCTAssertEqual(
            updated.history.first?.customIconUUID,
            original.customIconUUID,
            "the stored version keeps the icon it was saved with; only the live entry changes"
        )
    }

    /// The display copy alone is not enough: the serializer writes
    /// `<CustomIconUUID>` only from the preserved XML, so a custom pick that
    /// does not land there is lost on the next save.
    func test_setEntryIcon_customWritesTheElementRightAfterIconID() throws {
        let (draft, entryID) = try makeEntryIconDraft()
        let chosen = UUID()

        let updatedDraft = try draft.apply(.setEntryIcon(entryID: entryID, icon: .custom(uuid: chosen)))

        let updated = try XCTUnwrap(findEntry(withID: entryID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updated.customIconUUID, chosen)
        XCTAssertEqual(updated.iconID, 0, "a custom icon does not disturb the standard one it overrides")
        XCTAssertTrue(
            try serializedXML(of: updatedDraft).contains(
                "<IconID>0</IconID><CustomIconUUID>\(chosen.kdbxBase64String)</CustomIconUUID>"
            ),
            "KeePass puts CustomIconUUID directly after IconID"
        )
    }

    /// Picking a second custom icon has to replace the element, not add one:
    /// two `<CustomIconUUID>` children are invalid and clients disagree on which
    /// of them wins.
    func test_setEntryIcon_customReplacesAnExistingElement() throws {
        let (draft, entryID) = try makeEntryIconDraft(customIconUUID: UUID())
        let chosen = UUID()

        let updatedDraft = try draft.apply(.setEntryIcon(entryID: entryID, icon: .custom(uuid: chosen)))

        let updated = try XCTUnwrap(findEntry(withID: entryID, in: updatedDraft.rootGroup))
        XCTAssertEqual(
            updated.unknownXML.nodes.filter { $0.elementName == "CustomIconUUID" }.count,
            1
        )
        XCTAssertEqual(updated.customIconUUID, chosen)
        let xml = try liveEntryXML(of: updatedDraft)
        XCTAssertEqual(xml.components(separatedBy: "<CustomIconUUID>").count - 1, 1)
        XCTAssertTrue(xml.contains(chosen.kdbxBase64String))
    }

    /// An icon change is an entry edit like any other, so it is undoable from
    /// the history viewer and records what other clients record.
    func test_setEntryIcon_pushesAHistoryVersionAndTouchesModificationTime() throws {
        let (draft, entryID) = try makeEntryIconDraft(iconID: 48)
        let original = try XCTUnwrap(findEntry(withID: entryID, in: draft.rootGroup))

        let updatedDraft = try draft.apply(.setEntryIcon(entryID: entryID, icon: .standard(iconID: 37)))

        let updated = try XCTUnwrap(findEntry(withID: entryID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updated.history.count, original.history.count + 1)
        XCTAssertEqual(updated.history.first?.iconID, 48, "the replaced icon is what a restore brings back")
        XCTAssertGreaterThan(
            try XCTUnwrap(updated.lastModificationTime),
            try XCTUnwrap(original.lastModificationTime)
        )
        XCTAssertTrue(updatedDraft.isDirty)
    }

    /// A parsable `<Binary>` advances the opaque-XML position space but not the
    /// attachment anchor, so an entry whose source put one before `<IconID>`
    /// shifts every later fragment by one. A fixed insertion index would write
    /// the new element ahead of `<IconID>` — or, with two such attachments, ahead
    /// of the attachment itself.
    func test_setEntryIcon_customLandsAfterIconIDEvenWithAnEarlyAttachment() throws {
        let entry = KPEntry(
            title: "Icon",
            password: try EncryptedValue.encrypt("pw", using: sessionKey),
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 0),
            attachments: [KPAttachment(name: "note.txt", ref: 0, insertionIndex: 1)]
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)
        let chosen = UUID()

        let updatedDraft = try draft.apply(.setEntryIcon(entryID: entry.id, icon: .custom(uuid: chosen)))

        XCTAssertTrue(
            try liveEntryXML(of: updatedDraft).contains(
                "<IconID>0</IconID><CustomIconUUID>\(chosen.kdbxBase64String)</CustomIconUUID>"
            ),
            "the attachment's slot must be counted, or the element lands before IconID"
        )
    }

    func test_setEntryIcon_unknownEntry_throws() throws {
        let (draft, _) = try makeEntryIconDraft()
        let missingEntryID = UUID()

        XCTAssertThrowsError(
            try draft.apply(.setEntryIcon(entryID: missingEntryID, icon: .standard(iconID: 37)))
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .entryNotFound(missingEntryID))
        }
    }

    // MARK: - Add entry custom icon

    private let downloadedIconData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// The stored dictionary is what the UI reads before the next save; the
    /// preserved XML is what the writer emits. An icon that reaches only one of
    /// them either vanishes on save or shows up as a blank cell until then.
    func test_addEntryCustomIcon_storesTheImageInBothMetaRepresentations() throws {
        let (draft, entryID) = try makeEntryIconDraft()
        let iconUUID = UUID()

        let updatedDraft = try draft.apply(
            .addEntryCustomIcon(entryID: entryID, iconUUID: iconUUID, imageData: downloadedIconData)
        )

        XCTAssertEqual(updatedDraft.meta.customIcons[iconUUID], downloadedIconData)
        let fragment = try XCTUnwrap(
            updatedDraft.meta.unknownXML.nodes.first { $0.elementName == "CustomIcons" }?.xml
        )
        XCTAssertTrue(fragment.contains(downloadedIconData.base64EncodedString()))
        XCTAssertTrue(fragment.contains(iconUUID.kdbxBase64String))
    }

    func test_addEntryCustomIcon_pointsTheEntryAtTheStoredIcon() throws {
        let (draft, entryID) = try makeEntryIconDraft(iconID: 48)
        let iconUUID = UUID()

        let updatedDraft = try draft.apply(
            .addEntryCustomIcon(entryID: entryID, iconUUID: iconUUID, imageData: downloadedIconData)
        )

        let updated = try XCTUnwrap(findEntry(withID: entryID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updated.customIconUUID, iconUUID)
        XCTAssertEqual(updated.iconID, 48, "the standard icon it overrides is left alone")
        XCTAssertEqual(updated.history.count, 1, "an icon change is an entry edit like any other")
        XCTAssertTrue(
            try liveEntryXML(of: updatedDraft).contains(
                "<IconID>48</IconID><CustomIconUUID>\(iconUUID.kdbxBase64String)</CustomIconUUID>"
            )
        )
    }

    /// The same favicon downloaded onto three entries has to leave one icon in
    /// the file, not three — KeePass's icon dialog shows the whole set, so
    /// duplicates are visible clutter as well as wasted bytes.
    func test_addEntryCustomIcon_reusesAnIdenticalImageAlreadyInTheDatabase() throws {
        let (draft, firstEntryID) = try makeEntryIconDraft()
        let seeded = try draft.apply(
            .createEntry(parentGroupID: draft.rootGroup.id, draft: EntryDraftPayload(title: "Second"))
        )
        let secondID = try XCTUnwrap(seeded.rootGroup.entries.first { $0.title == "Second" }?.id)

        let firstUUID = UUID()
        let afterFirst = try seeded.apply(
            .addEntryCustomIcon(entryID: firstEntryID, iconUUID: firstUUID, imageData: downloadedIconData)
        )
        let afterSecond = try afterFirst.apply(
            .addEntryCustomIcon(entryID: secondID, iconUUID: UUID(), imageData: downloadedIconData)
        )

        XCTAssertEqual(afterSecond.meta.customIcons.count, 1)
        XCTAssertEqual(
            findEntry(withID: secondID, in: afterSecond.rootGroup)?.customIconUUID,
            firstUUID,
            "the second entry points at the icon the first one stored"
        )
        let fragment = try XCTUnwrap(
            afterSecond.meta.unknownXML.nodes.first { $0.elementName == "CustomIcons" }?.xml
        )
        XCTAssertEqual(fragment.components(separatedBy: "<Icon>").count - 1, 1)
    }

    /// A foreign database can hold the same image bytes under two UUIDs — the
    /// parser stores what the file says and does not dedupe by value. Picking
    /// whichever one `Dictionary` iteration happened to yield first would make
    /// the same edit on the same input produce different file bytes from one
    /// launch to the next, against `EntryEdit`'s own pure-function contract.
    func test_addEntryCustomIcon_picksTheSameDuplicateEveryTime() throws {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!

        for _ in 0..<20 {
            let (base, entryID) = try makeEntryIconDraft()
            var meta = base.meta
            meta.customIcons = [lower: downloadedIconData, higher: downloadedIconData]
            let draft = DatabaseDraft(rootGroup: base.rootGroup, meta: meta, sessionKey: sessionKey)

            let updated = try draft.apply(
                .addEntryCustomIcon(entryID: entryID, iconUUID: UUID(), imageData: downloadedIconData)
            )

            XCTAssertEqual(findEntry(withID: entryID, in: updated.rootGroup)?.customIconUUID, lower)
            XCTAssertEqual(updated.meta.customIcons.count, 2, "neither duplicate is rewritten")
        }
    }

    /// The preserved fragment is the only copy of the icons a foreign database
    /// carries. One this cannot splice into is one it does not understand, and
    /// rebuilding the element from the decoded dictionary would drop every icon
    /// whose bytes this app does not model. Refusing the edit costs the user one
    /// icon; the alternative costs them all of them, silently, on the next save.
    func test_addEntryCustomIcon_refusesAFragmentItCannotSpliceInto() throws {
        let (base, entryID) = try makeEntryIconDraft()
        var meta = base.meta
        meta.unknownXML.append(xml: "<CustomIcons/>", insertionIndex: 0)
        let draft = DatabaseDraft(rootGroup: base.rootGroup, meta: meta, sessionKey: sessionKey)

        XCTAssertThrowsError(
            try draft.apply(
                .addEntryCustomIcon(entryID: entryID, iconUUID: UUID(), imageData: downloadedIconData)
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .customIconNotStorable)
        }
        XCTAssertEqual(
            draft.meta.unknownXML.nodes.first { $0.elementName == "CustomIcons" }?.xml,
            "<CustomIcons/>",
            "the fragment it refused to touch is left exactly as it was"
        )
    }

    func test_addEntryCustomIcon_unknownEntry_leavesTheDatabaseAlone() throws {
        let (draft, _) = try makeEntryIconDraft()
        let missingEntryID = UUID()

        XCTAssertThrowsError(
            try draft.apply(
                .addEntryCustomIcon(
                    entryID: missingEntryID,
                    iconUUID: UUID(),
                    imageData: downloadedIconData
                )
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .entryNotFound(missingEntryID))
        }
        XCTAssertTrue(draft.meta.customIcons.isEmpty, "a failed edit must not leave an orphaned icon behind")
    }

    // MARK: - Update group

    func test_updateGroup_renamesGroupKeepingIdentityAndChildren_andTouchesModificationTime() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        let originalEntryIDs = originalGroup.entries.map(\.id)
        let originalSubgroupIDs = originalGroup.groups.map(\.id)

        let updatedDraft = try draft.apply(
            .updateGroup(
                groupID: tree.parentGroupID,
                draft: GroupDraftPayload(name: "  Renamed Parent  ", iconID: originalGroup.iconID)
            )
        )

        let updatedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedGroup.name, "Renamed Parent", "The name is trimmed, the way applyCreateGroup trims it")
        XCTAssertEqual(updatedGroup.id, originalGroup.id)
        XCTAssertEqual(updatedGroup.entries.map(\.id), originalEntryIDs)
        XCTAssertEqual(updatedGroup.groups.map(\.id), originalSubgroupIDs)
        XCTAssertEqual(updatedGroup.creationTime, originalGroup.creationTime)
        XCTAssertGreaterThan(
            try XCTUnwrap(updatedGroup.lastModificationTime),
            try XCTUnwrap(originalGroup.lastModificationTime)
        )
        XCTAssertTrue(updatedDraft.isDirty)
    }

    func test_updateGroup_renameCollidingWithASibling_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let visibleRootID = try XCTUnwrap(tree.rootGroup.groups.first?.id)

        // "pàrent" differs from the sibling "Parent" only by case and a
        // diacritic — the same comparison applyCreateGroup rejects on.
        XCTAssertThrowsError(
            try draft.apply(
                .updateGroup(groupID: tree.untouchedGroupID, draft: GroupDraftPayload(name: "pàrent"))
            )
        ) { error in
            XCTAssertEqual(
                error as? DatabaseDraft.DraftError,
                .duplicateGroupName(parentGroupID: visibleRootID, name: "pàrent")
            )
        }
        XCTAssertFalse(draft.isDirty)
    }

    /// The sibling scan has to exclude the group being edited, or every save
    /// from the group editor that leaves the name alone reads as a collision.
    func test_updateGroup_savingAGroupUnderItsOwnCurrentNameIsAllowed() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let unchanged = try draft.apply(
            .updateGroup(
                groupID: tree.parentGroupID,
                draft: GroupDraftPayload(name: "Parent", notes: "same name, new notes")
            )
        )
        let unchangedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: unchanged.rootGroup))
        XCTAssertEqual(unchangedGroup.name, "Parent")
        XCTAssertEqual(unchangedGroup.notes, "same name, new notes")

        let recased = try unchanged.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "PARENT"))
        )
        let recasedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: recased.rootGroup))
        XCTAssertEqual(recasedGroup.name, "PARENT", "A case-only change of its own name is not a collision either")
    }

    func test_updateGroup_emptyName_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        XCTAssertThrowsError(
            try draft.apply(
                .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "   "))
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .emptyGroupName(tree.parentGroupID))
        }
        XCTAssertFalse(draft.isDirty)
    }

    func test_updateGroup_tagsAddedChangedAndCleared() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let added = try draft.apply(
            .updateGroup(
                groupID: tree.parentGroupID,
                draft: GroupDraftPayload(name: "Parent", tags: [" team ", "shared,shared"])
            )
        )
        let addedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: added.rootGroup))
        XCTAssertEqual(
            addedGroup.tags,
            ["team", "shared"],
            "Incoming tags go through TagNormalizer, so separators and duplicates cannot smuggle in"
        )

        let changed = try added.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "Parent", tags: ["ops"]))
        )
        let changedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: changed.rootGroup))
        XCTAssertEqual(changedGroup.tags, ["ops"])

        let cleared = try changed.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "Parent", tags: []))
        )
        let clearedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: cleared.rootGroup))
        XCTAssertTrue(clearedGroup.tags.isEmpty)
    }

    /// The serializer writes `<Tags>` for any non-empty list, so `hasTagsElement`
    /// keeps meaning "the source file had the element". Raising it on an edit
    /// would leave an empty `<Tags></Tags>` behind on a group that never had one
    /// as soon as the user cleared the tags again.
    func test_updateGroup_neverInventsATagsElementOnAGroupThatNeverHadOne() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        XCTAssertFalse(originalGroup.hasTagsElement, "Precondition: the group has no <Tags> element")

        let tagged = try draft.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "Parent", tags: ["team"]))
        )
        let taggedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tagged.rootGroup))
        XCTAssertEqual(taggedGroup.tags, ["team"])
        XCTAssertFalse(taggedGroup.hasTagsElement)

        let cleared = try tagged.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "Parent", tags: []))
        )
        let clearedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: cleared.rootGroup))
        XCTAssertTrue(clearedGroup.tags.isEmpty)
        XCTAssertFalse(
            clearedGroup.hasTagsElement,
            "A group that never had <Tags> and has no tags must not gain an empty element"
        )
    }

    func test_updateGroup_keepsAnAlreadyEmptyTagsElementWhenTagsAreCleared() throws {
        let group = KPGroup(
            name: "Had Empty Tags",
            tags: ["team"],
            hasTagsElement: true,
            lastModificationTime: Date(timeIntervalSince1970: 0)
        )
        let root = KPGroup(name: "Root", groups: [group])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        let updatedDraft = try draft.apply(
            .updateGroup(groupID: group.id, draft: GroupDraftPayload(name: "Had Empty Tags", tags: []))
        )

        let updatedGroup = try XCTUnwrap(findGroup(withID: group.id, in: updatedDraft.rootGroup))
        XCTAssertTrue(updatedGroup.tags.isEmpty)
        XCTAssertTrue(
            updatedGroup.hasTagsElement,
            "The source file's own empty <Tags></Tags> is preserved, not deleted by an unrelated edit"
        )
    }

    func test_updateGroup_notesSetChangedAndCleared() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let originalGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        XCTAssertFalse(originalGroup.hasNotesElement, "Precondition: the group has no <Notes> element")

        let set = try draft.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "Parent", notes: "First note"))
        )
        let setGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: set.rootGroup))
        XCTAssertEqual(setGroup.notes, "First note")
        XCTAssertTrue(setGroup.hasNotesElement)

        let changed = try set.apply(
            .updateGroup(
                groupID: tree.parentGroupID,
                draft: GroupDraftPayload(name: "Parent", notes: "  Second note\n")
            )
        )
        let changedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: changed.rootGroup))
        XCTAssertEqual(changedGroup.notes, "  Second note\n", "Group notes are free text and are stored untrimmed")

        let cleared = try changed.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "Parent", notes: ""))
        )
        let clearedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: cleared.rootGroup))
        XCTAssertTrue(clearedGroup.notes.isEmpty)
        XCTAssertTrue(
            clearedGroup.hasNotesElement,
            "Once the element exists it stays, the same three-state rule an empty <Tags></Tags> follows"
        )
    }

    func test_updateGroup_leavesTheNotesElementAbsentWhenNotesStayEmpty() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updatedDraft = try draft.apply(
            .updateGroup(groupID: tree.parentGroupID, draft: GroupDraftPayload(name: "Renamed", notes: ""))
        )

        let updatedGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updatedDraft.rootGroup))
        XCTAssertTrue(updatedGroup.notes.isEmpty)
        XCTAssertFalse(updatedGroup.hasNotesElement, "A rename must not invent a <Notes> element")
    }

    /// Deliberately asymmetric with `setGroupIcon`, which drops the custom icon
    /// unconditionally because the user just picked a standard one. The group
    /// editor submits the whole form, so renaming a group or editing its notes
    /// must leave a custom icon it never touched exactly where it was.
    func test_updateGroup_preservesTheCustomIconWhenTheIconIDIsUnchanged() throws {
        let customIconUUID = UUID()
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<CustomIconUUID>3q2+7w==</CustomIconUUID>", insertionIndex: 0)
        let group = KPGroup(
            name: "Has Custom Icon",
            iconID: 48,
            customIconUUID: customIconUUID,
            lastModificationTime: Date(timeIntervalSince1970: 0),
            unknownXML: unknownXML
        )
        let root = KPGroup(name: "Root", groups: [group])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        let updatedDraft = try draft.apply(
            .updateGroup(groupID: group.id, draft: GroupDraftPayload(name: "Renamed", iconID: 48))
        )

        let updatedGroup = try XCTUnwrap(findGroup(withID: group.id, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedGroup.name, "Renamed")
        XCTAssertEqual(updatedGroup.customIconUUID, customIconUUID)
        XCTAssertTrue(
            updatedGroup.unknownXML.nodes.contains { $0.elementName == "CustomIconUUID" },
            "The preserved element is what actually renders the custom icon in every client"
        )
    }

    func test_updateGroup_dropsTheCustomIconWhenTheIconIDChanges() throws {
        let customIconUUID = UUID()
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<CustomIconUUID>3q2+7w==</CustomIconUUID>", insertionIndex: 0)
        let group = KPGroup(
            name: "Has Custom Icon",
            iconID: 48,
            customIconUUID: customIconUUID,
            lastModificationTime: Date(timeIntervalSince1970: 0),
            unknownXML: unknownXML
        )
        let root = KPGroup(name: "Root", groups: [group])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        let updatedDraft = try draft.apply(
            .updateGroup(groupID: group.id, draft: GroupDraftPayload(name: "Has Custom Icon", iconID: 37))
        )

        let updatedGroup = try XCTUnwrap(findGroup(withID: group.id, in: updatedDraft.rootGroup))
        XCTAssertEqual(updatedGroup.iconID, 37)
        XCTAssertNil(updatedGroup.customIconUUID)
        XCTAssertFalse(
            updatedGroup.unknownXML.nodes.contains { $0.elementName == "CustomIconUUID" },
            "A <CustomIconUUID> outranks <IconID>, so the newly chosen icon would never show"
        )
    }

    func test_updateGroup_setsAndClearsSearchingEnabled() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let hidden = try draft.apply(
            .updateGroup(
                groupID: tree.parentGroupID,
                draft: GroupDraftPayload(name: "Parent", searchingEnabled: .disabled)
            )
        )
        let hiddenGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: hidden.rootGroup))
        XCTAssertEqual(hiddenGroup.searchingEnabled, .disabled)

        let restored = try hidden.apply(
            .updateGroup(
                groupID: tree.parentGroupID,
                draft: GroupDraftPayload(name: "Parent", searchingEnabled: nil)
            )
        )
        let restoredGroup = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: restored.rootGroup))
        XCTAssertNil(
            restoredGroup.searchingEnabled,
            "A nil selection means \"no element\", not an explicit inherit"
        )
    }

    /// An `<EnableSearching>` the parser could not read stays in `unknownXML`.
    /// Only an edit that actually supplies a structured value may drop it —
    /// otherwise saving the group editor with the visibility control untouched
    /// would silently destroy the original app's value.
    func test_updateGroup_keepsAnUnparsableEnableSearchingWhenTheDraftLeavesItInherited() throws {
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<EnableSearching>maybe</EnableSearching>", insertionIndex: 0)
        let group = KPGroup(
            name: "Weird",
            lastModificationTime: Date(timeIntervalSince1970: 0),
            unknownXML: unknownXML
        )
        let root = KPGroup(name: "Root", groups: [group])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        let renamed = try draft.apply(
            .updateGroup(groupID: group.id, draft: GroupDraftPayload(name: "Renamed", searchingEnabled: nil))
        )
        let renamedGroup = try XCTUnwrap(findGroup(withID: group.id, in: renamed.rootGroup))
        XCTAssertTrue(
            renamedGroup.unknownXML.nodes.contains { $0.xml.contains("maybe") },
            "The unparsable element must survive an edit that never touched it"
        )

        let hidden = try renamed.apply(
            .updateGroup(groupID: group.id, draft: GroupDraftPayload(name: "Renamed", searchingEnabled: .disabled))
        )
        let hiddenGroup = try XCTUnwrap(findGroup(withID: group.id, in: hidden.rootGroup))
        XCTAssertEqual(hiddenGroup.searchingEnabled, .disabled)
        XCTAssertFalse(
            hiddenGroup.unknownXML.nodes.contains { $0.elementName == "EnableSearching" },
            "Now that a structured value replaces it, the stale copy would be written twice"
        )
    }

    func test_updateGroup_unknownGroup_throws() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let missingGroupID = UUID()

        XCTAssertThrowsError(
            try draft.apply(.updateGroup(groupID: missingGroupID, draft: GroupDraftPayload(name: "Ghost")))
        ) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .groupNotFound(missingGroupID))
        }
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - LocationChanged maintenance

    /// Recycling is a move, so `<LocationChanged>` advances while
    /// `<LastModificationTime>` stays where it was — the distinction a merge
    /// needs to tell "the other side moved this" from "the other side edited it".
    func test_deleteEntry_softDelete_stampsLocationChangedAndLeavesModificationTimeAlone() throws {
        let previousMove = Date(timeIntervalSince1970: 3_000)
        let entry = KPEntry(
            title: "Recyclable",
            password: try EncryptedValue.encrypt("secret", using: sessionKey),
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 2_000),
            locationChanged: previousMove
        )
        let tree = try makeSyntheticTree(includeRecycleBin: true, parentEntryOverride: entry)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let beforeDelete = Date.now

        let updated = try draft.apply(.deleteEntry(entryID: entry.id, sendToRecycleBin: true))
        let recycled = try XCTUnwrap(findEntry(withID: entry.id, in: updated.rootGroup))

        let moved = try XCTUnwrap(recycled.locationChanged)
        XCTAssertGreaterThanOrEqual(moved, beforeDelete)
        XCTAssertGreaterThan(moved, previousMove)
        XCTAssertEqual(recycled.lastModificationTime, entry.lastModificationTime)
        XCTAssertEqual(recycled.creationTime, entry.creationTime)

        var normalized = recycled
        normalized.locationChanged = entry.locationChanged
        try assertEntriesEqual(normalized, entry)
    }

    func test_deleteEntry_softDelete_lazyRecycleBin_stampsBothTheEntryAndTheNewBin() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let beforeDelete = Date.now

        let updated = try draft.apply(.deleteEntry(entryID: tree.parentEntry.id, sendToRecycleBin: true))
        let recycled = try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updated.rootGroup))
        let binID = try XCTUnwrap(updated.meta.recycleBinUUID)
        let bin = try XCTUnwrap(findGroup(withID: binID, in: updated.rootGroup))

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(recycled.locationChanged), beforeDelete)
        // A group KeeForge itself creates has always lived where it was made.
        XCTAssertEqual(bin.locationChanged, bin.creationTime)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(bin.locationChanged), beforeDelete)
    }

    func test_deleteGroup_softDelete_stampsLocationChangedOnTheMovedGroupOnly() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let original = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: tree.rootGroup))
        let originalChildID = try XCTUnwrap(original.groups.first?.id)
        let beforeDelete = Date.now

        let updated = try draft.apply(.deleteGroup(groupID: tree.parentGroupID, sendToRecycleBin: true))
        let moved = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updated.rootGroup))

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(moved.locationChanged), beforeDelete)
        XCTAssertEqual(moved.lastModificationTime, original.lastModificationTime)
        // The subtree travelled with its parent; nothing inside it moved
        // relative to the group that contains it.
        let movedChild = try XCTUnwrap(findGroup(withID: originalChildID, in: updated.rootGroup))
        XCTAssertNil(movedChild.locationChanged)
        XCTAssertNil(try XCTUnwrap(findEntry(withID: tree.parentEntry.id, in: updated.rootGroup)).locationChanged)
    }

    func test_hardDelete_leavesSurvivingObjectsLocationChangedAlone() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: true)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)
        let recycleBinGroupID = try XCTUnwrap(tree.recycleBinGroupID)

        let updated = try draft.apply(.deleteEntry(entryID: tree.parentEntry.id, sendToRecycleBin: false))

        XCTAssertNil(try XCTUnwrap(findGroup(withID: recycleBinGroupID, in: updated.rootGroup)).locationChanged)
        XCTAssertNil(try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updated.rootGroup)).locationChanged)
    }

    func test_createEntryAndCreateGroup_stampLocationChangedWithCreationTime() throws {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let draft = DatabaseDraft(rootGroup: tree.rootGroup, meta: tree.meta, sessionKey: sessionKey)

        let updated = try draft
            .apply(.createEntry(parentGroupID: tree.parentGroupID, draft: EntryDraftPayload(title: "Fresh Entry")))
            .apply(.createGroup(parentGroupID: tree.parentGroupID, name: "Fresh Group"))

        let parent = try XCTUnwrap(findGroup(withID: tree.parentGroupID, in: updated.rootGroup))
        let createdEntry = try XCTUnwrap(parent.entries.first { $0.title == "Fresh Entry" })
        let createdGroup = try XCTUnwrap(parent.groups.first { $0.name == "Fresh Group" })

        XCTAssertNotNil(createdEntry.locationChanged)
        XCTAssertEqual(createdEntry.locationChanged, createdEntry.creationTime)
        XCTAssertNotNil(createdGroup.locationChanged)
        XCTAssertEqual(createdGroup.locationChanged, createdGroup.creationTime)
    }

    func test_editsThatDoNotReparent_leaveLocationChangedUntouched() throws {
        let previousMove = Date(timeIntervalSince1970: 3_000)
        let entry = KPEntry(
            title: "Settled",
            password: try EncryptedValue.encrypt("secret", using: sessionKey),
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 2_000),
            locationChanged: previousMove
        )
        let groupID = UUID()
        let group = KPGroup(
            id: groupID,
            name: "Settled Group",
            entries: [entry],
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 2_000),
            locationChanged: previousMove
        )
        let root = KPGroup(name: "Root", groups: [group])
        let draft = DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: sessionKey)

        var payload = try makeDraftPayload(from: entry)
        payload.notes = "edited"

        let updated = try draft
            .apply(.updateEntry(entryID: entry.id, draft: payload))
            .apply(.updateGroup(groupID: groupID, draft: GroupDraftPayload(name: "Renamed", searchingEnabled: nil)))
            .apply(.setGroupIcon(groupID: groupID, iconID: 37))
            .apply(.setEntryIcon(entryID: entry.id, icon: .standard(iconID: 12)))
            .apply(.restoreEntryVersion(entryID: entry.id, historyIndex: 0))

        XCTAssertEqual(try XCTUnwrap(findEntry(withID: entry.id, in: updated.rootGroup)).locationChanged, previousMove)
        XCTAssertEqual(try XCTUnwrap(findGroup(withID: groupID, in: updated.rootGroup)).locationChanged, previousMove)
    }

    func test_deepCopy_carriesLocationChangedThroughTheWholeSubtree() throws {
        let moved = Date(timeIntervalSince1970: 4_000)
        let child = KPGroup(
            name: "Child",
            entries: [KPEntry(title: "Nested", locationChanged: moved)],
            locationChanged: moved,
            unknownXML: OpaqueXMLNodes(nodes: [
                OpaqueXMLNodes.Node(path: ["Times"], insertionIndex: 2, xml: "<UsageCount>3</UsageCount>")
            ])
        )
        let root = KPGroup(name: "Root", groups: [child], locationChanged: moved)

        let copy = root.deepCopy()
        let copiedChild = try XCTUnwrap(copy.groups.first)

        XCTAssertEqual(copy.locationChanged, moved)
        XCTAssertEqual(copiedChild.locationChanged, moved)
        XCTAssertEqual(try XCTUnwrap(copiedChild.entries.first).locationChanged, moved)
        XCTAssertEqual(copiedChild.unknownXML, child.unknownXML)

        copiedChild.locationChanged = nil
        XCTAssertEqual(child.locationChanged, moved, "The copy must not share storage with the original")
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

    private func historyVersion(
        _ title: String,
        at seconds: TimeInterval?,
        notes: String = ""
    ) throws -> KPEntry {
        KPEntry(
            id: UUID(),
            title: title,
            password: try EncryptedValue.encrypt("history", using: sessionKey),
            notes: notes,
            lastModificationTime: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// Edits the synthetic tree's entry so its pre-edit state ("Original Entry") is
    /// pushed onto `history` and the trim runs.
    private func applyTitleEdit(
        toEntryWithHistory history: [KPEntry],
        meta: KPMeta
    ) throws -> KPEntry {
        let tree = try makeSyntheticTree(includeRecycleBin: false)
        let treeWithHistory = try makeSyntheticTree(
            includeRecycleBin: false,
            parentEntryOverride: withUpdatedEntry(tree.parentEntry, history: history),
            metaOverride: meta
        )
        var payload = try makeDraftPayload(from: treeWithHistory.parentEntry)
        payload.title = "Updated Title"

        let draft = DatabaseDraft(
            rootGroup: treeWithHistory.rootGroup,
            meta: treeWithHistory.meta,
            sessionKey: sessionKey
        )
        let updatedDraft = try draft.apply(
            .updateEntry(entryID: treeWithHistory.parentEntry.id, draft: payload)
        )
        return try XCTUnwrap(findEntry(withID: treeWithHistory.parentEntry.id, in: updatedDraft.rootGroup))
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
        XCTAssertEqual(lhs.locationChanged, rhs.locationChanged, file: file, line: line)
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
        XCTAssertEqual(lhs.locationChanged, rhs.locationChanged, file: file, line: line)
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
