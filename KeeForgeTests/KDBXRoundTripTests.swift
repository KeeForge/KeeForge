import CryptoKit
import XCTest
@testable import KeeForge

final class KDBXRoundTripTests: XCTestCase {
    private let roundTripSessionKey = SymmetricKey(size: .bits256)
    private let roundTripInnerStreamKey = Data("KeeForge Slice01 Inner Stream Key".utf8)

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

    @MainActor
    func test_editSaveReload_preservesOtpauthURLOnUnrelatedEdit() throws {
        let uri = "otpauth://totp/Example:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&period=30&digits=6&algorithm=SHA1"
        let entry = KPEntry(
            title: "Otpauth Entry",
            password: try EncryptedValue.encrypt("password", using: roundTripSessionKey),
            totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: roundTripSessionKey)),
            otpURL: uri
        )
        let rootGroup = KPGroup(id: UUID(), name: "Root", entries: [entry])
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: roundTripSessionKey)
        viewModel.notes = "Edited"

        let draft = DatabaseDraft(rootGroup: rootGroup, meta: KPMeta(), sessionKey: roundTripSessionKey)
        let updated = try draft.apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first)

        XCTAssertEqual(
            reloaded.otpURL, uri,
            "The otpauth:// URI (issuer, label, custom parameters) must survive edits that leave TOTP unchanged"
        )
        XCTAssertNil(reloaded.customFields["TimeOtp-Secret-Base32"])
    }

    @MainActor
    func test_createSaveReload_enrollmentFromOTPAuthURIStoresProtectedVerbatimURI() throws {
        let raw = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&period=45&digits=8&algorithm=SHA256"
        let rootGroup = KPGroup(id: UUID(), name: "Root")
        let viewModel = EntryEditViewModel(createIn: rootGroup.id)
        viewModel.title = "Enrolled"
        viewModel.applyOTPAuthURI(try OTPAuthURI(string: raw))

        let draft = DatabaseDraft(rootGroup: rootGroup, meta: KPMeta(), sessionKey: roundTripSessionKey)
        let updated = try draft.apply(.createEntry(parentGroupID: rootGroup.id, draft: viewModel.entryDraftPayload))
        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        let reloadedTOTP = try XCTUnwrap(reloaded.totpConfig)

        XCTAssertEqual(reloaded.otpURL, raw, "The enrollment URI must be stored verbatim in the otp field")
        XCTAssertTrue(reloaded.protectedStringKeys.contains("otp"), "The freshly authored otp field must be protected")
        XCTAssertEqual(try reloadedTOTP.secret.decrypt(using: roundTripSessionKey), "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(reloadedTOTP.period, 45)
        XCTAssertEqual(reloadedTOTP.digits, 8)
        XCTAssertEqual(reloadedTOTP.algorithm, .sha256)
        XCTAssertFalse(
            reloaded.customFields.keys.contains { $0.hasPrefix("TimeOtp-") },
            "URI enrollment must not also author TimeOtp-* fields"
        )
    }

    @MainActor
    func test_createSaveReload_uppercaseSchemeEnrollmentStaysReadable() throws {
        // QR alphanumeric mode encodes uppercase; the stored URI's scheme and
        // host are lowercased at authoring so the parser's case-sensitive
        // "otpauth://" prefix check still reads it back — otherwise the entry
        // would reload without a TOTP config and a later unrelated edit would
        // silently drop the otp field.
        let rootGroup = KPGroup(id: UUID(), name: "Root")
        let viewModel = EntryEditViewModel(createIn: rootGroup.id)
        viewModel.title = "Enrolled Uppercase"
        viewModel.applyOTPAuthURI(try OTPAuthURI(string: "OTPAUTH://TOTP/Ex:a?SECRET=JBSWY3DPEHPK3PXP"))

        let draft = DatabaseDraft(rootGroup: rootGroup, meta: KPMeta(), sessionKey: roundTripSessionKey)
        let updated = try draft.apply(.createEntry(parentGroupID: rootGroup.id, draft: viewModel.entryDraftPayload))
        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        let reloadedTOTP = try XCTUnwrap(
            reloaded.totpConfig,
            "The stored uppercase-scheme enrollment must still parse as a TOTP config"
        )

        XCTAssertEqual(
            reloaded.otpURL, "otpauth://totp/Ex:a?SECRET=JBSWY3DPEHPK3PXP",
            "Scheme and host lowercased; label and query byte-verbatim"
        )
        XCTAssertEqual(try reloadedTOTP.secret.decrypt(using: roundTripSessionKey), "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(reloadedTOTP.period, 30)
        XCTAssertEqual(reloadedTOTP.digits, 6)
    }

    @MainActor
    func test_editSaveReload_minimalKeeOTPSourceGainsRewrittenParameters() throws {
        let entry = KPEntry(
            title: "KeeOTP Minimal",
            password: try EncryptedValue.encrypt("password", using: roundTripSessionKey),
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DP", using: roundTripSessionKey),
                decodedSecret: try EncryptedValue.encrypt(Data("Hello".utf8), using: roundTripSessionKey),
                keeOTPSource: KeeOTPSource(fieldName: "otp", rawQuery: "key=JBSWY3DP")
            ),
            otpURL: "key=JBSWY3DP"
        )
        let rootGroup = KPGroup(id: UUID(), name: "Root", entries: [entry])
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: roundTripSessionKey)
        viewModel.totpPeriod = 45

        let draft = DatabaseDraft(rootGroup: rootGroup, meta: KPMeta(), sessionKey: roundTripSessionKey)
        let updated = try draft.apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reloaded = try XCTUnwrap(reparsed.rootGroup.allEntries.first)
        let reloadedTOTP = try XCTUnwrap(reloaded.totpConfig)

        XCTAssertEqual(reloadedTOTP.period, 45, "A period edit must survive even when the source omitted the step parameter")
        XCTAssertTrue(reloadedTOTP.keeOTPSource?.rawQuery.contains("step=45") == true)
        XCTAssertEqual(
            TOTPGenerator.resolveSecret(config: reloadedTOTP, sessionKey: roundTripSessionKey)?.data,
            Data("Hello".utf8)
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

    private func assertFixtureRoundTrips(
        _ fixture: KDBXTestFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let parsed = try parseFixture(fixture)
        let reparsed = try serializeAndParse(parsed)

        try KDBXTreeAssertions.assertTreesEqual(
            parsed,
            reparsed,
            sessionKey: roundTripSessionKey,
            file: file,
            line: line
        )
    }

    private func parseFixture(_ fixture: KDBXTestFixture) throws -> (rootGroup: KPGroup, meta: KPMeta) {
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

    func test_extremeBinaryTimestampsSerializeWithoutTrappingAndSaturate() throws {
        let maximumTimestamp = binaryTimestamp(Int64.max)
        let minimumTimestamp = binaryTimestamp(Int64.min)
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name><Entry>
        <Times><CreationTime>\(maximumTimestamp)</CreationTime><LastModificationTime>\(minimumTimestamp)</LastModificationTime></Times>
        <String><Key>Title</Key><Value>Extreme Dates</Value></String>
        </Entry></Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )

        let serialized = try serializer.serialize()
        let serializedXML = String(decoding: serialized, as: UTF8.self)

        XCTAssertTrue(serializedXML.contains("<CreationTime>\(maximumTimestamp)</CreationTime>"))
        XCTAssertTrue(serializedXML.contains("<LastModificationTime>\(minimumTimestamp)</LastModificationTime>"))
        XCTAssertNoThrow(try parseXML(serialized))
    }

    func test_ordinaryBinaryTimestampStillRoundTripsExactly() throws {
        let timestamp = binaryTimestamp(63_113_904_000)
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name><Entry>
        <Times><CreationTime>\(timestamp)</CreationTime></Times>
        <String><Key>Title</Key><Value>Ordinary Date</Value></String>
        </Entry></Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let serializedXML = String(decoding: try serializer.serialize(), as: UTF8.self)

        XCTAssertTrue(serializedXML.contains("<CreationTime>\(timestamp)</CreationTime>"))
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

    private func binaryTimestamp(_ seconds: Int64) -> String {
        var littleEndian = seconds.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }.base64EncodedString()
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

    // MARK: - EnableSearching round-trip

    func test_enableSearching_allThreeStates_surviveRoundTrip() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><Name>Off</Name><EnableSearching>False</EnableSearching></Group>
        <Group><Name>On</Name><EnableSearching>True</EnableSearching></Group>
        <Group><Name>Inherit</Name><EnableSearching>null</EnableSearching></Group>
        <Group><Name>NoElement</Name></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let reparsed = try serializeAndParse(parsed)

        for tree in [parsed, reparsed] {
            // `rootGroup` is the synthetic wrapper for `<Root>`; the group named
            // "Root" in the XML is its single child.
            let container = try XCTUnwrap(tree.rootGroup.groups.first)
            let groups = Dictionary(
                uniqueKeysWithValues: container.groups.map { ($0.name, $0) }
            )
            XCTAssertEqual(groups["Off"]?.searchingEnabled, .disabled)
            XCTAssertEqual(groups["On"]?.searchingEnabled, .enabled)
            XCTAssertEqual(groups["Inherit"]?.searchingEnabled, .inherit)
            XCTAssertNil(
                groups["NoElement"]?.searchingEnabled,
                "A group without the element must stay without it"
            )
        }
    }

    func test_enableSearching_absentElement_isNotAddedOnWrite() throws {
        let root = KPGroup(name: "Root", groups: [KPGroup(name: "Plain")])

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertFalse(
            xmlString.contains("EnableSearching"),
            "Writing a group that never had the element must not invent one"
        )
    }

    /// The value KeeForge writes has to be one KeePass itself accepts, so a
    /// database stays usable in both apps.
    func test_enableSearching_writesKeePassCasing() throws {
        let root = KPGroup(
            name: "Root",
            groups: [KPGroup(name: "Hidden", searchingEnabled: .disabled)]
        )

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("<EnableSearching>False</EnableSearching>"))
    }

    /// An unparsable value must fall through to the opaque-XML path rather than
    /// being silently rewritten or dropped.
    func test_enableSearching_unrecognizedValue_isPreservedVerbatim() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><Name>Weird</Name><EnableSearching>maybe</EnableSearching></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let container = try XCTUnwrap(parsed.rootGroup.groups.first)
        let weird = try XCTUnwrap(container.groups.first)
        XCTAssertNil(weird.searchingEnabled, "\"maybe\" is not a tri-state value")

        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(
            xmlString.contains("<EnableSearching>maybe</EnableSearching>"),
            "Unknown values must round-trip untouched"
        )
    }

    /// Regression guard for the opaque-XML position bookkeeping: making
    /// `<EnableSearching>` a structured element shifts the insertion indices of
    /// the unmodelled siblings around it, and none of them may be lost.
    func test_enableSearching_doesNotDisturbSurroundingUnknownElements() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Nested</Name><Notes>group notes</Notes>\
        <IconID>48</IconID><IsExpanded>True</IsExpanded>\
        <DefaultAutoTypeSequence>{USERNAME}</DefaultAutoTypeSequence>\
        <EnableAutoType>null</EnableAutoType>\
        <EnableSearching>False</EnableSearching>\
        <LastTopVisibleEntry>AAAAAAAAAAAAAAAAAAAAAA==</LastTopVisibleEntry></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("<Notes>group notes</Notes>"))
        XCTAssertTrue(xmlString.contains("<DefaultAutoTypeSequence>{USERNAME}</DefaultAutoTypeSequence>"))
        XCTAssertTrue(xmlString.contains("<EnableAutoType>null</EnableAutoType>"))
        XCTAssertTrue(xmlString.contains("<LastTopVisibleEntry>AAAAAAAAAAAAAAAAAAAAAA==</LastTopVisibleEntry>"))

        let reparsed = try parseXML(Data(xmlString.utf8))
        let container = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let nested = try XCTUnwrap(container.groups.first)
        XCTAssertEqual(nested.searchingEnabled, .disabled)
        XCTAssertEqual(nested.name, "Nested")
    }

    /// An unparsable `<EnableSearching>` is preserved opaquely, so hiding that
    /// same group later used to emit the preserved copy *and* the new
    /// structured element, leaving two of them in one group. KeeForge would
    /// still read its own output correctly, but another client resolving the
    /// first one would silently ignore the user's choice.
    func test_enableSearching_toggleAfterUnrecognizedValue_writesExactlyOneElement() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Weird</Name>\
        <Notes>keep me</Notes>\
        <EnableSearching>maybe</EnableSearching></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let container = try XCTUnwrap(parsed.rootGroup.groups.first)
        let weird = try XCTUnwrap(container.groups.first)
        XCTAssertNil(weird.searchingEnabled, "Precondition: \"maybe\" is not a tri-state value")

        let draft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: roundTripSessionKey
        )
        let updated = try draft.apply(
            .setGroupSearchingEnabled(groupID: weird.id, value: .disabled)
        )

        var serializer = KDBXXMLSerializer(
            rootGroup: updated.rootGroup,
            meta: updated.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertEqual(
            xmlString.components(separatedBy: "<EnableSearching>").count - 1,
            1,
            "The stale opaque element must be replaced, not duplicated"
        )
        XCTAssertTrue(xmlString.contains("<EnableSearching>False</EnableSearching>"))
        XCTAssertFalse(xmlString.contains("maybe"))
        XCTAssertTrue(
            xmlString.contains("<Notes>keep me</Notes>"),
            "Only the superseded element is dropped; other opaque siblings stay"
        )

        let reparsed = try parseXML(Data(xmlString.utf8))
        let reparsedContainer = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let reparsedWeird = try XCTUnwrap(reparsedContainer.groups.first)
        XCTAssertEqual(reparsedWeird.searchingEnabled, .disabled)
    }

    /// Untouched groups must keep an unparsable value verbatim — the fix above
    /// is scoped to the group the user actually edited.
    func test_enableSearching_unrecognizedValue_survivesAnEditToAnotherGroup() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Weird</Name>\
        <EnableSearching>maybe</EnableSearching></Group>
        <Group><UUID>u9nSbYQCTk6Vg0kJ0YQ1Qw==</UUID><Name>Other</Name></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let container = try XCTUnwrap(parsed.rootGroup.groups.first)
        let other = try XCTUnwrap(container.groups.first { $0.name == "Other" })

        let draft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: roundTripSessionKey
        )
        let updated = try draft.apply(
            .setGroupSearchingEnabled(groupID: other.id, value: .disabled)
        )

        var serializer = KDBXXMLSerializer(
            rootGroup: updated.rootGroup,
            meta: updated.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("<EnableSearching>maybe</EnableSearching>"))
        XCTAssertTrue(xmlString.contains("<EnableSearching>False</EnableSearching>"))
    }

    // MARK: - Group Tags round-trip (KDBX 4.1)

    func test_groupTags_allThreeStates_surviveRoundTrip() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><Name>Tagged</Name><Tags>team;shared</Tags></Group>
        <Group><Name>EmptyElement</Name><Tags></Tags></Group>
        <Group><Name>NoElement</Name></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let reparsed = try serializeAndParse(parsed)

        for tree in [parsed, reparsed] {
            // `rootGroup` is the synthetic wrapper for `<Root>`; the group named
            // "Root" in the XML is its single child.
            let container = try XCTUnwrap(tree.rootGroup.groups.first)
            let groups = Dictionary(
                uniqueKeysWithValues: container.groups.map { ($0.name, $0) }
            )
            XCTAssertEqual(groups["Tagged"]?.tags, ["team", "shared"])
            XCTAssertEqual(groups["Tagged"]?.hasTagsElement, true)
            XCTAssertEqual(groups["EmptyElement"]?.tags, [])
            XCTAssertEqual(
                groups["EmptyElement"]?.hasTagsElement,
                true,
                "An empty <Tags></Tags> element is present, just contentless"
            )
            XCTAssertEqual(groups["NoElement"]?.tags, [])
            XCTAssertEqual(
                groups["NoElement"]?.hasTagsElement,
                false,
                "A group without the element must stay without it"
            )
        }
    }

    func test_groupTags_absentElement_isNotAddedOnWrite() throws {
        let root = KPGroup(name: "Root", groups: [KPGroup(name: "Plain")])

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertFalse(
            xmlString.contains("<Tags"),
            "Writing a group that never had the element must not invent one — KeeForge has no group-tag write path"
        )
    }

    /// The stored text KeeForge writes has to be one KeePass itself reads
    /// back, so a database stays usable in both apps. Comma-joined matches
    /// the entry serializer (KeePass canonically writes `;` but every major
    /// implementation reads both).
    func test_groupTags_writesCommaJoinedText() throws {
        let root = KPGroup(
            name: "Root",
            groups: [KPGroup(name: "Tagged", tags: ["team", "shared"], hasTagsElement: true)]
        )

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("<Tags>team,shared</Tags>"))
    }

    func test_groupTags_emptyElement_preserved() throws {
        let root = KPGroup(
            name: "Root",
            groups: [KPGroup(name: "Empty", hasTagsElement: true)]
        )

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlData = try serializer.serialize()
        let xmlString = String(data: xmlData, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<Tags></Tags>"), "Empty group Tags element should be emitted")

        let reparsed = try parseXML(xmlData)
        let reparsedGroup = try XCTUnwrap(reparsed.rootGroup.groups.first)
        XCTAssertTrue(reparsedGroup.hasTagsElement, "hasTagsElement should survive round-trip")
        XCTAssertTrue(reparsedGroup.tags.isEmpty, "tags array should remain empty")
    }

    /// Read-time rewriting is forbidden: the parser splits and trims but
    /// never dedupes, so a foreign file's duplicated group tag survives a
    /// KeeForge save exactly as written (`TagNormalizer`'s dedupe is an
    /// edit-side policy and deliberately not applied here).
    func test_groupTags_duplicatesInStoredText_surviveRoundTripUnchanged() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><Name>Duped</Name><Tags>dup; dup ,unique</Tags></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let container = try XCTUnwrap(parsed.rootGroup.groups.first)
        let duped = try XCTUnwrap(container.groups.first)
        XCTAssertEqual(duped.tags, ["dup", "dup", "unique"], "Precondition: parse keeps duplicates and order")

        let reparsed = try serializeAndParse(parsed)
        let reparsedContainer = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let reparsedDuped = try XCTUnwrap(reparsedContainer.groups.first)
        XCTAssertEqual(reparsedDuped.tags, ["dup", "dup", "unique"])
    }

    /// Regression guard for the opaque-XML position bookkeeping: making the
    /// group `<Tags>` a structured element shifts the insertion indices of
    /// the unmodelled siblings around it, and none of them may be lost or
    /// moved relative to each other.
    func test_groupTags_doNotDisturbSurroundingUnknownElements() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Nested</Name><Notes>group notes</Notes>\
        <IconID>48</IconID><IsExpanded>True</IsExpanded>\
        <DefaultAutoTypeSequence>{USERNAME}</DefaultAutoTypeSequence>\
        <EnableAutoType>null</EnableAutoType>\
        <EnableSearching>False</EnableSearching>\
        <LastTopVisibleEntry>AAAAAAAAAAAAAAAAAAAAAA==</LastTopVisibleEntry>\
        <Tags>team;shared</Tags></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let originalContainer = try XCTUnwrap(parsed.rootGroup.groups.first)
        let originalNested = try XCTUnwrap(originalContainer.groups.first)

        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("<Notes>group notes</Notes>"))
        XCTAssertTrue(xmlString.contains("<DefaultAutoTypeSequence>{USERNAME}</DefaultAutoTypeSequence>"))
        XCTAssertTrue(xmlString.contains("<EnableAutoType>null</EnableAutoType>"))
        XCTAssertTrue(xmlString.contains("<LastTopVisibleEntry>AAAAAAAAAAAAAAAAAAAAAA==</LastTopVisibleEntry>"))

        let reparsed = try parseXML(Data(xmlString.utf8))
        let container = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let nested = try XCTUnwrap(container.groups.first)
        XCTAssertEqual(nested.tags, ["team", "shared"])
        XCTAssertTrue(nested.hasTagsElement)
        XCTAssertEqual(nested.searchingEnabled, .disabled)
        XCTAssertEqual(nested.name, "Nested")
        XCTAssertEqual(
            KDBXTreeAssertions.normalizedOpaqueXML(nested.unknownXML),
            KDBXTreeAssertions.normalizedOpaqueXML(originalNested.unknownXML),
            "Every unknown sibling must keep its exact position across a second parse"
        )
    }

    /// Group tags survive an edit to another part of the tree: creating an
    /// entry inside the tagged group runs `DatabaseDraft.copyGroup` on it and
    /// `KPGroup.replacingChildGroup` on its tagged ancestor — the two funnels
    /// that would silently drop the fields if they failed to forward them.
    func test_groupTags_surviveAnEditToAnotherEntry() throws {
        let xml = """
        <KeePassFile><Root><Group><UUID>u9nSbYQCTk6Vg0kJ0YQ1Qw==</UUID><Name>Root</Name><Tags>inherited</Tags>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Tagged</Name><Tags>team;shared</Tags></Group>
        <Group><UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID><Name>EmptySibling</Name><Tags></Tags></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let container = try XCTUnwrap(parsed.rootGroup.groups.first)
        let tagged = try XCTUnwrap(container.groups.first { $0.name == "Tagged" })

        let draft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: roundTripSessionKey
        )
        let updated = try draft.apply(
            .createEntry(parentGroupID: tagged.id, draft: EntryDraftPayload(title: "New Entry"))
        )

        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reparsedContainer = try XCTUnwrap(reparsed.rootGroup.groups.first)
        XCTAssertEqual(
            reparsedContainer.tags,
            ["inherited"],
            "replacingChildGroup must forward the edited group's ancestor tags"
        )
        let reparsedTagged = try XCTUnwrap(reparsedContainer.groups.first { $0.name == "Tagged" })
        XCTAssertEqual(reparsedTagged.tags, ["team", "shared"], "copyGroup must forward the edited group's own tags")
        XCTAssertTrue(reparsedTagged.hasTagsElement)
        XCTAssertEqual(reparsedTagged.entries.map(\.title), ["New Entry"])
        let emptySibling = try XCTUnwrap(reparsedContainer.groups.first { $0.name == "EmptySibling" })
        XCTAssertTrue(emptySibling.hasTagsElement, "Untouched siblings keep their empty element")
        XCTAssertTrue(emptySibling.tags.isEmpty)
    }

    /// `applySetGroupSearchingEnabled` rebuilds the edited group through an
    /// explicit `KPGroup` init rather than `copyGroup`; toggling AutoFill
    /// visibility on a tagged group must not eat its tags.
    func test_groupTags_surviveTogglingAutoFillVisibility() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Tagged</Name><Tags>team;shared</Tags></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let container = try XCTUnwrap(parsed.rootGroup.groups.first)
        let tagged = try XCTUnwrap(container.groups.first)

        let draft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: roundTripSessionKey
        )
        let updated = try draft.apply(
            .setGroupSearchingEnabled(groupID: tagged.id, value: .disabled)
        )

        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reparsedContainer = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let reparsedTagged = try XCTUnwrap(reparsedContainer.groups.first)
        XCTAssertEqual(reparsedTagged.searchingEnabled, .disabled)
        XCTAssertEqual(reparsedTagged.tags, ["team", "shared"])
        XCTAssertTrue(reparsedTagged.hasTagsElement)
    }

    /// `applySetGroupIcon` also rebuilds the edited group through an explicit
    /// `KPGroup` init; picking a standard icon for a tagged group must not eat
    /// its tags (or an empty element's presence flag) either.
    func test_groupTags_surviveChangingTheGroupIcon() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Tagged</Name><Tags>team;shared</Tags></Group>
        <Group><UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID><Name>EmptyElement</Name><Tags></Tags></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let container = try XCTUnwrap(parsed.rootGroup.groups.first)
        let tagged = try XCTUnwrap(container.groups.first { $0.name == "Tagged" })
        let emptyElement = try XCTUnwrap(container.groups.first { $0.name == "EmptyElement" })

        let draft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: roundTripSessionKey
        )
        let updated = try draft
            .apply(.setGroupIcon(groupID: tagged.id, iconID: 30))
            .apply(.setGroupIcon(groupID: emptyElement.id, iconID: 30))

        let reparsed = try serializeAndParse((rootGroup: updated.rootGroup, meta: updated.meta))
        let reparsedContainer = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let reparsedTagged = try XCTUnwrap(reparsedContainer.groups.first { $0.name == "Tagged" })
        XCTAssertEqual(reparsedTagged.iconID, 30)
        XCTAssertEqual(reparsedTagged.tags, ["team", "shared"])
        XCTAssertTrue(reparsedTagged.hasTagsElement)
        let reparsedEmpty = try XCTUnwrap(reparsedContainer.groups.first { $0.name == "EmptyElement" })
        XCTAssertEqual(reparsedEmpty.iconID, 30)
        XCTAssertTrue(reparsedEmpty.tags.isEmpty)
        XCTAssertTrue(reparsedEmpty.hasTagsElement, "The empty <Tags></Tags> element survives an icon change")
    }

    // MARK: - Group Notes round-trip

    /// Group `<Notes>` is a structured `KPGroup` field, so the text has to come
    /// back byte-for-byte. Unlike group `<Name>`, it is deliberately not
    /// trimmed: leading and trailing whitespace in free-form notes is the
    /// author's, and a save must not quietly rewrite it.
    func test_groupNotes_structuredRoundTrip_preservesWhitespaceAndNewlinesExactly() throws {
        let notes = "  leading spaces\nsecond line\n\ttabbed\ntrailing newline\n  "
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>\
        <Group><Name>  Padded Name  </Name><Notes>\(notes)</Notes></Group>\
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let reparsed = try serializeAndParse(parsed)

        for tree in [parsed, reparsed] {
            let container = try XCTUnwrap(tree.rootGroup.groups.first)
            let group = try XCTUnwrap(container.groups.first)
            XCTAssertEqual(group.notes, notes)
            XCTAssertTrue(group.hasNotesElement)
            XCTAssertEqual(group.name, "Padded Name", "Group <Name> is trimmed; <Notes> deliberately is not")
            XCTAssertFalse(
                group.unknownXML.nodes.contains { $0.elementName == "Notes" },
                "<Notes> is structured now, so no opaque copy may be left behind"
            )
        }
    }

    func test_groupNotes_presenceThreeStates_surviveRoundTrip() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><Name>WithNotes</Name><Notes>a note</Notes></Group>
        <Group><Name>EmptyElement</Name><Notes></Notes></Group>
        <Group><Name>NoElement</Name></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let reparsed = try serializeAndParse(parsed)

        for tree in [parsed, reparsed] {
            let container = try XCTUnwrap(tree.rootGroup.groups.first)
            let groups = Dictionary(uniqueKeysWithValues: container.groups.map { ($0.name, $0) })
            XCTAssertEqual(groups["WithNotes"]?.notes, "a note")
            XCTAssertEqual(groups["WithNotes"]?.hasNotesElement, true)
            XCTAssertEqual(groups["EmptyElement"]?.notes, "")
            XCTAssertEqual(
                groups["EmptyElement"]?.hasNotesElement,
                true,
                "An empty <Notes></Notes> element is present, just contentless"
            )
            XCTAssertEqual(groups["NoElement"]?.notes, "")
            XCTAssertEqual(
                groups["NoElement"]?.hasNotesElement,
                false,
                "A group without the element must stay without it"
            )
        }
    }

    func test_groupNotes_absentElement_isNotAddedOnWrite() throws {
        let root = KPGroup(name: "Root", groups: [KPGroup(name: "Plain")])

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertFalse(
            xmlString.contains("<Notes"),
            "Writing a group that never had the element must not invent one"
        )
    }

    /// KeePass's own `WriteGroup` emits `UUID, Name, Notes, IconID, …`, so
    /// writing `<Notes>` anywhere else would move every opaque fragment a
    /// KeePass-written file recorded after it.
    func test_groupNotes_writtenImmediatelyAfterName() throws {
        let root = KPGroup(
            name: "Root",
            groups: [KPGroup(name: "Ordered", notes: "a note", hasNotesElement: true)]
        )

        var serializer = KDBXXMLSerializer(
            rootGroup: root,
            meta: KPMeta(),
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("<Name>Ordered</Name><Notes>a note</Notes><IconID>"))
    }

    /// Regression guard for the opaque-XML position bookkeeping: promoting the
    /// group `<Notes>` to a structured element shifts the insertion indices of
    /// the unmodelled siblings around it. The parser's read handler and its
    /// `knownChildCount` arm have to accept the element under exactly the same
    /// conditions — if they disagree, every opaque fragment after `<Notes>` in
    /// that group slides one position, and this is the test that sees it.
    func test_groupNotes_doNotDisturbSurroundingUnknownElements() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Nested</Name>\
        <CustomIconUUID>3q2+7wAAAAAAAAAAAAAAAA==</CustomIconUUID>\
        <Notes>first line
        second line</Notes>\
        <IconID>48</IconID><IsExpanded>True</IsExpanded>\
        <DefaultAutoTypeSequence>{USERNAME}</DefaultAutoTypeSequence>\
        <EnableAutoType>null</EnableAutoType>\
        <EnableSearching>False</EnableSearching>\
        <LastTopVisibleEntry>AAAAAAAAAAAAAAAAAAAAAA==</LastTopVisibleEntry>\
        <Tags>team;shared</Tags></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let originalContainer = try XCTUnwrap(parsed.rootGroup.groups.first)
        let originalNested = try XCTUnwrap(originalContainer.groups.first)
        XCTAssertEqual(originalNested.notes, "first line\nsecond line")

        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let xmlString = String(data: try serializer.serialize(), encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("<CustomIconUUID>3q2+7wAAAAAAAAAAAAAAAA==</CustomIconUUID>"))
        XCTAssertTrue(xmlString.contains("<DefaultAutoTypeSequence>{USERNAME}</DefaultAutoTypeSequence>"))
        XCTAssertTrue(xmlString.contains("<EnableAutoType>null</EnableAutoType>"))
        XCTAssertTrue(xmlString.contains("<LastTopVisibleEntry>AAAAAAAAAAAAAAAAAAAAAA==</LastTopVisibleEntry>"))

        let reparsed = try parseXML(Data(xmlString.utf8))
        let container = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let nested = try XCTUnwrap(container.groups.first)
        XCTAssertEqual(nested.notes, originalNested.notes)
        XCTAssertTrue(nested.hasNotesElement)
        XCTAssertEqual(nested.tags, ["team", "shared"])
        XCTAssertEqual(nested.searchingEnabled, .disabled)
        XCTAssertEqual(nested.name, "Nested")
        XCTAssertEqual(
            KDBXTreeAssertions.normalizedOpaqueXML(nested.unknownXML),
            KDBXTreeAssertions.normalizedOpaqueXML(originalNested.unknownXML),
            "Every unknown sibling must keep its exact position across a second parse"
        )
    }

    // MARK: - Header minor version floor

    /// Group `<Tags>` is a KDBX 4.1 element, so authoring one has to raise the
    /// written header's minor version — the policy KeePassXC's
    /// `KeePass2Writer::kdbxVersionRequired` and KeePassium both use. KDBX 3.1
    /// never reaches the writer (`FileVersion.requiresReadOnlyMode` opens those
    /// read-only), so only the 4.x floor matters.
    func test_headerMinorVersion_bumpsTo41WhenAGroupTagIsAuthored() throws {
        let fixture = try parseFixtureWithHeader(.test)
        XCTAssertEqual(
            fixture.header.formatVersion,
            .kdbx4(minor: 0),
            "Precondition: the fixture is a 4.0 database"
        )
        let target = try XCTUnwrap(fixture.rootGroup.groups.first)

        let draft = DatabaseDraft(
            rootGroup: fixture.rootGroup,
            meta: fixture.meta,
            sessionKey: roundTripSessionKey
        )
        let updated = try draft.apply(
            .updateGroup(
                groupID: target.id,
                draft: GroupDraftPayload(name: target.name, tags: ["needs-4-1"], iconID: target.iconID)
            )
        )

        let written = try KDBXWriter.write(
            rootGroup: updated.rootGroup,
            meta: updated.meta,
            compositeKey: fixture.compositeKey,
            header: fixture.header,
            sessionKey: roundTripSessionKey
        )

        XCTAssertEqual(try KDBXParser.parseFileVersion(from: written), .kdbx4(minor: 1))
    }

    func test_headerMinorVersion_staysAt40WhenNoGroupCarriesATag() throws {
        let fixture = try parseFixtureWithHeader(.test)
        let target = try XCTUnwrap(fixture.rootGroup.groups.first)

        let draft = DatabaseDraft(
            rootGroup: fixture.rootGroup,
            meta: fixture.meta,
            sessionKey: roundTripSessionKey
        )
        let updated = try draft.apply(
            .updateGroup(
                groupID: target.id,
                draft: GroupDraftPayload(
                    name: "Renamed Without Tags",
                    notes: "notes are a KDBX 3.1 element and force nothing",
                    iconID: target.iconID
                )
            )
        )

        let written = try KDBXWriter.write(
            rootGroup: updated.rootGroup,
            meta: updated.meta,
            compositeKey: fixture.compositeKey,
            header: fixture.header,
            sessionKey: roundTripSessionKey
        )

        XCTAssertEqual(try KDBXParser.parseFileVersion(from: written), .kdbx4(minor: 0))
    }

    /// The floor is `max(required, existing)`, never a downgrade: KeeForge
    /// preserves opaque 4.1 XML it does not model, so stamping a 4.0 header
    /// onto that payload would misdescribe the file. Stripping every group tag
    /// out of a 4.1 database drops the *required* minor back to 0 and still
    /// must not lower the header.
    func test_headerMinorVersion_neverDowngradesA41FileEvenWithEveryGroupTagRemoved() throws {
        let fixture = try parseFixtureWithHeader(
            name: "group-tags",
            subdirectory: "compatibility",
            password: "testpassword123"
        )
        XCTAssertEqual(
            fixture.header.formatVersion,
            .kdbx4(minor: 1),
            "Precondition: the fixture is a 4.1 database"
        )

        func stripTags(_ group: KPGroup) {
            group.tags = []
            group.hasTagsElement = false
            group.groups.forEach(stripTags)
        }
        func carriesTag(_ group: KPGroup) -> Bool {
            group.hasTagsElement || !group.tags.isEmpty || group.groups.contains(where: carriesTag)
        }
        XCTAssertTrue(carriesTag(fixture.rootGroup), "Precondition: the fixture's groups carry tags")
        stripTags(fixture.rootGroup)
        XCTAssertFalse(carriesTag(fixture.rootGroup), "The content now only requires 4.0")

        let written = try KDBXWriter.write(
            rootGroup: fixture.rootGroup,
            meta: fixture.meta,
            compositeKey: fixture.compositeKey,
            header: fixture.header,
            sessionKey: roundTripSessionKey
        )

        XCTAssertEqual(try KDBXParser.parseFileVersion(from: written), .kdbx4(minor: 1))
    }

    private func parseFixtureWithHeader(
        _ fixture: KDBXTestFixture
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: KDBXParser.Header, compositeKey: SymmetricKey) {
        try parseFixtureWithHeader(
            name: fixture.name,
            subdirectory: fixture.subdirectory,
            password: try XCTUnwrap(fixture.password)
        )
    }

    private func parseFixtureWithHeader(
        name: String,
        subdirectory: String?,
        password: String
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: KDBXParser.Header, compositeKey: SymmetricKey) {
        let bundle = Bundle(for: Self.self)
        let databaseURL = try TestDatabaseSupport.fixtureURL(
            named: name,
            subdirectory: subdirectory,
            bundle: bundle
        )
        let databaseData = try Data(contentsOf: databaseURL)
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: databaseData,
            compositeKey: compositeKey,
            sessionKey: roundTripSessionKey
        )

        return (parsed.rootGroup, parsed.meta, parsed.header, compositeKey)
    }

    /// A nonstandard KDBX 4.0 file containing group tags round-trips them
    /// unchanged — preservation, not validation, is the contract. The XML
    /// layer under test here carries no format version at all, so this
    /// version-agnosticism IS the 4.0-nonstandard-file coverage: the same
    /// `parseXML`/`serialize` pair runs identically whatever minor version
    /// the outer header declared.
    func test_groupTags_versionAgnosticXMLLayer_preservesNonstandardKDBX40GroupTags() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Nonstandard</Name><Tags>from-a-4.0-file</Tags></Group>
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let reparsed = try serializeAndParse(parsed)

        try KDBXTreeAssertions.assertTreesEqual(
            parsed,
            reparsed,
            sessionKey: roundTripSessionKey
        )
        let container = try XCTUnwrap(reparsed.rootGroup.groups.first)
        let nonstandard = try XCTUnwrap(container.groups.first)
        XCTAssertEqual(nonstandard.tags, ["from-a-4.0-file"])
        XCTAssertTrue(nonstandard.hasTagsElement)
    }

    // MARK: - Times/LocationChanged

    func test_locationChanged_parsesForEntriesAndGroupsAndSurvivesRoundTrip() throws {
        let groupMoved = binaryTimestamp(63_800_000_000)
        let entryMoved = binaryTimestamp(63_800_000_123)
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>\
        <Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Nested</Name>\
        <Times><CreationTime>\(binaryTimestamp(63_700_000_000))</CreationTime>\
        <LastModificationTime>\(binaryTimestamp(63_710_000_000))</LastModificationTime>\
        <LocationChanged>\(groupMoved)</LocationChanged></Times>\
        <Entry><UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID>\
        <Times><CreationTime>\(binaryTimestamp(63_700_000_000))</CreationTime>\
        <LastModificationTime>\(binaryTimestamp(63_710_000_000))</LastModificationTime>\
        <LocationChanged>\(entryMoved)</LocationChanged></Times>\
        <String><Key>Title</Key><Value>Moved</Value></String></Entry>\
        </Group></Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let nested = try XCTUnwrap(parsed.rootGroup.groups.first?.groups.first)
        let entry = try XCTUnwrap(nested.entries.first)
        XCTAssertEqual(nested.locationChanged, kpDate(63_800_000_000))
        XCTAssertEqual(entry.locationChanged, kpDate(63_800_000_123))
        XCTAssertFalse(
            nested.unknownXML.nodes.contains { $0.xml.hasPrefix("<LocationChanged>") },
            "A parsed <LocationChanged> is structured, so no opaque copy may remain"
        )
        XCTAssertFalse(entry.unknownXML.nodes.contains { $0.xml.hasPrefix("<LocationChanged>") })

        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let serialized = String(decoding: try serializer.serialize(), as: UTF8.self)
        XCTAssertTrue(serialized.contains("<LocationChanged>\(groupMoved)</LocationChanged>"))
        XCTAssertTrue(serialized.contains("<LocationChanged>\(entryMoved)</LocationChanged>"))

        let reparsed = try parseXML(Data(serialized.utf8))
        try KDBXTreeAssertions.assertTreesEqual(parsed, reparsed, sessionKey: roundTripSessionKey)
    }

    func test_locationChanged_absentElement_isNotAddedOnWrite() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>\
        <Times><CreationTime>\(binaryTimestamp(63_700_000_000))</CreationTime></Times>\
        <Entry><UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID>\
        <Times><CreationTime>\(binaryTimestamp(63_700_000_000))</CreationTime></Times>\
        <String><Key>Title</Key><Value>Stationary</Value></String></Entry>\
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let group = try XCTUnwrap(parsed.rootGroup.groups.first)
        XCTAssertNil(group.locationChanged)
        XCTAssertNil(try XCTUnwrap(group.entries.first).locationChanged)

        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let serialized = String(decoding: try serializer.serialize(), as: UTF8.self)
        XCTAssertFalse(
            serialized.contains("<LocationChanged>"),
            "A file without the element must never gain one on a plain round trip"
        )
    }

    /// `<LocationChanged>` is the last of KeePass's standard `<Times>` children,
    /// so making it structured must leave `<LastAccessTime>`, `<ExpiryTime>`,
    /// `<Expires>`, and `<UsageCount>` — all still opaque — exactly where the
    /// source put them. If the parser's counter arm and the serializer's
    /// emission position disagree, every fragment recorded after
    /// `<LastModificationTime>` slides, and this is the test that sees it.
    func test_locationChanged_keepsTheCanonicalTimesBlockByteIdentical() throws {
        let times = """
        <Times><CreationTime>\(binaryTimestamp(63_700_000_000))</CreationTime>\
        <LastModificationTime>\(binaryTimestamp(63_710_000_000))</LastModificationTime>\
        <LastAccessTime>\(binaryTimestamp(63_720_000_000))</LastAccessTime>\
        <ExpiryTime>\(binaryTimestamp(63_730_000_000))</ExpiryTime>\
        <Expires>True</Expires><UsageCount>7</UsageCount>\
        <LocationChanged>\(binaryTimestamp(63_740_000_000))</LocationChanged></Times>
        """
        let xml = """
        <KeePassFile><Root><Group><UUID>rG5FhCLXQ0GDRLRUEBEHUw==</UUID><Name>Root</Name>\(times)\
        <Entry><UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID>\(times)\
        <String><Key>Title</Key><Value>Canonical</Value></String></Entry>\
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let serialized = String(decoding: try serializer.serialize(), as: UTF8.self)

        XCTAssertEqual(
            serialized.components(separatedBy: times).count - 1,
            2,
            "Both the group's and the entry's <Times> must come back byte-identical:\n\(serialized)"
        )
    }

    func test_locationChanged_unparsableValue_staysOpaqueAndIsWrittenOnce() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>\
        <Times><CreationTime>\(binaryTimestamp(63_700_000_000))</CreationTime>\
        <LocationChanged>not-a-timestamp</LocationChanged></Times>\
        </Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        XCTAssertNil(parsed.rootGroup.locationChanged)

        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        let serialized = String(decoding: try serializer.serialize(), as: UTF8.self)

        XCTAssertEqual(
            serialized.components(separatedBy: "<LocationChanged>").count - 1,
            1,
            "The unparsable element must be replayed verbatim and exactly once"
        )
        XCTAssertTrue(serialized.contains("<LocationChanged>not-a-timestamp</LocationChanged>"))
    }

    func test_locationChanged_onStoredHistoryVersions_roundTrips() throws {
        let xml = """
        <KeePassFile><Root><Group><Name>Root</Name>\
        <Entry><UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID>\
        <Times><LocationChanged>\(binaryTimestamp(63_800_000_000))</LocationChanged></Times>\
        <String><Key>Title</Key><Value>Current</Value></String>\
        <History><Entry><UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID>\
        <Times><LocationChanged>\(binaryTimestamp(63_600_000_000))</LocationChanged></Times>\
        <String><Key>Title</Key><Value>Old</Value></String></Entry></History>\
        </Entry></Group></Root></KeePassFile>
        """

        let parsed = try parseXML(Data(xml.utf8))
        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first)
        XCTAssertEqual(entry.locationChanged, kpDate(63_800_000_000))
        XCTAssertEqual(try XCTUnwrap(entry.history.first).locationChanged, kpDate(63_600_000_000))

        let reparsed = try serializeAndParse(parsed)
        try KDBXTreeAssertions.assertTreesEqual(parsed, reparsed, sessionKey: roundTripSessionKey)
    }

    /// Real files, not synthetic XML: every `<Times>` element KeeForge writes
    /// must carry the same children, in the same order, as the source file did.
    /// Promoting `<LocationChanged>` out of the opaque set is exactly the kind
    /// of change that silently reorders a foreign writer's `<Times>` block.
    func test_locationChanged_realFixtures_preserveEveryTimesChildSequence() throws {
        var sawLocationChanged = false

        for fixture in Self.timesOrderFixtures {
            let sourceXML = String(decoding: try decryptedXML(of: fixture), as: UTF8.self)
            let parsed = try parseFixture(fixture)
            var serializer = KDBXXMLSerializer(
                rootGroup: parsed.rootGroup,
                meta: parsed.meta,
                innerStreamKey: roundTripInnerStreamKey,
                sessionKey: roundTripSessionKey
            )
            let writtenXML = String(decoding: try serializer.serialize(), as: UTF8.self)

            let source = Self.timesChildSequences(in: sourceXML)
            let written = Self.timesChildSequences(in: writtenXML)
            XCTAssertFalse(source.isEmpty, "\(fixture.name): fixture has no <Times> elements to compare")
            XCTAssertEqual(
                written.sorted(),
                source.sorted(),
                "\(fixture.name): <Times> child order changed across a save"
            )
            sawLocationChanged = sawLocationChanged || source.contains { $0.contains("LocationChanged") }
        }

        XCTAssertTrue(sawLocationChanged, "None of the fixtures exercises <LocationChanged>")
    }

    /// The serializer is a fixed point on every real fixture: parse → write →
    /// parse → write reproduces the first output byte for byte. Anything that
    /// shifts an opaque insertion index by one shows up here as a diff.
    func test_realFixtures_serializedXMLIsAByteStableFixedPoint() throws {
        for fixture in Self.timesOrderFixtures {
            let first = try serializedXML(of: try parseFixture(fixture))
            let second = try serializedXML(of: try parseXML(first))
            XCTAssertEqual(first, second, "\(fixture.name): a second save changed the bytes")
        }
    }

    /// KDBX4 fixtures that carry a full `<Times>` block, spanning the writers
    /// the app has to interoperate with. `argon2-high-iterations` is left out
    /// on purpose (its KDF is deliberately expensive) and so is
    /// `legacy-kdbx31` (3.1 never reaches the writer).
    private static let timesOrderFixtures: [KDBXTestFixture] = [
        .test,
        .demo,
        .demoKeyfile,
        .unknownElements,
        .unknownInnerHeader,
        KDBXTestFixture(
            name: "aes-baseline",
            subdirectory: "compatibility",
            password: "testpassword123",
            keyFileName: nil,
            keyFileExtension: nil
        ),
        KDBXTestFixture(
            name: "unknown-rich",
            subdirectory: "compatibility",
            password: "test-round-trip",
            keyFileName: nil,
            keyFileExtension: nil
        ),
        KDBXTestFixture(
            name: "kdbx41-public-custom-data",
            subdirectory: "compatibility",
            password: "testpassword123",
            keyFileName: nil,
            keyFileExtension: nil
        ),
        KDBXTestFixture(
            name: "group-tags",
            subdirectory: "compatibility",
            password: "testpassword123",
            keyFileName: nil,
            keyFileExtension: nil
        ),
        KDBXTestFixture(
            name: "attachments",
            subdirectory: "compatibility",
            password: "testpassword123",
            keyFileName: nil,
            keyFileExtension: nil
        ),
        KDBXTestFixture(
            name: "foreign-chacha20",
            subdirectory: "compatibility",
            password: "foreign-chacha20",
            keyFileName: nil,
            keyFileExtension: nil
        ),
        KDBXTestFixture(
            name: "foreign-twofish",
            subdirectory: "compatibility",
            password: "foreign-twofish",
            keyFileName: nil,
            keyFileExtension: nil
        ),
    ]

    /// Child element names of every `<Times>` element, in document order within
    /// each block. The blocks themselves are compared as a multiset, because a
    /// rewrite is entitled to move a whole entry or group to its canonical
    /// position; what it may never do is reorder the children inside one block.
    private static func timesChildSequences(in xml: String) -> [String] {
        xml.components(separatedBy: "<Times>")
            .dropFirst()
            .compactMap { tail in
                guard let end = tail.range(of: "</Times>") else { return nil }
                let names = childElementNames(in: String(tail[tail.startIndex..<end.lowerBound]))
                return canonicallyOrdered(names).joined(separator: ",")
            }
    }

    /// Moves the two long-standing structured children to the front, in
    /// KeePass's order.
    ///
    /// A writer is free to emit them the other way round — pykeepass writes the
    /// root group's `<LastModificationTime>` first — and KeeForge has always
    /// normalized that, from before `<LocationChanged>` was modelled. Folding
    /// that known normalization out is what leaves this comparison testing the
    /// property at issue: where `<LocationChanged>` sits relative to the
    /// `<Times>` children that are still opaque.
    private static func canonicallyOrdered(_ names: [String]) -> [String] {
        let leading = ["CreationTime", "LastModificationTime"]
        return leading.filter(names.contains) + names.filter { !leading.contains($0) }
    }

    private static func childElementNames(in xml: String) -> [String] {
        var names: [String] = []
        var remainder = Substring(xml)
        while let open = remainder.firstIndex(of: "<") {
            remainder = remainder[remainder.index(after: open)...]
            guard remainder.first?.isLetter == true else { continue }
            let name = remainder.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            names.append(String(name))
            remainder = remainder.dropFirst(name.count)
        }
        return names
    }

    private func serializedXML(of parsed: (rootGroup: KPGroup, meta: KPMeta)) throws -> Data {
        var serializer = KDBXXMLSerializer(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            innerStreamKey: roundTripInnerStreamKey,
            sessionKey: roundTripSessionKey
        )
        return try serializer.serialize()
    }

    /// The fixture's own inner XML payload, so a test can compare KeeForge's
    /// output against the bytes the authoring app actually wrote.
    private func decryptedXML(of fixture: KDBXTestFixture) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let databaseData = try Data(
            contentsOf: try TestDatabaseSupport.fixtureURL(
                named: fixture.name,
                subdirectory: fixture.subdirectory,
                bundle: bundle
            )
        )

        let keyFileData: Data?
        if let keyFileName = fixture.keyFileName, let keyFileExtension = fixture.keyFileExtension {
            keyFileData = try Data(
                contentsOf: try TestDatabaseSupport.fixtureURL(
                    named: keyFileName,
                    extension: keyFileExtension,
                    bundle: bundle
                )
            )
        } else {
            keyFileData = nil
        }
        let compositeKey = try KDBXCrypto.compositeKey(password: fixture.password, keyFileData: keyFileData)

        var reader = DataReader(data: databaseData)
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()
        let header = try KDBXParser.parseHeader(&reader)
        _ = try reader.readBytes(32)
        _ = try reader.readBytes(32)

        let transformedKey = try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: header.kdfParameters)
        let masterKey = KDBXCrypto.sha256(header.masterSeed + transformedKey)
        let hmacBaseKey = KDBXCrypto.sha512(header.masterSeed + transformedKey + Data([0x01]))

        let encryptedPayload = try KDBXParser.readHMACBlocks(reader: &reader, baseKey: hmacBaseKey)
        let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)
        let decrypted = try cipher.decrypt(
            data: encryptedPayload,
            key: masterKey,
            iv: header.encryptionIV
        )

        let payload = header.compressionFlags == 1 ? try KDBXCrypto.gunzip(decrypted) : decrypted
        var innerReader = DataReader(data: payload)
        _ = try KDBXParser.parseInnerHeader(&innerReader)
        return payload.subdata(in: innerReader.offset..<payload.count)
    }

    private func kpDate(_ secondsSinceKeePassEpoch: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: -63_113_904_000 + TimeInterval(secondsSinceKeePassEpoch))
    }
}
