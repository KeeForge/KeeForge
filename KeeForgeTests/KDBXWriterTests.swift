import CryptoKit
import XCTest
import KDBXKit
import KDBXXML
@testable import KeeForge

final class KDBXWriterTests: XCTestCase {
    private struct ParsedFixture {
        let rootGroup: KPGroup
        let meta: KPMeta
        let header: KDBXContainer.Header
        let compositeKey: SymmetricKey
    }

    private let sessionKey = SymmetricKey(size: .bits256)

    func test_writeRoundTrip_test_kdbx_AES_returnsEqualTree() throws {
        let parsed = try parseFixture(.test)
        XCTAssertEqual(parsed.header.cipherID, KDBXOuterCipher.aes256CBC.uuid)

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
        XCTAssertEqual(parsed.header.cipherID, KDBXOuterCipher.aes256CBC.uuid)

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
        XCTAssertEqual(parsed.header.cipherID, KDBXOuterCipher.aes256CBC.uuid)

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

    func test_writeWithChaCha20Cipher_roundTrip() throws {
        let parsed = try parseFixture(.test)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXContainerWriter.FreshHeaderConfiguration(
                cipher: .chaCha20,
                kdfParameters: parsed.header.kdfParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        XCTAssertEqual(try KDBXContainer.readHeader(from: written).cipher, .chaCha20)

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeWithTwofish256CBCCipher_roundTrip() throws {
        let parsed = try parseFixture(.test)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXContainerWriter.FreshHeaderConfiguration(
                cipher: .twofish256CBC,
                kdfParameters: parsed.header.kdfParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        let writtenHeader = try KDBXContainer.readHeader(from: written)
        XCTAssertEqual(writtenHeader.cipher, .twofish256CBC)
        XCTAssertEqual(writtenHeader.encryptionIV.count, 16)

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeWithTwofishReportedArgon2dProfile_roundTrip() throws {
        let parsed = try parseFixture(.test)
        let reportedKDFParameters = KDBXKeyDerivation.argon2(KDBXKeyDerivation.Argon2Parameters(
            variant: .d,
            iterations: 3,
            memoryBytes: 16 * 1024 * 1024,
            parallelism: 4,
            salt: Data((0..<32).map(UInt8.init))
        )).parameters

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXContainerWriter.FreshHeaderConfiguration(
                cipher: .twofish256CBC,
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
        XCTAssertEqual(reparsed.header.cipherID, KDBXOuterCipher.twofish256CBC.uuid)
        XCTAssertEqual(reparsed.header.kdfParameters.bytes("$UUID"), KDBXKeyDerivation.Algorithm.argon2d.uuid)
        XCTAssertEqual(reparsed.header.kdfParameters.uint64("I"), 3)
        XCTAssertEqual(reparsed.header.kdfParameters.uint64("M"), 16 * 1024 * 1024)
        XCTAssertEqual(reparsed.header.kdfParameters.uint32("P"), 4)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func test_writeReusedTwofishHeader_preservesNoCompression() throws {
        let parsed = try parseFixture(.test)
        var twofishHeader = parsed.header
        twofishHeader.cipherID = KDBXOuterCipher.twofish256CBC.uuid
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
        XCTAssertEqual(reparsed.header.cipherID, KDBXOuterCipher.twofish256CBC.uuid)
        XCTAssertEqual(reparsed.header.compressionFlags, 0)
        try assertTreesEqual(parsed, (rootGroup: reparsed.rootGroup, meta: reparsed.meta))
    }

    func test_writeWithArgon2idKDF_roundTrip() throws {
        let parsed = try parseFixture(.test)
        var argon2idHeader = parsed.header
        argon2idHeader.kdfParameters["$UUID"] = .bytes(KDBXKeyDerivation.Algorithm.argon2id.uuid)

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            header: argon2idHeader,
            sessionKey: sessionKey
        )

        XCTAssertEqual(try KDBXContainer.readHeader(from: written).keyDerivation?.algorithm, .argon2id)

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeIconTimestampWithoutNameRequiresKDBX41() throws {
        let parsed = try parseFixture(.test)
        let uuid = UUID()
        var meta = parsed.meta
        meta.unknownXML.append(xml: "<CustomIcons><Icon><UUID>\(uuid.kdbxBase64String)</UUID><Data>AQ==</Data><LastModificationTime>\(Date.now.kdbxBase64String)</LastModificationTime></Icon></CustomIcons>", insertionIndex: 0)
        var header = parsed.header
        header.formatVersion = .kdbx4(minor: 0)
        let written = try KDBXWriter.write(rootGroup: parsed.rootGroup, meta: meta, compositeKey: parsed.compositeKey,
                                           header: header, sessionKey: sessionKey)
        XCTAssertEqual(try KDBXContainer.parseFileVersion(from: written), .kdbx4(minor: 1))
        let reopened = try parseWrittenFile(written, fixture: .test)
        XCTAssertEqual(reopened.meta.customIcons[uuid], Data([1]))
        XCTAssertNil(reopened.meta.customIconNames[uuid])
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

        XCTAssertEqual(try KDBXContainer.parseFileVersion(from: written), .kdbx4(minor: 1))

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
    }

    func test_writeReusedHeader_preservesUnknownOuterHeaderFields() throws {
        let parsed = try parseFixture(.test)
        let unknownFields = [
            KDBXContainer.UnknownHeaderField(id: 12, data: Data("public-custom-data".utf8)),
            KDBXContainer.UnknownHeaderField(id: 0x7F, data: Data([0x01, 0x02, 0x03])),
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
        }
    }

    func test_writeReusedHeader_preservesLargeUnknownInnerHeaderPayload() throws {
        let parsed = try parseFixture(.unknownInnerHeader)
        let largePayload = Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        var header = parsed.header
        header.unknownInnerHeaderFields.append(KDBXContainer.UnknownHeaderField(id: 0x42, data: largePayload))

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
        invalidHeader.kdfParameters["I"] = .uint64(0)
        invalidHeader.kdfParameters["M"] = .uint64(0)

        XCTAssertThrowsError(
            try KDBXWriter.write(
                rootGroup: parsed.rootGroup,
                meta: parsed.meta,
                compositeKey: parsed.compositeKey,
                header: invalidHeader,
                sessionKey: sessionKey
            )
        ) { error in
            guard case KDBXContainer.ParseError.kdfParameterOutOfRange(let message) = error else {
                XCTFail("Expected KDF parameter failure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("iterations"))
        }
    }

    func test_invalidCharacterFailureNamesTheEntryOrGroupAndField() {
        typealias Location = KDBXDocument.WriteError.Location
        let groupID = UUID()
        let entryID = UUID()
        let untitledID = UUID()
        let document = KDBXDocument(root: .init(groups: [KDBXDocument.Group(name: "Root", groups: [
            KDBXDocument.Group(uuid: groupID, name: "Bank\u{0}s", entries: [
                KDBXDocument.Entry(uuid: entryID, strings: [.init(key: "Title", value: "Checking")]),
                KDBXDocument.Entry(uuid: untitledID),
            ]),
        ])]))
        let cases: [(Location, String?, String)] = [
            (Location(owner: .entry(entryID), part: .field(key: "UserName")), "Checking",
             "The entry “Checking” contains an unsupported character (U+0000) in “Username”. Remove it before saving."),
            (Location(owner: .historyEntry(entryID), part: .field(key: "PIN\u{0}")), "Checking",
             "An earlier version of the entry “Checking” contains an unsupported character (U+0000) in “PIN”, so the database can’t be saved."),
            (Location(owner: .group(groupID), part: .element("Name")), "Banks",
             "The group “Banks” contains an unsupported character (U+0000) in “Name”. Remove it before saving."),
            (Location(owner: .entry(untitledID), part: .attachment(key: "scan.pdf")), nil,
             "The database contains an unsupported character (U+0000) in “scan.pdf”, so it can’t be saved."),
            (Location(owner: .meta, part: .element("CustomData")), nil,
             "The database contains an unsupported character (U+0000) in “CustomData”, so it can’t be saved."),
            (Location(owner: .root, part: .element(nil)), nil,
             "The database contains an unsupported character (U+0000). Remove it from your text before saving."),
        ]
        for (location, ownerName, message) in cases {
            let failure = DocumentWriteFailure(.invalidXMLCharacter("\u{0}", at: location), in: document)
            XCTAssertEqual(failure.ownerName, ownerName)
            XCTAssertEqual(failure.errorDescription, message)
        }
        XCTAssertEqual(
            KDBXDocument.WriteError.invalidXMLCharacter("\u{0}", at: Location(owner: .group(groupID), part: .element("Tags"))).errorDescription,
            "The database contains an unsupported character (U+0000) in “Tags”, so it can’t be saved."
        )
    }

    func test_writeReusedHeaderTwice_rotatesMasterSeedIVInnerStreamKeyAndKDFSalt() throws {
        let parsed = try parseFixture(.test)
        let originalSalt = try XCTUnwrap(parsed.header.kdfParameters.bytes("S"))

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

        let firstSalt = try XCTUnwrap(first.header.kdfParameters.bytes("S"))
        let secondSalt = try XCTUnwrap(second.header.kdfParameters.bytes("S"))

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
            first.header.kdfParameters.bytes("$UUID"),
            parsed.header.kdfParameters.bytes("$UUID")
        )
        XCTAssertEqual(first.header.kdfParameters.uint64("I"), parsed.header.kdfParameters.uint64("I"))
        XCTAssertEqual(first.header.kdfParameters.uint64("M"), parsed.header.kdfParameters.uint64("M"))
        XCTAssertEqual(first.header.kdfParameters.uint32("P"), parsed.header.kdfParameters.uint32("P"))

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
            reparsed.header.kdfParameters.bytes("$UUID"),
            parsed.header.kdfParameters.bytes("$UUID")
        )
        XCTAssertEqual(reparsed.header.kdfParameters.uint64("I"), parsed.header.kdfParameters.uint64("I"))
        XCTAssertEqual(reparsed.header.kdfParameters.uint64("M"), parsed.header.kdfParameters.uint64("M"))
        XCTAssertEqual(reparsed.header.kdfParameters.uint32("P"), parsed.header.kdfParameters.uint32("P"))
        XCTAssertNotEqual(reparsed.header.masterSeed, parsed.header.masterSeed)
        XCTAssertNotEqual(
            reparsed.header.kdfParameters.bytes("S"),
            parsed.header.kdfParameters.bytes("S")
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
        let providedSalt = try XCTUnwrap(parsed.header.kdfParameters.bytes("S"))

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: parsed.compositeKey,
            freshHeader: KDBXContainerWriter.FreshHeaderConfiguration(
                cipher: .chaCha20,
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
        let writtenSalt = try XCTUnwrap(reparsed.header.kdfParameters.bytes("S"))

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
        let parsed = try fixture.parse(in: Bundle(for: Self.self), sessionKey: sessionKey)
        return ParsedFixture(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            header: parsed.header,
            compositeKey: parsed.compositeKey
        )
    }

    /// Re-opens KeeForge's own output with the fixture's credentials, so the
    /// written file is proven to accept the password (and key file) it claims.
    private func parseWrittenFile(
        _ data: Data,
        fixture: KDBXTestFixture
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        try KDBXParser.parseWithMeta(
            data: data,
            password: fixture.password,
            keyFileData: try fixture.keyFileData(in: Bundle(for: Self.self)),
            sessionKey: sessionKey
        )
    }

    private func decryptWrittenXML(_ data: Data, compositeKey: SymmetricKey) throws -> Data {
        try KDBXContainer.read(data: data, compositeKey: compositeKey, kdfPolicy: .mainApp).xml
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
