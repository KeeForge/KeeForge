import CryptoKit
import XCTest
@testable import KeeForge

final class KDBXWriterTests: XCTestCase {
    private struct Fixture {
        let name: String
        let subdirectory: String?
        let password: String?
        let keyFileName: String?
        let keyFileExtension: String?

        static let test = Fixture(
            name: "test",
            subdirectory: nil,
            password: "testpassword123",
            keyFileName: nil,
            keyFileExtension: nil
        )
        static let demo = Fixture(
            name: "demo",
            subdirectory: nil,
            password: "demo",
            keyFileName: nil,
            keyFileExtension: nil
        )
        static let demoKeyfile = Fixture(
            name: "demo-keyfile",
            subdirectory: nil,
            password: "demo",
            keyFileName: "demo-keyfile",
            keyFileExtension: "key"
        )
        static let unknownElements = Fixture(
            name: "unknown-elements",
            subdirectory: "round-trip",
            password: "test-round-trip",
            keyFileName: nil,
            keyFileExtension: nil
        )
    }

    private struct ParsedFixture {
        let rootGroup: KPGroup
        let meta: KPMeta
        let header: KDBXParser.Header
        let compositeKey: Data
    }

    private let sessionKey = SymmetricKey(size: .bits256)
    private let protectedValueRegex = try? NSRegularExpression(
        pattern: #"<Value(?=[^>]*Protected="True")([^>]*)>.*?</Value>"#,
        options: [.dotMatchesLineSeparators]
    )

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

        let reparsed = try parseWrittenFile(written, fixture: .test)
        try assertTreesEqual(parsed, reparsed)
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

    private func parseFixture(_ fixture: Fixture) throws -> ParsedFixture {
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

        let compositeKey = KDBXCrypto.compositeKey(password: fixture.password, keyFileData: keyFileData)
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
        fixture: Fixture
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
        compositeKey: Data
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

    private func decryptWrittenXML(_ data: Data, compositeKey: Data) throws -> Data {
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
        let decryptedPayload: Data

        if header.cipherID == KDBXParser.aesCipherUUID {
            decryptedPayload = try KDBXCrypto.decryptAES256CBC(
                data: encryptedPayload,
                key: masterKey,
                iv: header.encryptionIV
            )
        } else if header.cipherID == KDBXParser.chachaCipherUUID {
            decryptedPayload = try KDBXCrypto.decryptChaCha20Poly1305(
                data: encryptedPayload,
                key: masterKey,
                nonce: header.encryptionIV
            )
        } else {
            throw KDBXCrypto.CryptoError.unsupportedCipher(header.cipherID.hexString)
        }

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

    private func assertTreesEqual(
        _ lhs: ParsedFixture,
        _ rhs: (rootGroup: KPGroup, meta: KPMeta),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(lhs.meta.recycleBinUUID, rhs.meta.recycleBinUUID, file: file, line: line)
        XCTAssertEqual(lhs.meta.maintenanceHistoryDays, rhs.meta.maintenanceHistoryDays, file: file, line: line)
        XCTAssertEqual(lhs.meta.historyMaxItems, rhs.meta.historyMaxItems, file: file, line: line)
        XCTAssertEqual(lhs.meta.historyMaxSize, rhs.meta.historyMaxSize, file: file, line: line)
        XCTAssertEqual(normalizedOpaqueXML(lhs.meta.unknownXML), normalizedOpaqueXML(rhs.meta.unknownXML), file: file, line: line)
        try assertGroupsEqual(lhs.rootGroup, rhs.rootGroup, file: file, line: line)
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
        XCTAssertEqual(normalizedOpaqueXML(lhs.unknownXML), normalizedOpaqueXML(rhs.unknownXML), file: file, line: line)
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
        XCTAssertEqual(normalizedOpaqueXML(lhs.unknownXML), normalizedOpaqueXML(rhs.unknownXML), file: file, line: line)
        XCTAssertEqual(lhs.history.count, rhs.history.count, file: file, line: line)
        for (lhsHistoryEntry, rhsHistoryEntry) in zip(lhs.history, rhs.history) {
            try assertEntriesEqual(lhsHistoryEntry, rhsHistoryEntry, file: file, line: line)
        }
        try assertTOTPConfigsEqual(lhs.totpConfig, rhs.totpConfig, file: file, line: line)
    }

    private func normalizedOpaqueXML(_ unknownXML: OpaqueXMLNodes) -> OpaqueXMLNodes {
        OpaqueXMLNodes(nodes: unknownXML.nodes.map { node in
            OpaqueXMLNodes.Node(
                path: node.path,
                insertionIndex: node.insertionIndex,
                xml: normalizedProtectedValues(in: node.xml)
            )
        })
    }

    private func normalizedProtectedValues(in xml: String) -> String {
        guard let protectedValueRegex else { return xml }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return protectedValueRegex.stringByReplacingMatches(
            in: xml,
            options: [],
            range: nsRange,
            withTemplate: "<Value$1></Value>"
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
