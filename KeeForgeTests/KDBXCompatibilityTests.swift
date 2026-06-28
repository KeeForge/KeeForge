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

        let beforeUnknownXML = result.before.entries.values.map(\.unknownXML.nodes).flatMap { $0 }.map(\.xml).joined()
        let afterUnknownXML = result.after.entries.values.map(\.unknownXML.nodes).flatMap { $0 }.map(\.xml).joined()
        let beforeMetaUnknownXML = result.before.meta.unknownXML.nodes.map(\.xml).joined()
        let afterMetaUnknownXML = result.after.meta.unknownXML.nodes.map(\.xml).joined()

        XCTAssertTrue(beforeUnknownXML.contains("round-trip.txt"))
        XCTAssertTrue(afterUnknownXML.contains("round-trip.txt"))
        XCTAssertTrue(beforeUnknownXML.contains("RoundTripEntryValue-Expected"))
        XCTAssertTrue(afterUnknownXML.contains("RoundTripEntryValue-Expected"))
        XCTAssertTrue(beforeMetaUnknownXML.contains("RoundTripMetaValue-Expected"))
        XCTAssertTrue(afterMetaUnknownXML.contains("RoundTripMetaValue-Expected"))
    }

    func test_legacyKDBX31CompatibilityFixture_isReadOnlyAndWriterRejects() throws {
        try KDBXCompatibilitySupport.assertLegacyFixtureIsReadOnly(bundle: bundle)
    }
}
