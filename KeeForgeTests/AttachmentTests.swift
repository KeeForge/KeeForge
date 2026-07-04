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

    func test_unknownElementsFixture_parsesAttachmentsStructurally() throws {
        let bundle = Bundle(for: Self.self)
        let databaseURL = try TestDatabaseSupport.fixtureURL(
            named: "unknown-elements",
            subdirectory: "round-trip",
            bundle: bundle
        )
        let data = try Data(contentsOf: databaseURL)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            password: "test-round-trip",
            sessionKey: sessionKey
        )

        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "Controlled Unknowns" })
        // Compare name/ref only: insertionIndex is positional metadata
        // recorded from the fixture's actual `<Binary>` placement, not a
        // value this test should hardcode.
        XCTAssertEqual(entry.attachments.map(\.name), ["round-trip.txt"])
        XCTAssertEqual(entry.attachments.map(\.ref), [0])
        XCTAssertEqual(entry.history.first?.attachments.map(\.name), ["round-trip.txt"])
        XCTAssertEqual(entry.history.first?.attachments.map(\.ref), [0])

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
                kdfParameters: fastArgon2idParameters(),
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
                kdfParameters: fastArgon2idParameters()
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

    private func fastArgon2idParameters() -> [String: Any] {
        [
            "$UUID": KDBXParser.argon2idUUID,
            "I": UInt64(2),
            "M": UInt64(1024 * 1024),
            "P": UInt32(1),
            "V": UInt32(0x13),
            "S": Data((0..<32).map { UInt8($0) }),
        ]
    }
}
