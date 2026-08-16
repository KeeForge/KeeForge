import CryptoKit
import XCTest
@testable import KeeForge

final class KDBXWriterTests: XCTestCase {
    private struct ParsedFixture {
        let rootGroup: KPGroup
        let meta: KPMeta
        let header: KDBXParser.Header
        let compositeKey: SymmetricKey
    }

    private let sessionKey = SymmetricKey(size: .bits256)

    func test_writeRoundTrip_test_kdbx_AES_returnsEqualTree() throws {
        let parsed = try parseFixture(.test)
        XCTAssertEqual(parsed.header.cipherID, KDBXParser.aesCipherUUID)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    @MainActor
    func testEditingKeeOTPWithWhitespacePreservesDecodedSecretAndAvoidsTimeOtpFields() throws {
        let parsed = try parseFixture(.test)
        let keeOTPQuery = "key=%20leading%20and%20trailing%20&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1"
        let originalSecret = " leading and trailing "
        let entry = KPEntry(
            title: "KeeOTP Entry",
            password: try EncryptedValue.encrypt("password", using: sessionKey),
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt(originalSecret, using: sessionKey),
                decodedSecret: try EncryptedValue.encrypt(Data(originalSecret.utf8), using: sessionKey),
                keeOTPSource: KeeOTPSource(fieldName: "OTP", rawQuery: keeOTPQuery)
            ),
            protectedStringKeys: ["OTP"]
        )
        var rootGroup = parsed.rootGroup
        rootGroup.entries.append(entry)

        let initialData = try KDBXWriter.write(
            rootGroup: rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )
        let initiallyParsed = try parseWrittenFile(initialData, fixture: .test)
        let parsedEntry = try XCTUnwrap(initiallyParsed.rootGroup.allEntries.first { $0.id == entry.id })

        let viewModel = EntryEditViewModel(editing: parsedEntry, sessionKey: sessionKey)
        viewModel.title = "Unrelated Edit"
        let draft = DatabaseDraft(rootGroup: initiallyParsed.rootGroup, meta: initiallyParsed.meta, sessionKey: sessionKey)
        let updatedDraft = try draft.apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        let savedData = try KDBXWriter.write(
            rootGroup: updatedDraft.rootGroup,
            meta: updatedDraft.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: updatedDraft.writerSessionKey
        )

        let savedXML = try XCTUnwrap(String(data: decryptWrittenXML(savedData, compositeKey: parsed.compositeKey), encoding: .utf8))
        XCTAssertTrue(
            savedXML.contains("<Key>OTP</Key><Value Protected=\"True\""),
            "The KeeOTP source field must keep its memory-protection flag across edits"
        )
        XCTAssertFalse(savedXML.contains("TimeOtp-"))

        let reloaded = try parseWrittenFile(savedData, fixture: .test)
        let reloadedEntry = try XCTUnwrap(reloaded.rootGroup.allEntries.first { $0.id == entry.id })
        let reloadedConfig = try XCTUnwrap(reloadedEntry.totpConfig)
        XCTAssertEqual(reloadedEntry.title, "Unrelated Edit")
        XCTAssertEqual(reloadedConfig.keeOTPSource?.rawQuery, keeOTPQuery)
        XCTAssertEqual(try reloadedConfig.secret.decrypt(using: sessionKey), originalSecret)
        XCTAssertEqual(try reloadedConfig.decodedSecret?.decryptData(using: sessionKey), Data(originalSecret.utf8))
    }

    func test_writeRoundTrip_demo_kdbx_returnsEqualTree() throws {
        let parsed = try parseFixture(.demo)
        XCTAssertEqual(parsed.header.cipherID, KDBXParser.aesCipherUUID)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let reparsed = try parseWrittenFile(written, fixture: .demo)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeRoundTrip_demoKeyfile_kdbx_returnsEqualTree() throws {
        let parsed = try parseFixture(.demoKeyfile)
        XCTAssertEqual(parsed.header.cipherID, KDBXParser.aesCipherUUID)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let reparsed = try parseWrittenFile(written, fixture: .demoKeyfile)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writtenFile_validatesOuterHeaderHMAC() throws {
        let parsed = try parseFixture(.unknownElements)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let fileComponents = try readWrittenFileComponents(written, compositeKey: parsed.compositeKey)
        XCTAssertEqual(fileComponents.storedHeaderSHA256, KDBXCrypto.sha256(fileComponents.headerBytes))
        XCTAssertEqual(
            fileComponents.storedHeaderHMAC,
            KDBXCrypto.hmacSHA256(
                key: KDBXParser.computeBlockHMACKey(
                    blockIndex: UInt64.max,
                    baseKey: fileComponents.hmacBaseKey
                ),
                data: fileComponents.headerBytes
            )
        )

        let reparsed = try parseWrittenFile(written, fixture: .unknownElements)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writtenFile_validatesPerBlockHMAC() throws {
        let parsed = try parseFixture(.test)
        // Use base64-encoded random bytes so gzip cannot compress below the 1 MB HMAC block size.
        var rng = [UInt8](repeating: 0, count: 1_500_000)
        _ = SecRandomCopyBytes(kSecRandomDefault, rng.count, &rng)
        let largeNotes = Data(rng).base64EncodedString()
        XCTAssertTrue(setNotes(largeNotes, forEntryTitled: "GitHub", in: parsed.rootGroup))

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        var reader = DataReader(data: written)
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()
        _ = try KDBXParser.parseHeader(&reader)
        _ = try reader.readBytes(32)
        _ = try reader.readBytes(32)

        let baseKey = try readWrittenFileComponents(written, compositeKey: parsed.compositeKey).hmacBaseKey
        let encryptedPayload = try KDBXParser.readHMACBlocks(reader: &reader, baseKey: baseKey)

        XCTAssertFalse(encryptedPayload.isEmpty)
        XCTAssertGreaterThan(try countPayloadBlocks(in: written), 1)
    }

    func test_writeWithChaCha20Cipher_roundTrip() throws {
        let parsed = try parseFixture(.test)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.chachaCipherUUID,
                kdfParameters: parsed.header.kdfParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        let fileComponents = try readWrittenFileComponents(written, compositeKey: parsed.compositeKey)
        XCTAssertEqual(fileComponents.header.cipherID, KDBXParser.chachaCipherUUID)
        let encryptedPayload = try readEncryptedPayload(
            from: written,
            payloadOffset: fileComponents.payloadOffset,
            hmacBaseKey: fileComponents.hmacBaseKey
        )
        let decryptedPayload = try decryptPayload(
            encryptedPayload,
            header: fileComponents.header,
            compositeKey: parsed.compositeKey
        )
        XCTAssertEqual(encryptedPayload.count, decryptedPayload.count)
        _ = try parseInnerPayload(decryptedPayload, header: fileComponents.header)

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeWithTwofish256CBCCipher_roundTrip() throws {
        let parsed = try parseFixture(.test)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.twofishCipherUUID,
                kdfParameters: parsed.header.kdfParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        let fileComponents = try readWrittenFileComponents(written, compositeKey: parsed.compositeKey)
        XCTAssertEqual(fileComponents.header.cipherID, KDBXParser.twofishCipherUUID)
        XCTAssertEqual(fileComponents.header.encryptionIV.count, 16)

        let encryptedPayload = try readEncryptedPayload(
            from: written,
            payloadOffset: fileComponents.payloadOffset,
            hmacBaseKey: fileComponents.hmacBaseKey
        )
        XCTAssertFalse(encryptedPayload.isEmpty)
        XCTAssertEqual(encryptedPayload.count % 16, 0)

        let decryptedPayload = try decryptPayload(
            encryptedPayload,
            header: fileComponents.header,
            compositeKey: parsed.compositeKey
        )
        _ = try parseInnerPayload(decryptedPayload, header: fileComponents.header)

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeWithTwofishReportedArgon2dProfile_roundTrip() throws {
        let parsed = try parseFixture(.test)
        let reportedKDFParameters: [String: Any] = [
            "$UUID": KDBXParser.argon2dUUID,
            "I": UInt64(3),
            "M": UInt64(16 * 1024 * 1024),
            "P": UInt32(4),
            "V": UInt32(0x13),
            "S": Data((0..<32).map(UInt8.init)),
        ]

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.twofishCipherUUID,
                kdfParameters: reportedKDFParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )
        XCTAssertEqual(reparsed.header.cipherID, KDBXParser.twofishCipherUUID)
        XCTAssertEqual(reparsed.header.kdfParameters["$UUID"] as? Data, KDBXParser.argon2dUUID)
        XCTAssertEqual(reparsed.header.kdfParameters["I"] as? UInt64, 3)
        XCTAssertEqual(reparsed.header.kdfParameters["M"] as? UInt64, 16 * 1024 * 1024)
        XCTAssertEqual(reparsed.header.kdfParameters["P"] as? UInt32, 4)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func test_writeReusedTwofishHeader_preservesNoCompression() throws {
        let parsed = try parseFixture(.test)
        var twofishHeader = parsed.header
        twofishHeader.cipherID = KDBXParser.twofishCipherUUID
        twofishHeader.compressionFlags = 0

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: twofishHeader,
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )
        XCTAssertEqual(reparsed.header.cipherID, KDBXParser.twofishCipherUUID)
        XCTAssertEqual(reparsed.header.compressionFlags, 0)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func test_writeWithArgon2idKDF_roundTrip() throws {
        let parsed = try parseFixture(.test)
        var argon2idHeader = parsed.header
        argon2idHeader.kdfParameters["$UUID"] = KDBXParser.argon2idUUID

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: argon2idHeader,
            sessionKey: sessionKey
        )

        let fileComponents = try readWrittenFileComponents(written, compositeKey: parsed.compositeKey)
        XCTAssertEqual(fileComponents.header.kdfParameters["$UUID"] as? Data, KDBXParser.argon2idUUID)

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeReusedHeader_preservesKDBX4MinorVersion() throws {
        let parsed = try parseFixture(.test)
        var kdbx41Header = parsed.header
        kdbx41Header.formatVersion = .kdbx4(minor: 1)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: kdbx41Header,
            sessionKey: sessionKey
        )

        XCTAssertEqual(try KDBXParser.parseFileVersion(from: written), .kdbx4(minor: 1))

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeReusedHeader_preservesUnknownOuterHeaderFields() throws {
        let parsed = try parseFixture(.test)
        let unknownFields = [
            KDBXParser.UnknownHeaderField(id: 12, data: Data("public-custom-data".utf8)),
            KDBXParser.UnknownHeaderField(id: 0x7F, data: Data([0x01, 0x02, 0x03])),
        ]
        var header = parsed.header
        header.unknownOuterHeaderFields = unknownFields

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: header,
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )

        XCTAssertEqual(reparsed.header.unknownOuterHeaderFields, unknownFields)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func test_writeReusedHeader_reemitsUnknownInnerHeaderFieldsBeforeTheBinaryPool() throws {
        let parsed = try parseFixture(.unknownInnerHeader)
        let sourceUnknownFields = [
            KDBXParser.UnknownHeaderField(id: 0x21, data: Data("mid-pool-unknown-field".utf8)),
            KDBXParser.UnknownHeaderField(
                id: 0x7F,
                data: Data("kdbx-format-hardening-fixture:unknown-field-0x7f-marker".utf8)
            ),
            KDBXParser.UnknownHeaderField(id: 0x10, data: Data()),
        ]
        XCTAssertEqual(parsed.header.unknownInnerHeaderFields, sourceUnknownFields)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        // Ordering contract: stream ID/key, then every unknown field in its
        // original relative order, then the pool — so the fixture's 0x21,
        // spliced between the two binary entries on disk, moves ahead of them.
        let items = try innerHeaderItems(of: written, compositeKey: parsed.compositeKey)
        XCTAssertEqual(items.map(\.id), [0x01, 0x02, 0x21, 0x7F, 0x10, 0x03, 0x03, 0x00])
        XCTAssertEqual(
            items.filter { !(0x00...0x03).contains($0.id) },
            sourceUnknownFields.map { InnerHeaderItem(id: $0.id, payload: $0.data) }
        )
        XCTAssertEqual(items.filter { $0.id == 0x03 }.map(\.payload), parsed.header.innerHeaderBinaryFields)

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )
        XCTAssertEqual(reparsed.header.unknownInnerHeaderFields, sourceUnknownFields)
        XCTAssertEqual(reparsed.header.innerHeaderBinaryFields, parsed.header.innerHeaderBinaryFields)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func test_writeReusedHeader_emitsNoUnknownInnerHeaderFieldsWhenTheSourceHasNone() throws {
        let parsed = try parseFixture(.test)
        XCTAssertTrue(parsed.header.unknownInnerHeaderFields.isEmpty)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let items = try innerHeaderItems(of: written, compositeKey: parsed.compositeKey)
        XCTAssertTrue(
            items.allSatisfy { (0x00...0x03).contains($0.id) },
            "A database with no unknown inner-header fields must not gain any"
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )
        XCTAssertTrue(reparsed.header.unknownInnerHeaderFields.isEmpty)
    }

    func test_writeReusedHeader_preservesUnknownInnerHeaderFieldsWhenTheBinaryPoolChanges() throws {
        let parsed = try parseFixture(.unknownInnerHeader)
        let sourceUnknownFields = parsed.header.unknownInnerHeaderFields
        XCTAssertEqual(sourceUnknownFields.count, 3)
        XCTAssertEqual(parsed.header.innerHeaderBinaryFields.count, 2)

        var withAddedAttachment = parsed.header
        withAddedAttachment.innerHeaderBinaryFields.append(Data([0x00]) + Data("added attachment bytes".utf8))

        var withRemovedAttachment = parsed.header
        withRemovedAttachment.innerHeaderBinaryFields.removeLast()

        for (label, header, expectedPoolCount) in [
            ("added", withAddedAttachment, 3),
            ("removed", withRemovedAttachment, 1),
        ] {
            let written = try KDBXWriter.write(
                rootGroup: parsed.rootGroup,
                meta: parsed.meta,
                compositeKey: parsed.compositeKey,
                header: header,
                sessionKey: sessionKey
            )
            let reparsed = try KDBXParser.parseWithMetaAndHeader(
                data: written,
                compositeKey: parsed.compositeKey,
                sessionKey: sessionKey
            )

            XCTAssertEqual(reparsed.header.innerHeaderBinaryFields.count, expectedPoolCount, label)
            XCTAssertEqual(reparsed.header.innerHeaderBinaryFields, header.innerHeaderBinaryFields, label)
            XCTAssertEqual(reparsed.header.unknownInnerHeaderFields, sourceUnknownFields, label)

            let items = try innerHeaderItems(of: written, compositeKey: parsed.compositeKey)
            let firstBinaryIndex = try XCTUnwrap(items.firstIndex { $0.id == 0x03 }, label)
            let lastUnknownIndex = try XCTUnwrap(items.lastIndex { !(0x00...0x03).contains($0.id) }, label)
            XCTAssertLessThan(lastUnknownIndex, firstBinaryIndex, label)
        }
    }

    func test_writeReusedHeader_preservesLargeUnknownInnerHeaderPayload() throws {
        let parsed = try parseFixture(.unknownInnerHeader)
        let largePayload = Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        var header = parsed.header
        header.unknownInnerHeaderFields.append(KDBXParser.UnknownHeaderField(id: 0x42, data: largePayload))

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: header,
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )
        XCTAssertEqual(reparsed.header.unknownInnerHeaderFields, header.unknownInnerHeaderFields)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func testWriteFreshEmptyDatabaseRoundTrips() throws {
        let password = "fresh empty password"
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        let recycleBinID = UUID()
        let root = KPGroup(
            name: "Root",
            groups: [
                KPGroup(
                    name: "Fresh",
                    groups: [
                        KPGroup(id: recycleBinID, name: "Recycle Bin", iconID: 43, isExpanded: false),
                    ]
                ),
            ],
            recycleBinUUID: recycleBinID
        )
        let meta = KPMeta(
            recycleBinUUID: recycleBinID,
            hasRecycleBinUUIDElement: true,
            maintenanceHistoryDays: KPMeta.defaultMaintenanceHistoryDays,
            historyMaxItems: KPMeta.defaultHistoryMaxItems,
            historyMaxSize: KPMeta.defaultHistoryMaxSize
        )

        let written = try KDBXWriter.write(
            rootGroup: root,
            meta: meta,
            compositeKey: compositeKey,
            freshHeader: try DatabaseCreationDefaults.freshHeaderConfiguration(),
            sessionKey: sessionKey
        )

        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )

        XCTAssertEqual(parsed.header.formatVersion, .kdbx4(minor: 0))
        XCTAssertEqual(parsed.rootGroup.groups.first?.name, "Fresh")
        XCTAssertEqual(parsed.meta.recycleBinUUID, recycleBinID)
    }

    func test_writeRoundTrip_preservesHistorySettingsAndEntryHistory() throws {
        let parsed = try parseFixture(.test)
        var meta = parsed.meta
        meta.maintenanceHistoryDays = 30
        meta.historyMaxItems = 3
        meta.historyMaxSize = 4_096

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let reparsed = try parseWrittenFile(written, fixture: .test)
        let twitter = try XCTUnwrap(reparsed.rootGroup.allEntries.first { $0.title == "Twitter" })

        XCTAssertEqual(reparsed.meta.maintenanceHistoryDays, 30)
        XCTAssertEqual(reparsed.meta.historyMaxItems, 3)
        XCTAssertEqual(reparsed.meta.historyMaxSize, 4_096)
        XCTAssertEqual(twitter.history.count, 2)
    }

    func test_writer_failsOnInvalidKDFParameters() throws {
        let parsed = try parseFixture(.test)
        var invalidHeader = parsed.header
        invalidHeader.kdfParameters["I"] = UInt64(0)
        invalidHeader.kdfParameters["M"] = UInt64(0)

        XCTAssertThrowsError(
            try KDBXWriter.write(
                rootGroup: parsed.rootGroup,
                meta: parsed.meta,
                compositeKey: parsed.compositeKey,
                header: invalidHeader,
                sessionKey: sessionKey
            )
        ) { error in
            guard case KDBXParser.ParseError.kdfParameterOutOfRange(let message) = error else {
                XCTFail("Expected KDF parameter failure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("iterations"))
        }
    }

    func test_writeReusedHeaderTwice_rotatesMasterSeedIVInnerStreamKeyAndKDFSalt() throws {
        let parsed = try parseFixture(.test)
        let originalSalt = try XCTUnwrap(parsed.header.kdfParameters["S"] as? Data)

        let firstData = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )
        let secondData = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let first = try KDBXParser.parseWithMetaAndHeader(
            data: firstData,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )
        let second = try KDBXParser.parseWithMetaAndHeader(
            data: secondData,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )

        let firstSalt = try XCTUnwrap(first.header.kdfParameters["S"] as? Data)
        let secondSalt = try XCTUnwrap(second.header.kdfParameters["S"] as? Data)

        // Original file, first save, and second save must differ pairwise in
        // each of these header values.
        assertAllDistinct(
            [parsed.header.masterSeed, first.header.masterSeed, second.header.masterSeed],
            "master seed"
        )
        assertAllDistinct(
            [parsed.header.encryptionIV, first.header.encryptionIV, second.header.encryptionIV],
            "encryption IV"
        )
        assertAllDistinct(
            [parsed.header.innerStreamKey, first.header.innerStreamKey, second.header.innerStreamKey],
            "inner stream key"
        )
        assertAllDistinct([originalSalt, firstSalt, secondSalt], "KDF salt")

        XCTAssertEqual(firstSalt.count, originalSalt.count)
        XCTAssertEqual(secondSalt.count, originalSalt.count)
        XCTAssertEqual(
            first.header.kdfParameters["$UUID"] as? Data,
            parsed.header.kdfParameters["$UUID"] as? Data
        )
        XCTAssertEqual(first.header.kdfParameters["I"] as? UInt64, parsed.header.kdfParameters["I"] as? UInt64)
        XCTAssertEqual(first.header.kdfParameters["M"] as? UInt64, parsed.header.kdfParameters["M"] as? UInt64)
        XCTAssertEqual(first.header.kdfParameters["P"] as? UInt32, parsed.header.kdfParameters["P"] as? UInt32)

        try assertTreesEqual(parsed, (rootGroup: first.rootGroup, meta: first.meta))
        try assertTreesEqual(parsed, (rootGroup: second.rootGroup, meta: second.meta))
    }

    func test_writeReusedHeaderWithNewCompositeKey_newKeyOpensOldKeyFails() throws {
        let parsed = try parseFixture(.test)
        let newCompositeKey = try KDBXCrypto.compositeKey(
            password: "rotated-master-123",
            keyFileData: nil
        )

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: newCompositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: newCompositeKey,
            sessionKey: sessionKey
        )
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
        XCTAssertEqual(reparsed.header.cipherID, parsed.header.cipherID)
        XCTAssertEqual(
            reparsed.header.kdfParameters["$UUID"] as? Data,
            parsed.header.kdfParameters["$UUID"] as? Data
        )
        XCTAssertEqual(reparsed.header.kdfParameters["I"] as? UInt64, parsed.header.kdfParameters["I"] as? UInt64)
        XCTAssertEqual(reparsed.header.kdfParameters["M"] as? UInt64, parsed.header.kdfParameters["M"] as? UInt64)
        XCTAssertEqual(reparsed.header.kdfParameters["P"] as? UInt32, parsed.header.kdfParameters["P"] as? UInt32)
        XCTAssertNotEqual(reparsed.header.masterSeed, parsed.header.masterSeed)
        XCTAssertNotEqual(
            reparsed.header.kdfParameters["S"] as? Data,
            parsed.header.kdfParameters["S"] as? Data
        )

        XCTAssertThrowsError(
            try KDBXParser.parseWithMetaAndHeader(
                data: written,
                compositeKey: parsed.compositeKey,
                sessionKey: sessionKey
            ),
            "The old composite key must fail the header HMAC of the rekeyed file."
        )
    }

    func test_writeFreshHeader_rotatesProvidedKDFSalt() throws {
        let parsed = try parseFixture(.test)
        let providedSalt = try XCTUnwrap(parsed.header.kdfParameters["S"] as? Data)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.chachaCipherUUID,
                kdfParameters: parsed.header.kdfParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: written,
            compositeKey: parsed.compositeKey,
            sessionKey: sessionKey
        )
        let writtenSalt = try XCTUnwrap(reparsed.header.kdfParameters["S"] as? Data)

        XCTAssertNotEqual(writtenSalt, providedSalt)
        XCTAssertEqual(writtenSalt.count, providedSalt.count)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func test_writeAndDecrypt_protectedValueStaysOpaque() throws {
        let parsed = try parseFixture(.test)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )

        let xmlData = try decryptWrittenXML(written, compositeKey: parsed.compositeKey)
        let xmlString = try XCTUnwrap(String(data: xmlData, encoding: .utf8))

        XCTAssertTrue(xmlString.contains("Protected=\"True\""))
        XCTAssertFalse(xmlString.contains(">githubpass789</Value>"))
        XCTAssertFalse(xmlString.contains(">twitterpass123</Value>"))
    }

    private func assertAllDistinct(
        _ values: [Data],
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for lhsIndex in values.indices {
            for rhsIndex in values.indices where rhsIndex > lhsIndex {
                XCTAssertNotEqual(
                    values[lhsIndex],
                    values[rhsIndex],
                    "\(label) must be freshly randomized on every save",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func parseFixture(_ fixture: KDBXTestFixture) throws -> ParsedFixture {
        let bundle = Bundle(for: Self.self)
        let databaseURL = try TestDatabaseSupport.fixtureURL(
            named: fixture.name,
            subdirectory: fixture.subdirectory,
            bundle: bundle
        )
        let databaseData = try Data(contentsOf: databaseURL)

        let keyFileData: Data?
        if let keyFileName = fixture.keyFileName, let keyFileExtension = fixture.keyFileExtension {
            let keyURL = try TestDatabaseSupport.fixtureURL(
                named: keyFileName,
                extension: keyFileExtension,
                bundle: bundle
            )
            keyFileData = try Data(contentsOf: keyURL)
        } else {
            keyFileData = nil
        }

        let compositeKey = try KDBXCrypto.compositeKey(password: fixture.password, keyFileData: keyFileData)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: databaseData,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )

        return ParsedFixture(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            header: parsed.header,
            compositeKey: compositeKey
        )
    }

    private func parseWrittenFile(
        _ data: Data,
        fixture: KDBXTestFixture
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let bundle = Bundle(for: Self.self)

        let keyFileData: Data?
        if let keyFileName = fixture.keyFileName, let keyFileExtension = fixture.keyFileExtension {
            let keyURL = try TestDatabaseSupport.fixtureURL(
                named: keyFileName,
                extension: keyFileExtension,
                bundle: bundle
            )
            keyFileData = try Data(contentsOf: keyURL)
        } else {
            keyFileData = nil
        }

        if fixture.keyFileName != nil {
            return try KDBXParser.parseWithMeta(
                data: data,
                password: fixture.password,
                keyFileData: keyFileData,
                sessionKey: sessionKey
            )
        }

        return try KDBXParser.parseWithMeta(
            data: data,
            password: try XCTUnwrap(fixture.password),
            sessionKey: sessionKey
        )
    }

    private func readWrittenFileComponents(
        _ data: Data,
        compositeKey: SymmetricKey
    ) throws -> (
        header: KDBXParser.Header,
        headerBytes: Data,
        storedHeaderSHA256: Data,
        storedHeaderHMAC: Data,
        payloadOffset: Int,
        hmacBaseKey: Data
    ) {
        var reader = DataReader(data: data)
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()

        let header = try KDBXParser.parseHeader(&reader)
        let headerBytes = data.subdata(in: 0..<reader.offset)
        let storedHeaderSHA256 = try reader.readBytes(32)
        let storedHeaderHMAC = try reader.readBytes(32)

        let transformedKey = try KDBXParser.deriveKey(
            compositeKey: compositeKey,
            kdfParams: header.kdfParameters
        )

        var hmacPreKey = Data()
        hmacPreKey.append(header.masterSeed)
        hmacPreKey.append(transformedKey)
        hmacPreKey.append(Data([0x01]))

        return (
            header,
            headerBytes,
            storedHeaderSHA256,
            storedHeaderHMAC,
            reader.offset,
            KDBXCrypto.sha512(hmacPreKey)
        )
    }

    private func decryptWrittenXML(_ data: Data, compositeKey: SymmetricKey) throws -> Data {
        var reader = DataReader(data: data)
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()
        let header = try KDBXParser.parseHeader(&reader)
        _ = try reader.readBytes(32)
        _ = try reader.readBytes(32)

        let transformedKey = try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: header.kdfParameters)

        var masterPreKey = Data()
        masterPreKey.append(header.masterSeed)
        masterPreKey.append(transformedKey)
        let masterKey = KDBXCrypto.sha256(masterPreKey)

        var hmacPreKey = Data()
        hmacPreKey.append(header.masterSeed)
        hmacPreKey.append(transformedKey)
        hmacPreKey.append(Data([0x01]))
        let hmacBaseKey = KDBXCrypto.sha512(hmacPreKey)

        let encryptedPayload = try KDBXParser.readHMACBlocks(reader: &reader, baseKey: hmacBaseKey)
        let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)
        let decryptedPayload = try cipher.decrypt(
            data: encryptedPayload,
            key: masterKey,
            iv: header.encryptionIV
        )

        let payload = header.compressionFlags == 1 ? try KDBXCrypto.gunzip(decryptedPayload) : decryptedPayload
        var innerReader = DataReader(data: payload)
        _ = try KDBXParser.parseInnerHeader(&innerReader)
        return payload.subdata(in: innerReader.offset..<payload.count)
    }

    private func readEncryptedPayload(
        from data: Data,
        payloadOffset: Int,
        hmacBaseKey: Data
    ) throws -> Data {
        var reader = DataReader(data: data)
        try reader.skip(payloadOffset)
        return try KDBXParser.readHMACBlocks(reader: &reader, baseKey: hmacBaseKey)
    }

    private func decryptPayload(
        _ encryptedPayload: Data,
        header: KDBXParser.Header,
        compositeKey: SymmetricKey
    ) throws -> Data {
        let transformedKey = try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: header.kdfParameters)

        var masterPreKey = Data()
        masterPreKey.append(header.masterSeed)
        masterPreKey.append(transformedKey)
        let masterKey = KDBXCrypto.sha256(masterPreKey)

        let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)
        return try cipher.decrypt(data: encryptedPayload, key: masterKey, iv: header.encryptionIV)
    }

    private struct InnerHeaderItem: Equatable {
        let id: UInt8
        let payload: Data
    }

    /// Raw inner-header item sequence of a written database, so ordering (not
    /// just the parsed model's contents) can be asserted.
    private func innerHeaderItems(of written: Data, compositeKey: SymmetricKey) throws -> [InnerHeaderItem] {
        let components = try readWrittenFileComponents(written, compositeKey: compositeKey)
        let encryptedPayload = try readEncryptedPayload(
            from: written,
            payloadOffset: components.payloadOffset,
            hmacBaseKey: components.hmacBaseKey
        )
        let decrypted = try decryptPayload(encryptedPayload, header: components.header, compositeKey: compositeKey)
        let payload = components.header.compressionFlags == 1 ? try KDBXCrypto.gunzip(decrypted) : decrypted

        var reader = DataReader(data: payload)
        var items: [InnerHeaderItem] = []
        while true {
            let id = try reader.readUInt8()
            let size = Int(try reader.readUInt32())
            items.append(InnerHeaderItem(id: id, payload: try reader.readBytes(size)))
            if id == KDBXParser.InnerHeaderField.endOfHeader.rawValue {
                return items
            }
        }
    }

    private func parseInnerPayload(
        _ decryptedPayload: Data,
        header: KDBXParser.Header
    ) throws -> Data {
        let payload = header.compressionFlags == 1 ? try KDBXCrypto.gunzip(decryptedPayload) : decryptedPayload
        var innerReader = DataReader(data: payload)
        _ = try KDBXParser.parseInnerHeader(&innerReader)
        return payload.subdata(in: innerReader.offset..<payload.count)
    }

    private func countPayloadBlocks(in data: Data) throws -> Int {
        var reader = DataReader(data: data)
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()
        _ = try KDBXParser.parseHeader(&reader)
        _ = try reader.readBytes(32)
        _ = try reader.readBytes(32)

        var blockCount = 0
        while true {
            _ = try reader.readBytes(32)
            let blockSize = try reader.readInt32()
            if blockSize == 0 {
                return blockCount
            }
            XCTAssertGreaterThan(blockSize, 0)
            try reader.skip(Int(blockSize))
            blockCount += 1
        }
    }

    private func setNotes(_ notes: String, forEntryTitled title: String, in group: KPGroup) -> Bool {
        if let index = group.entries.firstIndex(where: { $0.title == title }) {
            group.entries[index].notes = notes
            return true
        }

        for subgroup in group.groups where setNotes(notes, forEntryTitled: title, in: subgroup) {
            return true
        }

        return false
    }

    /// Thin adapter over the shared comparators in `KDBXTreeAssertions.swift`;
    /// the container round-trip and the XML round-trip must verify the same
    /// fields.
    private func assertTreesEqual(
        _ lhs: ParsedFixture,
        _ rhs: (rootGroup: KPGroup, meta: KPMeta),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try KDBXTreeAssertions.assertTreesEqual(
            (rootGroup: lhs.rootGroup, meta: lhs.meta),
            rhs,
            sessionKey: sessionKey,
            file: file,
            line: line
        )
    }
}
