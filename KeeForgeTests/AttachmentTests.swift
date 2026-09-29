import CryptoKit
import XCTest
@testable import KeeForge

final class AttachmentTests: XCTestCase {
    private let sessionKey = SymmetricKey(size: .bits256)

    // MARK: - BinaryPool

    func test_binaryPool_decodesProtectedFlagAndStripsIt() throws {
        let protectedRaw = Data([0x01]) + Data("secret-bytes".utf8)
        let unprotectedRaw = Data([0x00]) + Data("plain-bytes".utf8)
        let pool = BinaryPool(rawFields: [protectedRaw, unprotectedRaw])

        XCTAssertEqual(pool.count, 2)
        XCTAssertFalse(pool.isEmpty)

        let protectedItem = try XCTUnwrap(pool[0])
        XCTAssertTrue(protectedItem.isProtected)
        XCTAssertEqual(protectedItem.data, Data("secret-bytes".utf8))

        let unprotectedItem = try XCTUnwrap(pool[1])
        XCTAssertFalse(unprotectedItem.isProtected)
        XCTAssertEqual(unprotectedItem.data, Data("plain-bytes".utf8))
    }

    func test_binaryPool_outOfRangeRefReturnsNil() {
        let pool = BinaryPool(rawFields: [Data([0x00]) + Data("only-item".utf8)])
        XCTAssertNil(pool[1])
        XCTAssertNil(pool[-1])
    }

    func test_binaryPool_emptyRawFieldDecodesToEmptyUnprotectedItem() throws {
        let pool = BinaryPool(rawFields: [Data()])
        let item = try XCTUnwrap(pool[0])
        XCTAssertFalse(item.isProtected)
        XCTAssertTrue(item.data.isEmpty)
    }

    // MARK: - Fixture-backed parsing

    func test_kitchenSinkFixture_parsesRoundTripAttachmentsStructurally() throws {
        let parsed = try KDBXTestFixture.kitchenSink.parse(in: Bundle(for: Self.self), sessionKey: sessionKey)

        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "Controlled Unknowns" })
        // Compare names and pool content, not literal refs or insertionIndex:
        // both are positional metadata recorded from the fixture's actual
        // `<Binary>` placement, not values this test should hardcode.
        XCTAssertEqual(entry.attachments.map(\.name), ["round-trip.txt"])
        XCTAssertEqual(entry.history.first?.attachments.map(\.name), ["round-trip.txt"])
        XCTAssertEqual(entry.history.first?.attachments.map(\.ref), entry.attachments.map(\.ref))

        let pool = BinaryPool(rawFields: parsed.header.innerHeaderBinaryFields)
        let attachment = try XCTUnwrap(entry.attachments.first)
        let item = try XCTUnwrap(pool[attachment.ref])
        XCTAssertEqual(item.data, Data("round-trip-attachment-bytes".utf8))
    }

    // MARK: - Synthetic round-trip: multiple binaries, history, dangling ref

    func test_writeAndReparse_preservesAttachmentsPoolContentsAndDanglingRefs() throws {
        let compositeKey = KDBXCrypto.compositeKey(password: "attachment-test-password")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let protectedBinary = Data([0x01]) + Data("protected-attachment-bytes".utf8)
        let plainBinary = Data([0x00]) + Data("plain-attachment-bytes".utf8)

        let historyEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000401")!,
            title: "Attachment Entry",
            password: try EncryptedValue.encrypt("old-password", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            attachments: [KPAttachment(name: "history-file.txt", ref: 1)]
        )

        let entry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000401")!,
            title: "Attachment Entry",
            password: try EncryptedValue.encrypt("current-password", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            history: [historyEntry],
            attachments: [
                KPAttachment(name: "protected.bin", ref: 0),
                KPAttachment(name: "plain.txt", ref: 1),
                // Dangling ref: no pool entry at index 5.
                KPAttachment(name: "missing.dat", ref: 5),
            ]
        )

        let root = KPGroup(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000400")!,
            name: "Root",
            entries: [entry]
        )

        let meta = KPMeta(
            maintenanceHistoryDays: KPMeta.defaultMaintenanceHistoryDays,
            historyMaxItems: KPMeta.defaultHistoryMaxItems,
            historyMaxSize: KPMeta.defaultHistoryMaxSize
        )

        let written = try KDBXWriter.write(
            rootGroup: root,
            meta: meta,
            compositeKey: compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.aesCipherUUID,
                kdfParameters: KDBXCompatibilitySupport.fastArgon2idParameters(),
                innerHeaderBinaryFields: [protectedBinary, plainBinary]
            ),
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )

        let reparsedEntry = try XCTUnwrap(reparsed.rootGroup.entries.first)
        // Compare name/ref only: insertionIndex is positional metadata
        // assigned from the serialized document order, not a value this test
        // should hardcode.
        XCTAssertEqual(
            reparsedEntry.attachments.map(\.name),
            ["protected.bin", "plain.txt", "missing.dat"]
        )
        XCTAssertEqual(reparsedEntry.attachments.map(\.ref), [0, 1, 5])

        let reparsedHistoryEntry = try XCTUnwrap(reparsedEntry.history.first)
        XCTAssertEqual(reparsedHistoryEntry.attachments.map(\.name), ["history-file.txt"])
        XCTAssertEqual(reparsedHistoryEntry.attachments.map(\.ref), [1])

        let pool = BinaryPool(rawFields: reparsed.header.innerHeaderBinaryFields)
        XCTAssertEqual(pool.count, 2)

        let protectedItem = try XCTUnwrap(pool[0])
        XCTAssertTrue(protectedItem.isProtected)
        XCTAssertEqual(protectedItem.data, Data("protected-attachment-bytes".utf8))

        let plainItem = try XCTUnwrap(pool[1])
        XCTAssertFalse(plainItem.isProtected)
        XCTAssertEqual(plainItem.data, Data("plain-attachment-bytes".utf8))

        // Dangling ref tolerated, not resolvable against the pool.
        XCTAssertNil(pool[5])

        // Editing the entry via DatabaseDraft preserves attachments even
        // though EntryDraftPayload has no attachment field in Phase 1.
        let draft = DatabaseDraft(rootGroup: reparsed.rootGroup, meta: reparsed.meta, sessionKey: sessionKey)
        let updatedPayload = EntryDraftPayload(
            title: "Attachment Entry Updated",
            username: reparsedEntry.username,
            password: "current-password",
            url: reparsedEntry.url,
            notes: reparsedEntry.notes,
            customFields: reparsedEntry.customFields,
            tags: reparsedEntry.tags
        )
        let updatedDraft = try draft.apply(.updateEntry(entryID: reparsedEntry.id, draft: updatedPayload))
        let updatedEntry = try XCTUnwrap(updatedDraft.rootGroup.entries.first { $0.id == reparsedEntry.id })

        XCTAssertEqual(updatedEntry.attachments, reparsedEntry.attachments)
        XCTAssertEqual(updatedEntry.history.first?.attachments, reparsedEntry.attachments)

        let savedData = try KDBXWriter.write(
            rootGroup: updatedDraft.rootGroup,
            meta: updatedDraft.meta,
            compositeKey: compositeKey,
            header: reparsed.header,
            sessionKey: updatedDraft.writerSessionKey
        )
        let reparsedAfterSave = try KDBXParser.parseWithMetaAndHeader(
            data: savedData,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )
        let savedEntry = try XCTUnwrap(reparsedAfterSave.rootGroup.entries.first { $0.id == reparsedEntry.id })
        XCTAssertEqual(savedEntry.attachments, reparsedEntry.attachments)

        let poolAfterSave = BinaryPool(rawFields: reparsedAfterSave.header.innerHeaderBinaryFields)
        XCTAssertEqual(poolAfterSave.count, 2)
        XCTAssertEqual(poolAfterSave[0]?.data, Data("protected-attachment-bytes".utf8))
        XCTAssertEqual(poolAfterSave[1]?.data, Data("plain-attachment-bytes".utf8))
    }

    // MARK: - Editing attachments

    func test_addingAttachment_appendsProtectedPoolEntryKeepsHistoryAndRoundTrips() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry()

        let draft = try fixture.draft().apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: [
                .existing(name: "alpha.txt", ref: 0),
                .new(name: "bravo.pdf", data: Data("bravo-bytes".utf8)),
            ])
        ))

        let pool = try XCTUnwrap(draft.binaryPoolFields)
        XCTAssertEqual(pool, fixture.header.innerHeaderBinaryFields + [Data([0x01]) + Data("bravo-bytes".utf8)])
        let updated = try XCTUnwrap(draft.rootGroup.allEntries.first { $0.id == entry.id })
        XCTAssertEqual(updated.attachments.map(\.name), ["alpha.txt", "bravo.pdf"])
        XCTAssertEqual(updated.attachments.map(\.ref), [0, 1])
        XCTAssertEqual(updated.history.first?.attachments, entry.attachments)

        let reparsed = try fixture.writeAndReparse(draft)
        let saved = try XCTUnwrap(reparsed.rootGroup.allEntries.first { $0.id == entry.id })
        // Whole-value equality, insertion index included: the in-memory tree
        // has to match what the next parse of the saved file reports, or a
        // later merge sees a change that never happened.
        XCTAssertEqual(saved.attachments, updated.attachments)
        let savedPool = BinaryPool(rawFields: reparsed.header.innerHeaderBinaryFields)
        XCTAssertEqual(savedPool[saved.attachments[1].ref]?.data, Data("bravo-bytes".utf8))
        XCTAssertEqual(savedPool[saved.attachments[1].ref]?.isProtected, true)
        XCTAssertEqual(savedPool[saved.attachments[0].ref]?.data, Data("alpha-bytes".utf8))
    }

    func test_addingAttachment_toEntryWithoutAttachments_landsWhereTheParserReportsIt() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry(titled: "Bare")

        let draft = try fixture.draft().apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: [.new(name: "first.bin", data: Data("first".utf8))])
        ))
        let updated = try XCTUnwrap(draft.rootGroup.allEntries.first { $0.id == entry.id })

        let reparsed = try fixture.writeAndReparse(draft)
        let saved = try XCTUnwrap(reparsed.rootGroup.allEntries.first { $0.id == entry.id })
        XCTAssertEqual(saved.attachments, updated.attachments)
        XCTAssertEqual(saved.unknownXML, updated.unknownXML)
        XCTAssertEqual(saved.customFields, updated.customFields)
    }

    func test_creatingEntryWithAttachment_storesItAndRoundTrips() throws {
        let fixture = try makeEditableFixture()

        let draft = try fixture.draft().apply(.createEntry(
            parentGroupID: fixture.rootGroup.id,
            draft: EntryDraftPayload(
                title: "Created",
                password: "created-password",
                attachments: [.new(name: "created.txt", data: Data("created-bytes".utf8))]
            )
        ))
        let created = try XCTUnwrap(draft.rootGroup.allEntries.first { $0.title == "Created" })
        XCTAssertEqual(created.attachments.map(\.name), ["created.txt"])

        let reparsed = try fixture.writeAndReparse(draft)
        let saved = try XCTUnwrap(reparsed.rootGroup.allEntries.first { $0.title == "Created" })
        XCTAssertEqual(saved.attachments, created.attachments)
        let savedPool = BinaryPool(rawFields: reparsed.header.innerHeaderBinaryFields)
        XCTAssertEqual(savedPool[saved.attachments[0].ref]?.data, Data("created-bytes".utf8))
    }

    func test_addingBytesThePoolAlreadyHolds_reusesThatPoolEntry() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry(titled: "Bare")

        let draft = try fixture.draft().apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: [
                .new(name: "copy-of-alpha.txt", data: Data("alpha-bytes".utf8)),
                .new(name: "new.txt", data: Data("new-bytes".utf8)),
                .new(name: "new-again.txt", data: Data("new-bytes".utf8)),
            ])
        ))

        let updated = try XCTUnwrap(draft.rootGroup.allEntries.first { $0.id == entry.id })
        XCTAssertEqual(updated.attachments.map(\.ref), [0, 1, 1])
        XCTAssertEqual(draft.binaryPoolFields?.count, 2)
    }

    func test_removingAttachment_dropsTheReferenceButHistoryStillResolvesIt() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry()

        let draft = try fixture.draft().apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: [])
        ))

        let updated = try XCTUnwrap(draft.rootGroup.allEntries.first { $0.id == entry.id })
        XCTAssertTrue(updated.attachments.isEmpty)
        XCTAssertEqual(draft.binaryPoolFields, fixture.header.innerHeaderBinaryFields)

        let reparsed = try fixture.writeAndReparse(draft)
        let saved = try XCTUnwrap(reparsed.rootGroup.allEntries.first { $0.id == entry.id })
        XCTAssertTrue(saved.attachments.isEmpty)
        let historical = try XCTUnwrap(saved.history.first?.attachments.first)
        XCTAssertEqual(historical.name, "alpha.txt")
        let savedPool = BinaryPool(rawFields: reparsed.header.innerHeaderBinaryFields)
        XCTAssertEqual(savedPool[historical.ref]?.data, Data("alpha-bytes".utf8))
    }

    func test_nilAttachmentPayload_keepsTheEntrysAttachments() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry()

        let draft = try fixture.draft().apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: nil)
        ))

        let updated = try XCTUnwrap(draft.rootGroup.allEntries.first { $0.id == entry.id })
        XCTAssertEqual(updated.attachments, entry.attachments)
        XCTAssertEqual(draft.binaryPoolFields, fixture.header.innerHeaderBinaryFields)
    }

    func test_keepingAnAttachmentTheEntryNoLongerHas_throws() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry()

        XCTAssertThrowsError(try fixture.draft().apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: [.existing(name: "alpha.txt", ref: 7)])
        ))) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .attachmentNotFound(name: "alpha.txt"))
        }
    }

    func test_draftWithoutPool_refusesNewAttachmentsButStillRemovesThem() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry()
        let poolless = DatabaseDraft(rootGroup: fixture.rootGroup, meta: fixture.meta, sessionKey: sessionKey)

        XCTAssertThrowsError(try poolless.apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: [.new(name: "x.bin", data: Data("x".utf8))])
        ))) { error in
            XCTAssertEqual(error as? DatabaseDraft.DraftError, .attachmentPoolUnavailable)
        }

        let removed = try poolless.apply(.updateEntry(entryID: entry.id, draft: payload(for: entry, attachments: [])))
        XCTAssertNil(removed.binaryPoolFields)
    }

    func test_draftWithoutPool_writesThePoolOfTheHeaderItReplaces() throws {
        let fixture = try makeEditableFixture()
        let poolless = DatabaseDraft(rootGroup: fixture.rootGroup, meta: fixture.meta, sessionKey: sessionKey)

        let reparsed = try fixture.writeAndReparse(poolless)

        XCTAssertEqual(reparsed.header.innerHeaderBinaryFields, fixture.header.innerHeaderBinaryFields)
    }

    func test_discardingEdits_restoresTheOpenedPool() throws {
        let fixture = try makeEditableFixture()
        let entry = try fixture.entry()

        let edited = try fixture.draft().apply(.updateEntry(
            entryID: entry.id,
            draft: payload(for: entry, attachments: [.new(name: "b.bin", data: Data("b".utf8))])
        ))

        XCTAssertEqual(edited.discardingEdits().binaryPoolFields, fixture.header.innerHeaderBinaryFields)
    }

    private struct EditableFixture {
        let rootGroup: KPGroup
        let meta: KPMeta
        let header: KDBXParser.Header
        let compositeKey: SymmetricKey
        let sessionKey: SymmetricKey

        func entry(titled title: String = "With Attachment") throws -> KPEntry {
            try XCTUnwrap(rootGroup.allEntries.first { $0.title == title })
        }

        func draft() -> DatabaseDraft {
            DatabaseDraft(
                rootGroup: rootGroup,
                meta: meta,
                sessionKey: sessionKey,
                binaryPoolFields: header.innerHeaderBinaryFields
            )
        }

        func writeAndReparse(_ draft: DatabaseDraft) throws -> (rootGroup: KPGroup, meta: KPMeta, header: KDBXParser.Header) {
            let data = try draft.write(compositeKey: compositeKey, header: header, kdfPolicy: .mainApp)
            return try KDBXParser.parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
        }
    }

    /// A parsed database with one entry carrying a tag, a custom field, and an
    /// attachment, and one bare entry, so edits run against parser-recorded
    /// positions rather than hand-built ones.
    private func makeEditableFixture() throws -> EditableFixture {
        let compositeKey = KDBXCrypto.compositeKey(password: "attachment-edit-password")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let withAttachment = KPEntry(
            title: "With Attachment",
            username: "user",
            password: try EncryptedValue.encrypt("secret", using: sessionKey),
            tags: ["work"],
            hasTagsElement: true,
            customFields: ["PIN": "1234"],
            creationTime: timestamp,
            lastModificationTime: timestamp,
            attachments: [KPAttachment(name: "alpha.txt", ref: 0)]
        )
        let bare = KPEntry(
            title: "Bare",
            password: try EncryptedValue.encrypt("bare-secret", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp
        )
        let root = KPGroup(name: "Root", entries: [withAttachment, bare])
        let meta = KPMeta(
            maintenanceHistoryDays: KPMeta.defaultMaintenanceHistoryDays,
            historyMaxItems: KPMeta.defaultHistoryMaxItems,
            historyMaxSize: KPMeta.defaultHistoryMaxSize
        )
        let written = try KDBXWriter.write(
            rootGroup: root,
            meta: meta,
            compositeKey: compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.aesCipherUUID,
                kdfParameters: KDBXCompatibilitySupport.fastArgon2idParameters(),
                innerHeaderBinaryFields: [Data([0x00]) + Data("alpha-bytes".utf8)]
            ),
            sessionKey: sessionKey
        )
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: written, compositeKey: compositeKey, sessionKey: sessionKey)
        return EditableFixture(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            header: parsed.header,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )
    }

    private func payload(for entry: KPEntry, attachments: [EntryAttachmentPayload]?) throws -> EntryDraftPayload {
        EntryDraftPayload(
            title: entry.title,
            username: entry.username,
            password: try entry.password.decrypt(using: sessionKey),
            url: entry.url,
            notes: entry.notes,
            customFields: entry.customFields,
            tags: entry.tags,
            attachments: attachments
        )
    }

    func test_freshDatabaseCreation_defaultsToEmptyBinaryPool() throws {
        let compositeKey = KDBXCrypto.compositeKey(password: "fresh-password")
        let root = KPGroup(name: "Root")
        let meta = KPMeta()

        let written = try KDBXWriter.write(
            rootGroup: root,
            meta: meta,
            compositeKey: compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.aesCipherUUID,
                kdfParameters: KDBXCompatibilitySupport.fastArgon2idParameters()
            ),
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )

        XCTAssertTrue(reparsed.header.innerHeaderBinaryFields.isEmpty)
        XCTAssertTrue(BinaryPool(rawFields: reparsed.header.innerHeaderBinaryFields).isEmpty)
    }
}
