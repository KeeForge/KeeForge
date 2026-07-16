import CryptoKit
import XCTest
@testable import KeeForge

final class KDBXCompatibilityTests: XCTestCase {
    private enum KeeOTPMutation: String, CaseIterable {
        case preserve
        case period
        case secret
    }

    private var bundle: Bundle {
        Bundle(for: Self.self)
    }

    func test_allSupportedEditScenarios_writeReparseAndOnlyChangeExpectedSemantics() throws {
        for fixture in [
            KDBXCompatibilitySupport.Fixture.syntheticRich,
            .syntheticTwofish,
        ] {
            let loaded = try KDBXCompatibilitySupport.load(fixture, bundle: bundle)

            for scenario in KDBXCompatibilitySupport.fullEditScenarios() {
                let result = try scenario.apply(to: loaded)
                let reparsed = try KDBXParser.parseWithMetaAndHeader(
                    data: result.written,
                    compositeKey: loaded.compositeKey,
                    sessionKey: loaded.sessionKey
                )
                XCTAssertEqual(reparsed.header.cipherID, loaded.header.cipherID)
                XCTAssertEqual(reparsed.header.kdfParameters["$UUID"] as? Data, loaded.header.kdfParameters["$UUID"] as? Data)
            }
        }
    }

    func test_softDeleteCreatesRecycleBinWithoutChangingOtherSemantics() throws {
        let loaded = try KDBXCompatibilitySupport.load(.syntheticNoRecycleBin, bundle: bundle)

        _ = try KDBXCompatibilitySupport.recycleBinCreationScenario().apply(to: loaded)
    }

    func test_representativeCompatibilityFixtures_writeReparseAndPreserveFixtureShapes() throws {
        let fixtures: [KDBXCompatibilitySupport.Fixture] = [
            .aesBaseline,
            .passwordKeyfile,
            .unknownRich,
            .kdbx41PublicCustomData,
            .syntheticChaCha,
            .syntheticTwofish,
        ]

        for fixture in fixtures {
            let loaded = try KDBXCompatibilitySupport.load(fixture, bundle: bundle)
            let scenario = KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: fixture.id)
            let result = try scenario.apply(to: loaded)

            XCTAssertFalse(result.written.isEmpty, "\(fixture.displayName) should produce encrypted output")
            XCTAssertEqual(result.after.entries.count, result.before.entries.count + 1)
        }
    }

    func test_unknownXMLFixture_preservesAttachmentReferencesAndCustomDataOnWrite() throws {
        let loaded = try KDBXCompatibilitySupport.load(.unknownRich, bundle: bundle)
        let scenario = KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: loaded.fixture.id)
        let result = try scenario.apply(to: loaded)

        // `<Binary>` attachment refs are now parsed structurally into
        // `KPEntry.attachments` instead of falling into unknownXML.
        let beforeAttachments = result.before.entries.values.flatMap(\.attachments)
        let afterAttachments = result.after.entries.values.flatMap(\.attachments)
        XCTAssertTrue(beforeAttachments.contains { $0.name == "round-trip.txt" && $0.ref == 0 })
        XCTAssertTrue(afterAttachments.contains { $0.name == "round-trip.txt" && $0.ref == 0 })

        let beforeHistoryAttachments = result.before.entries.values.flatMap(\.history).flatMap(\.attachments)
        let afterHistoryAttachments = result.after.entries.values.flatMap(\.history).flatMap(\.attachments)
        XCTAssertTrue(beforeHistoryAttachments.contains { $0.name == "round-trip.txt" && $0.ref == 0 })
        XCTAssertTrue(afterHistoryAttachments.contains { $0.name == "round-trip.txt" && $0.ref == 0 })

        let beforeUnknownXML = result.before.entries.values.map(\.unknownXML.nodes).flatMap { $0 }.map(\.xml).joined()
        let afterUnknownXML = result.after.entries.values.map(\.unknownXML.nodes).flatMap { $0 }.map(\.xml).joined()
        let beforeMetaUnknownXML = result.before.meta.unknownXML.nodes.map(\.xml).joined()
        let afterMetaUnknownXML = result.after.meta.unknownXML.nodes.map(\.xml).joined()

        XCTAssertFalse(beforeUnknownXML.contains("round-trip.txt"))
        XCTAssertFalse(afterUnknownXML.contains("round-trip.txt"))
        XCTAssertTrue(beforeUnknownXML.contains("RoundTripEntryValue-Expected"))
        XCTAssertTrue(afterUnknownXML.contains("RoundTripEntryValue-Expected"))
        XCTAssertTrue(beforeMetaUnknownXML.contains("RoundTripMetaValue-Expected"))
        XCTAssertTrue(afterMetaUnknownXML.contains("RoundTripMetaValue-Expected"))
    }

    func test_kdbx41Fixture_capturesAndPreservesUnknownOuterHeaderFields() throws {
        let loaded = try KDBXCompatibilitySupport.load(.kdbx41PublicCustomData, bundle: bundle)

        XCTAssertEqual(loaded.header.formatVersion, .kdbx4(minor: 1))
        let publicCustomData = try XCTUnwrap(
            loaded.header.unknownOuterHeaderFields.first { $0.id == 12 }
        )
        XCTAssertNotNil(publicCustomData.data.range(of: Data("KeeForgeFixture".utf8)))
        XCTAssertNotNil(publicCustomData.data.range(of: Data("KDBX 4.1 public custom data".utf8)))

        let scenario = KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: loaded.fixture.id)
        let result = try scenario.apply(to: loaded)
        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: result.written,
            compositeKey: loaded.compositeKey,
            sessionKey: loaded.sessionKey
        )

        XCTAssertEqual(reparsed.header.formatVersion, .kdbx4(minor: 1))
        XCTAssertEqual(reparsed.header.unknownOuterHeaderFields, loaded.header.unknownOuterHeaderFields)
    }

    func test_legacyKDBX31CompatibilityFixture_isReadOnlyAndWriterRejects() throws {
        try KDBXCompatibilitySupport.assertLegacyFixtureIsReadOnly(bundle: bundle)
    }

    func test_attachmentsFixture_preservesAttachmentsAndPoolContentHashesAcrossScenarios() throws {
        // fixtureSmoke: creating an unrelated entry should not disturb any
        // existing entry's attachments or their resolved pool bytes.
        let smokeLoaded = try KDBXCompatibilitySupport.load(.attachments, bundle: bundle)
        let smokeResult = try KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: KDBXCompatibilitySupport.Fixture.attachments.id)
            .apply(to: smokeLoaded)

        let multiEntryID = try XCTUnwrap(smokeResult.before.entryID(titled: "Multi Attachment Entry"))
        let multiBefore = try XCTUnwrap(smokeResult.before.entries[multiEntryID])
        let multiAfter = try XCTUnwrap(smokeResult.after.entries[multiEntryID])
        XCTAssertEqual(multiBefore.attachments, multiAfter.attachments)
        XCTAssertEqual(Set(multiBefore.attachments.map(\.name)), ["note-ü.txt", "pixel.png"])
        XCTAssertEqual(
            Set(multiBefore.attachmentHashes.compactMap { $0 }),
            [KDBXCompatibilitySupport.AttachmentFixtureHashes.noteUnicodeTxt, KDBXCompatibilitySupport.AttachmentFixtureHashes.pixelPNG]
        )
        XCTAssertEqual(multiBefore.attachmentHashes, multiAfter.attachmentHashes)

        let dedupAEntryID = try XCTUnwrap(smokeResult.before.entryID(titled: "Dedup Entry A"))
        let dedupBEntryID = try XCTUnwrap(smokeResult.before.entryID(titled: "Dedup Entry B"))
        let dedupABefore = try XCTUnwrap(smokeResult.before.entries[dedupAEntryID])
        let dedupBBefore = try XCTUnwrap(smokeResult.before.entries[dedupBEntryID])
        // Both dedup entries reference bytes with the same hash, whether or
        // not the underlying pool physically deduplicates the storage.
        XCTAssertEqual(dedupABefore.attachmentHashes, [KDBXCompatibilitySupport.AttachmentFixtureHashes.sharedBin])
        XCTAssertEqual(dedupBBefore.attachmentHashes, [KDBXCompatibilitySupport.AttachmentFixtureHashes.sharedBin])

        let noAttachmentEntryID = try XCTUnwrap(smokeResult.before.entryID(titled: "No Attachment Entry"))
        XCTAssertEqual(smokeResult.before.entries[noAttachmentEntryID]?.attachments, [])

        // updateEntry: editing non-attachment fields preserves attachments.
        let updateLoaded = try KDBXCompatibilitySupport.load(.attachments, bundle: bundle)
        _ = try KDBXCompatibilitySupport.attachmentsFixtureUpdateEntryScenario().apply(to: updateLoaded)

        // softDelete: recycling one dedup entry doesn't disturb its sibling.
        let softDeleteLoaded = try KDBXCompatibilitySupport.load(.attachments, bundle: bundle)
        _ = try KDBXCompatibilitySupport.attachmentsFixtureSoftDeleteScenario().apply(to: softDeleteLoaded)
    }

    @MainActor
    func test_keeOTPCompatibilityMatrix_preservesAndIntentionallyMutatesSources() throws {
        for testCase in KDBXCompatibilitySupport.keeOTPCases {
            for mutation in KeeOTPMutation.allCases {
                let reloaded = try editSaveReloadKeeOTP(testCase, mutation: mutation)
                let config = try XCTUnwrap(reloaded.totpConfig, "\(testCase.fieldName) \(testCase.encoding) \(mutation.rawValue)")
                let source = try XCTUnwrap(config.keeOTPSource)

                XCTAssertEqual(source.fieldName, testCase.fieldName)
                XCTAssertFalse(reloaded.customFields.keys.contains { $0.hasPrefix("TimeOtp-") })
                XCTAssertNil(reloaded.customFields["OTP"])
                XCTAssertNil(reloaded.customFields["Otp"])

                switch mutation {
                case .preserve:
                    XCTAssertEqual(source.rawQuery, testCase.rawQuery)
                    XCTAssertEqual(config.period, 30)
                    XCTAssertEqual(resolvedSecret(config), testCase.decodedSecret)
                case .period:
                    XCTAssertTrue(source.rawQuery.contains("step=45"))
                    XCTAssertTrue(source.rawQuery.contains("Encoding=\(testCase.encoding)"))
                    XCTAssertTrue(source.rawQuery.contains("vendor=keep%2Bme"))
                    XCTAssertEqual(config.period, 45)
                    XCTAssertEqual(resolvedSecret(config), testCase.decodedSecret)
                case .secret:
                    XCTAssertTrue(source.rawQuery.contains("key=JBSWY3DP"))
                    XCTAssertTrue(source.rawQuery.contains("Encoding=Base32"))
                    XCTAssertTrue(source.rawQuery.contains("vendor=keep%2Bme"))
                    XCTAssertEqual(resolvedSecret(config), Data("Hello".utf8))
                }
            }
        }
    }

    @MainActor
    func test_keeOTPRemovalAndMalformedReplacementRemainSafe() throws {
        let testCase = try XCTUnwrap(KDBXCompatibilitySupport.keeOTPCases.first { $0.fieldName == "OTP" && $0.encoding == "Base64" })
        let entry = try makeKeeOTPEntry(testCase)
        let root = KPGroup(name: "Root", entries: [entry])
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: entrySessionKey)
        viewModel.totpSecret = "not base32!"

        var updated = try DatabaseDraft(rootGroup: root, meta: KPMeta(), sessionKey: entrySessionKey)
            .apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        var reloaded = try writeAndReload(updated)
        XCTAssertEqual(reloaded.totpConfig?.keeOTPSource?.rawQuery, testCase.rawQuery)
        XCTAssertEqual(reloaded.totpConfig?.period, 30)
        XCTAssertEqual(reloaded.totpConfig.flatMap(resolvedSecret), testCase.decodedSecret)

        let removalViewModel = EntryEditViewModel(editing: reloaded, sessionKey: entrySessionKey)
        removalViewModel.totpSecret = ""
        updated = try DatabaseDraft(rootGroup: KPGroup(name: "Root", entries: [reloaded]), meta: KPMeta(), sessionKey: entrySessionKey)
            .apply(.updateEntry(entryID: reloaded.id, draft: removalViewModel.entryDraftPayload))
        reloaded = try writeAndReload(updated)
        XCTAssertNil(reloaded.totpConfig)
        XCTAssertNil(reloaded.otpURL)
        XCTAssertFalse(reloaded.customFields.keys.contains { $0.hasPrefix("TimeOtp-") || $0 == "OTP" || $0 == "Otp" })
    }

    private let entrySessionKey = SymmetricKey(size: .bits256)

    @MainActor
    private func editSaveReloadKeeOTP(
        _ testCase: KDBXCompatibilitySupport.KeeOTPCase,
        mutation: KeeOTPMutation
    ) throws -> KPEntry {
        let entry = try makeKeeOTPEntry(testCase)
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: entrySessionKey)
        switch mutation.rawValue {
        case "period": viewModel.totpPeriod = 45
        case "secret": viewModel.totpSecret = "JBSWY3DP"
        default: viewModel.notes = "Unrelated edit"
        }
        let updated = try DatabaseDraft(
            rootGroup: KPGroup(name: "Root", entries: [entry]),
            meta: KPMeta(),
            sessionKey: entrySessionKey
        ).apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        return try writeAndReload(updated)
    }

    private func makeKeeOTPEntry(_ testCase: KDBXCompatibilitySupport.KeeOTPCase) throws -> KPEntry {
        let source = KeeOTPSource(fieldName: testCase.fieldName, rawQuery: testCase.rawQuery)
        return KPEntry(
            title: "KeeOTP \(testCase.fieldName) \(testCase.encoding)",
            password: try EncryptedValue.encrypt("password", using: entrySessionKey),
            customFields: testCase.fieldName == "otp" ? [:] : [testCase.fieldName: testCase.rawQuery],
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt(testCase.secret, using: entrySessionKey),
                decodedSecret: try EncryptedValue.encrypt(testCase.decodedSecret, using: entrySessionKey),
                keeOTPSource: source
            ),
            otpURL: testCase.fieldName == "otp" ? testCase.rawQuery : nil
        )
    }

    private func writeAndReload(_ draft: DatabaseDraft) throws -> KPEntry {
        let loaded = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: bundle, sessionKey: entrySessionKey)
        let data = try KDBXWriter.write(
            rootGroup: draft.rootGroup,
            meta: draft.meta,
            compositeKey: loaded.compositeKey,
            header: loaded.header,
            sessionKey: draft.writerSessionKey
        )
        let reparsed = try KDBXParser.parse(data: data, compositeKey: loaded.compositeKey, sessionKey: entrySessionKey)
        return try XCTUnwrap(reparsed.allEntries.first)
    }

    private func resolvedSecret(_ config: TOTPConfig) -> Data? {
        TOTPGenerator.resolveSecret(config: config, sessionKey: entrySessionKey)?.data
    }
}
