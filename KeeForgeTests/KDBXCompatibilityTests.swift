import CryptoKit
import XCTest
@testable import KeeForge

final class KDBXCompatibilityTests: XCTestCase {
    private var bundle: Bundle {
        Bundle(for: Self.self)
    }

    func test_allSupportedEditScenarios_writeReparseAndOnlyChangeExpectedSemantics() throws {
        let loaded = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: bundle)

        for scenario in KDBXCompatibilitySupport.fullEditScenarios() {
            _ = try scenario.apply(to: loaded)
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
}
