import CryptoKit
import XCTest
@testable import KeeForge

final class KDBXRoundTripTests: XCTestCase {
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

    private let roundTripSessionKey = SymmetricKey(size: .bits256)
    private let roundTripInnerStreamKey = Data("KeeForge Slice01 Inner Stream Key".utf8)
    private let protectedValueRegex = try? NSRegularExpression(
        pattern: #"<Value(?=[^>]*Protected="True")([^>]*)>.*?</Value>"#,
        options: [.dotMatchesLineSeparators]
    )

    func test_parseSerializeParse_test_kdbx_returnsEqualTree() throws {
        try assertFixtureRoundTrips(.test)
    }

    func test_parseSerializeParse_demo_kdbx_returnsEqualTree() throws {
        try assertFixtureRoundTrips(.demo)
    }

    func test_parseSerializeParse_demoKeyfile_kdbx_returnsEqualTree() throws {
        try assertFixtureRoundTrips(.demoKeyfile)
    }

    @MainActor
    func test_editSaveReload_preservesKeeOTPDecodedSecretAndUppercaseSource() throws {
        let rawQuery = "key=AAEC%2Fw%3D%3D&type=TOTP&step=30&size=6&encoding=Base64&otpHashMode=SHA1"
        let entry = KPEntry(
            title: "KeeOTP",
            password: try EncryptedValue.encrypt("password", using: roundTripSessionKey),
            customFields: [
                "OTP": rawQuery,
            ],
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("AAEC/w==", using: roundTripSessionKey),
                decodedSecret: try EncryptedValue.encrypt(Data([0x00, 0x01, 0x02, 0xFF]), using: roundTripSessionKey),
                keeOTPSource: KeeOTPSource(fieldName: "OTP", rawQuery: rawQuery)
            )
        )
        let rootGroup = KPGroup(id: UUID(), name: "Root", entries: [entry])
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: roundTripSessionKey)
        viewModel.notes = "Edited"

        let draft = DatabaseDraft(rootGroup: rootGroup, meta: KPMeta(), sessionKey: roundTripSessionKey)
        let updated = try draft.apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        let reloadedTOTP = try XCTUnwrap(reloaded.totpConfig)

        XCTAssertEqual(reloadedTOTP.keeOTPSource, KeeOTPSource(fieldName: "OTP", rawQuery: rawQuery))
        XCTAssertNil(reloaded.customFields["OTP"])
        XCTAssertNil(reloaded.customFields["TimeOtp-Secret-Base32"])
        XCTAssertEqual(
            TOTPGenerator.resolveSecret(config: reloadedTOTP, sessionKey: roundTripSessionKey)?.data,
            Data([0x00, 0x01, 0x02, 0xFF])
        )
    }

    @MainActor
    func test_editSaveReload_preservesKeeOTPLowercaseSourceAndDecodedSecret() throws {
        let rawQuery = "key=AAEC%2Fw%3D%3D&type=TOTP&step=30&size=6&encoding=Base64&otpHashMode=SHA1"
        let entry = KPEntry(
            title: "KeeOTP",
            password: try EncryptedValue.encrypt("password", using: roundTripSessionKey),
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("AAEC/w==", using: roundTripSessionKey),
                decodedSecret: try EncryptedValue.encrypt(Data([0x00, 0x01, 0x02, 0xFF]), using: roundTripSessionKey),
                keeOTPSource: KeeOTPSource(fieldName: "otp", rawQuery: rawQuery)
            ),
            otpURL: rawQuery
        )
        let rootGroup = KPGroup(id: UUID(), name: "Root", entries: [entry])
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: roundTripSessionKey)
        viewModel.notes = "Edited"

        let draft = DatabaseDraft(rootGroup: rootGroup, meta: KPMeta(), sessionKey: roundTripSessionKey)
        let updated = try draft.apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        let reloadedTOTP = try XCTUnwrap(reloaded.totpConfig)

        XCTAssertEqual(reloaded.otpURL, entry.otpURL)
        XCTAssertNil(reloaded.customFields["TimeOtp-Secret-Base32"])
        XCTAssertEqual(
            TOTPGenerator.resolveSecret(config: reloadedTOTP, sessionKey: roundTripSessionKey)?.data,
            Data([0x00, 0x01, 0x02, 0xFF])
        )
    }

    @MainActor
    func test_editSaveReload_preservesKeeOTPLowercaseUTF8SourceWhitespace() throws {
        let secret = " leading and trailing "
        let rawQuery = "key=%20leading%20and%20trailing%20&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1"
        let entry = KPEntry(
            title: "KeeOTP",
            password: try EncryptedValue.encrypt("password", using: roundTripSessionKey),
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt(secret, using: roundTripSessionKey),
                decodedSecret: try EncryptedValue.encrypt(Data(secret.utf8), using: roundTripSessionKey),
                keeOTPSource: KeeOTPSource(fieldName: "otp", rawQuery: rawQuery)
            ),
            otpURL: rawQuery
        )
        let rootGroup = KPGroup(id: UUID(), name: "Root", entries: [entry])
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: roundTripSessionKey)
        viewModel.notes = "Edited"

        let draft = DatabaseDraft(rootGroup: rootGroup, meta: KPMeta(), sessionKey: roundTripSessionKey)
        let updated = try draft.apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        let reloadedTOTP = try XCTUnwrap(reloaded.totpConfig)

        XCTAssertEqual(reloaded.otpURL, entry.otpURL)
        XCTAssertNil(reloaded.customFields["TimeOtp-Secret-Base32"])
        XCTAssertEqual(
            TOTPGenerator.resolveSecret(config: reloadedTOTP, sessionKey: roundTripSessionKey)?.data,
            Data(secret.utf8)
        )
    }

    func test_unknownNodes_controlledFixture_capturesCustomData() throws {
        let parsed = try parseFixture(.unknownElements)
        let entry = try controlledUnknownsEntry(in: parsed.rootGroup)

        let metaCustomData = try XCTUnwrap(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripMetaValue-Expected",
                in: parsed.meta.unknownXML
            )
        )
        let entryCustomData = try XCTUnwrap(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripEntryValue-Expected",
                in: entry.unknownXML
            )
        )
        let autoType = try XCTUnwrap(
            unknownFragment(
                named: "AutoType",
                containing: "RoundTrip Login",
                in: entry.unknownXML
            )
        )
        // `<Binary>` attachment refs are structurally parsed into
        // `KPEntry.attachments`, not captured as unknown XML.
        let binaryAttachment = try XCTUnwrap(entry.attachments.first)

        XCTAssertFalse(metaCustomData.isEmpty)
        XCTAssertFalse(entryCustomData.isEmpty)
        XCTAssertFalse(autoType.isEmpty)
        XCTAssertEqual(binaryAttachment.name, "round-trip.txt")
        XCTAssertEqual(binaryAttachment.ref, 0)
        XCTAssertEqual(entry.history.count, 1)
        XCTAssertTrue(entry.history[0].notes.contains("Historical revision for round-trip coverage"))
        XCTAssertEqual(entry.history[0].attachments.first?.name, "round-trip.txt")
        XCTAssertEqual(entry.history[0].attachments.first?.ref, 0)

        let reparsed = try serializeAndParse(parsed)
        let reparsedEntry = try controlledUnknownsEntry(in: reparsed.rootGroup)

        XCTAssertNotNil(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripMetaValue-Expected",
                in: reparsed.meta.unknownXML
            )
        )
        XCTAssertNotNil(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripEntryValue-Expected",
                in: reparsedEntry.unknownXML
            )
        )
        XCTAssertNotNil(
            unknownFragment(
                named: "AutoType",
                containing: "RoundTrip Login",
                in: reparsedEntry.unknownXML
            )
        )
        XCTAssertEqual(reparsedEntry.attachments.first?.name, "round-trip.txt")
        XCTAssertEqual(reparsedEntry.attachments.first?.ref, 0)
        XCTAssertEqual(reparsedEntry.history.count, 1)
        XCTAssertTrue(reparsedEntry.history[0].notes.contains("Historical revision for round-trip coverage"))
        XCTAssertEqual(reparsedEntry.history[0].attachments.first?.name, "round-trip.txt")
        XCTAssertEqual(reparsedEntry.history[0].attachments.first?.ref, 0)
        XCTAssertEqual(parsed.meta.recycleBinUUID, reparsed.meta.recycleBinUUID)
        XCTAssertEqual(entry.title, reparsedEntry.title)
        XCTAssertEqual(entry.username, reparsedEntry.username)
        XCTAssertEqual(entry.url, reparsedEntry.url)
        XCTAssertEqual(
            try entry.password.decrypt(using: roundTripSessionKey),
            try reparsedEntry.password.decrypt(using: roundTripSessionKey)
        )
    }

    func test_unknownNodes_controlledFixture_specificContentPreserved() throws {
        let parsed = try parseFixture(.unknownElements)
        let entry = try controlledUnknownsEntry(in: parsed.rootGroup)

        let originalMetaCustomData = try XCTUnwrap(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripMetaKey",
                in: parsed.meta.unknownXML
            )
        )
        let originalEntryCustomData = try XCTUnwrap(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripEntryKey",
                in: entry.unknownXML
            )
        )

        XCTAssertTrue(originalMetaCustomData.contains("<Key>RoundTripMetaKey</Key>"))
        XCTAssertTrue(originalMetaCustomData.contains("<Value>RoundTripMetaValue-Expected</Value>"))
        XCTAssertTrue(originalEntryCustomData.contains("<Key>RoundTripEntryKey</Key>"))
        XCTAssertTrue(originalEntryCustomData.contains("<Value>RoundTripEntryValue-Expected</Value>"))

        let reparsed = try serializeAndParse(parsed)
        let reparsedEntry = try controlledUnknownsEntry(in: reparsed.rootGroup)

        let reparsedMetaCustomData = try XCTUnwrap(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripMetaKey",
                in: reparsed.meta.unknownXML
            )
        )
        let reparsedEntryCustomData = try XCTUnwrap(
            unknownFragment(
                named: "CustomData",
                containing: "RoundTripEntryKey",
                in: reparsedEntry.unknownXML
            )
        )

        XCTAssertEqual(originalMetaCustomData, reparsedMetaCustomData)
        XCTAssertEqual(originalEntryCustomData, reparsedEntryCustomData)
    }

    func test_protectedValues_reEncryptedDeterministically_roundTrip() throws {
        let parsed = try parseFixture(.test)

        var serializerA = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlA = try serializerA.serialize()

        var serializerB = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlB = try serializerB.serialize()

        XCTAssertEqual(xmlA, xmlB, "Protected value encryption should be deterministic for a fixed inner stream key")

        let reparsed = try parseXML(xmlA)
        let originalEntry = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "GitHub" })
        let reparsedEntry = try XCTUnwrap(reparsed.rootGroup.allEntries.first { $0.title == "GitHub" })

        XCTAssertEqual(
            try originalEntry.password.decrypt(using: roundTripSessionKey),
            try reparsedEntry.password.decrypt(using: roundTripSessionKey)
        )
    }

    func test_serializerEmitsValidXML_isUTF8WithBOM() throws {
        let parsed = try parseFixture(.test)

        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlData = try serializer.serialize()

        let expectedPrefix = Data([0xEF, 0xBB, 0xBF]) +
            Data("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n".utf8)
        XCTAssertTrue(xmlData.starts(with: expectedPrefix))

        let xmlParser = XMLParser(data: xmlData)
        XCTAssertTrue(xmlParser.parse(), xmlParser.parserError?.localizedDescription ?? "Serialized XML failed to parse")
    }

    private func assertFixtureRoundTrips(_ fixture: Fixture) throws {
        let parsed = try parseFixture(fixture)
        let reparsed = try serializeAndParse(parsed)

        XCTAssertEqual(parsed.meta.recycleBinUUID, reparsed.meta.recycleBinUUID)
        XCTAssertEqual(parsed.meta.maintenanceHistoryDays, reparsed.meta.maintenanceHistoryDays)
        XCTAssertEqual(parsed.meta.historyMaxItems, reparsed.meta.historyMaxItems)
        XCTAssertEqual(parsed.meta.historyMaxSize, reparsed.meta.historyMaxSize)
        XCTAssertEqual(normalizedOpaqueXML(parsed.meta.unknownXML), normalizedOpaqueXML(reparsed.meta.unknownXML))
        try assertGroupsEqual(parsed.rootGroup, reparsed.rootGroup)
    }

    private func parseFixture(_ fixture: Fixture) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let bundle = Bundle(for: Self.self)
        let databaseURL = try TestDatabaseSupport.fixtureURL(
            named: fixture.name,
            subdirectory: fixture.subdirectory,
            bundle: bundle
        )
        let databaseData = try Data(contentsOf: databaseURL)

        let keyFileData: Data?
        if let keyFileName = fixture.keyFileName, let keyFileExtension = fixture.keyFileExtension {
            let keyURL = try TestDatabaseSupport.fixtureURL(named: keyFileName, extension: keyFileExtension, bundle: bundle)
            keyFileData = try Data(contentsOf: keyURL)
        } else {
            keyFileData = nil
        }

        if fixture.keyFileName != nil {
            return try KDBXParser.parseWithMeta(
                data: databaseData,
                password: fixture.password,
                keyFileData: keyFileData,
                sessionKey: roundTripSessionKey
            )
        }

        let password = try XCTUnwrap(fixture.password)
        return try KDBXParser.parseWithMeta(
            data: databaseData,
            password: password,
            sessionKey: roundTripSessionKey
        )
    }

    private func serializeAndParse(
        _ parsed: (rootGroup: KPGroup, meta: KPMeta)
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlData = try serializer.serialize()
        return try parseXML(xmlData)
    }

    private func parseXML(_ xmlData: Data) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let parser = KDBXXMLParser(
            data: xmlData,
            innerStreamKey: roundTripInnerStreamKey,
            innerStreamID: KDBXParser.innerStreamChaCha20,
            sessionKey: roundTripSessionKey
        )
        return try parser.parse()
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
        XCTAssertEqual(try lhs.password.decrypt(using: roundTripSessionKey), try rhs.password.decrypt(using: roundTripSessionKey), file: file, line: line)
        XCTAssertEqual(lhs.url, rhs.url, file: file, line: line)
        XCTAssertEqual(lhs.notes, rhs.notes, file: file, line: line)
        XCTAssertEqual(lhs.iconID, rhs.iconID, file: file, line: line)
        XCTAssertEqual(lhs.tags, rhs.tags, file: file, line: line)
        XCTAssertEqual(lhs.customFields, rhs.customFields, file: file, line: line)
        XCTAssertEqual(lhs.creationTime, rhs.creationTime, file: file, line: line)
        XCTAssertEqual(lhs.lastModificationTime, rhs.lastModificationTime, file: file, line: line)
        XCTAssertEqual(lhs.expires, rhs.expires, file: file, line: line)
        XCTAssertEqual(lhs.expiryTime, rhs.expiryTime, file: file, line: line)
        XCTAssertEqual(normalizedOpaqueXML(lhs.unknownXML), normalizedOpaqueXML(rhs.unknownXML), file: file, line: line)
        XCTAssertEqual(lhs.attachments, rhs.attachments, file: file, line: line)
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
                try lhs.secret.decrypt(using: roundTripSessionKey),
                try rhs.secret.decrypt(using: roundTripSessionKey),
                file: file,
                line: line
            )
        default:
            XCTFail("TOTP config mismatch", file: file, line: line)
        }
    }

    private func controlledUnknownsEntry(in rootGroup: KPGroup) throws -> KPEntry {
        try XCTUnwrap(rootGroup.allEntries.first { $0.title == "Controlled Unknowns" })
    }

    private func unknownFragment(
        named elementName: String,
        containing expectedContent: String,
        in unknownXML: OpaqueXMLNodes,
        path: [String] = []
    ) -> String? {
        unknownXML.nodes
            .filter { $0.path == path }
            .map(\.xml)
            .first { xml in
                let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.hasPrefix("<\(elementName)") && trimmed.contains(expectedContent)
            }
    }

    // MARK: - Regression: base64 dates containing 'T' must parse

    func test_parseKPDate_base64WithLetterT_roundTrips() throws {
        // "9eT23g4AAAA=" is a valid KDBX4 base64 timestamp whose encoding
        // contains the letter 'T'. A naive "contains T → ISO-8601" heuristic
        // would misroute this string and silently lose the date.
        let entry = KPEntry(
            title: "Date-T",
            creationTime: Date(timeIntervalSinceReferenceDate: 0)
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let parsed = (rootGroup: root, meta: KPMeta())
        let reparsed = try serializeAndParse(parsed)
        let reparsedEntry = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        XCTAssertNotNil(reparsedEntry.creationTime, "CreationTime should survive round-trip")
        XCTAssertEqual(
            entry.creationTime!.timeIntervalSinceReferenceDate,
            reparsedEntry.creationTime!.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
    }

    func test_entryExpiry_parsesAndSurvivesRoundTrip() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name><Entry>
        <Times><ExpiryTime>2020-01-02T03:04:05Z</ExpiryTime><Expires>True</Expires></Times>
        <String><Key>Title</Key><Value>Expired Entry</Value></String>
        </Entry></Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first)
        XCTAssertTrue(entry.expires)
        XCTAssertTrue(entry.isExpired(at: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(
            try XCTUnwrap(entry.expiryTime).timeIntervalSince1970,
            1_577_934_245,
            accuracy: 1
        )

        let reparsed = try serializeAndParse(parsed)
        let reparsedEntry = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        XCTAssertEqual(reparsedEntry.expires, entry.expires)
        XCTAssertEqual(reparsedEntry.expiryTime, entry.expiryTime)
    }

    // MARK: - DeletedObjects round-trip

    func test_deletedObjects_survivesRoundTrip() throws {
        let deletedUUID = UUID()
        let deletionTime = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let meta = KPMeta(deletedObjects: [KPDeletedObject(uuid: deletedUUID, deletionTime: deletionTime)])
        let root = KPGroup(name: "Root", entries: [KPEntry(title: "Entry")])
        let reparsed = try serializeAndParse((rootGroup: root, meta: meta))

        XCTAssertEqual(reparsed.meta.deletedObjects.count, 1)
        let tombstone = try XCTUnwrap(reparsed.meta.deletedObjects.first)
        XCTAssertEqual(tombstone.uuid, deletedUUID)
        XCTAssertEqual(
            tombstone.deletionTime.timeIntervalSinceReferenceDate,
            deletionTime.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
    }

    // MARK: - Regression: Value whitespace preserved

    func test_valueWhitespace_trailingSpaces_preserved() throws {
        let entry = KPEntry(
            title: "Whitespace",
            username: "user   "
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let reparsed = try serializeAndParse((rootGroup: root, meta: KPMeta()))
        let reparsedEntry = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        XCTAssertEqual(reparsedEntry.username, "user   ", "Trailing whitespace must be preserved")
    }

    // MARK: - Regression: otp URL preserved

    func test_otpURL_preservedOnRoundTrip() throws {
        let uri = "otpauth://totp/Example:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&period=30&digits=6&algorithm=SHA1"
        let secret = "JBSWY3DPEHPK3PXP"
        let encryptedSecret = try EncryptedValue.encrypt(secret, using: roundTripSessionKey)
        let entry = KPEntry(
            title: "OTP",
            totpConfig: TOTPConfig(secret: encryptedSecret),
            otpURL: uri,
            protectedStringKeys: ["otp"]
        )
        let root = KPGroup(name: "Root", entries: [entry])
        let reparsed = try serializeAndParse((rootGroup: root, meta: KPMeta()))
        let reparsedEntry = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        XCTAssertEqual(reparsedEntry.otpURL, uri, "otp URL should survive round-trip")
        XCTAssertNotNil(reparsedEntry.totpConfig, "TOTP config should still be derived from the URL")
    }

    // MARK: - Regression: empty Tags element preserved

    func test_emptyTags_elementPreserved() throws {
        let entry = KPEntry(
            title: "Empty Tags",
            hasTagsElement: true
        )
        let root = KPGroup(name: "Root", entries: [entry])

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlData = try serializer.serialize()
        let xmlString = String(data: xmlData, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<Tags></Tags>"), "Empty Tags element should be emitted")

        let reparsed = try parseXML(xmlData)
        let reparsedEntry = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        XCTAssertTrue(reparsedEntry.hasTagsElement, "hasTagsElement should survive round-trip")
        XCTAssertTrue(reparsedEntry.tags.isEmpty, "tags array should remain empty")
    }
}
