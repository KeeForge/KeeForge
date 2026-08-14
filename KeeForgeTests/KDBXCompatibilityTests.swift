import CryptoKit
import XCTest
@testable import KeeForge

/// The authoritative KDBX edit-semantics matrix.
///
/// Every scenario in `KDBXCompatibilitySupport.artifactDescriptors` is executed
/// by exactly one method here, and the method emits that scenario's written
/// bytes as XCTAttachments for `ci_scripts/run_kdbx_compatibility_gate.sh`.
/// Artifact emission piggybacks on the run that already happened; nothing is
/// re-executed to produce a file. Adding a scenario means adding it to
/// `artifactDescriptors`, running it here through an `ArtifactCollector`, and
/// listing its external expectations (or explicitly listing it as having
/// none) — `test_externalExpectationTables_...` fails otherwise.
final class KDBXCompatibilityTests: XCTestCase {
    private enum KeeOTPMutation: String, CaseIterable {
        case preserve
        case period
        case secret
    }

    /// Smoke fixtures whose scenario is run (and emitted) by a dedicated
    /// deeper test below, so the generic smoke sweep skips them and no
    /// scenario executes twice per suite run.
    private static let smokeFixtureIDsWithDedicatedTests: Set<String> = [
        KDBXCompatibilitySupport.Fixture.unknownRich.id,
        KDBXCompatibilitySupport.Fixture.kdbx41PublicCustomData.id,
        KDBXCompatibilitySupport.Fixture.groupTags.id,
        KDBXCompatibilitySupport.Fixture.unknownInnerHeader.id,
    ]

    private var bundle: Bundle {
        Bundle(for: Self.self)
    }

    func test_allSupportedEditScenarios_writeReparseAndOnlyChangeExpectedSemantics() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)

        // Only the AES rich pass produces artifacts. The Twofish pass re-proves
        // the same edit semantics on a second cipher in-process; its external
        // opener coverage comes from `fixture-smoke-synthetic-twofish`, which
        // avoids doubling every KeePassXC check for no extra signal.
        let rich = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: bundle)
        XCTAssertEqual(
            rich.header.formatVersion,
            .kdbx4(minor: 0),
            "Fixture precondition: KeeForge authors 4.0 until content requires 4.1"
        )
        var writtenVersions: [String: KDBXParser.FileVersion] = [:]
        for scenario in KDBXCompatibilitySupport.fullEditScenarios() {
            let result = try collector.run(scenario, on: rich)
            assertHeaderPreserved(result, loaded: rich, scenario: scenario)
            writtenVersions[scenario.id] = result.afterHeader.formatVersion
        }

        // Group `<Tags>` is a KDBX 4.1 element, so authoring one on this 4.0
        // fixture must bump the written header — and nothing else may. The
        // matching artifact is opened by real KeePassXC in the external gate,
        // which is where "the bumped file is still readable elsewhere" is
        // proven; group tags themselves have no keepassxc-cli verb.
        XCTAssertEqual(writtenVersions["update-group"], .kdbx4(minor: 1))
        for (scenarioID, version) in writtenVersions where scenarioID != "update-group" {
            XCTAssertEqual(
                version,
                .kdbx4(minor: 0),
                "\(scenarioID) must not renegotiate the source's header version"
            )
        }

        let twofish = try KDBXCompatibilitySupport.load(.syntheticTwofish, bundle: bundle)
        for scenario in KDBXCompatibilitySupport.fullEditScenarios() {
            let result = try scenario.apply(to: twofish)
            assertHeaderPreserved(result, loaded: twofish, scenario: scenario)
        }

        try collector.emit()
    }

    func test_softDeleteCreatesRecycleBinWithoutChangingOtherSemantics() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)
        let loaded = try KDBXCompatibilitySupport.load(.syntheticNoRecycleBin, bundle: bundle)

        try collector.run(KDBXCompatibilitySupport.recycleBinCreationScenario(), on: loaded)

        try collector.emit()
    }

    func test_representativeCompatibilityFixtures_writeReparseAndPreserveFixtureShapes() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)

        for fixture in KDBXCompatibilitySupport.smokeFixtures
        where !Self.smokeFixtureIDsWithDedicatedTests.contains(fixture.id) {
            let loaded = try KDBXCompatibilitySupport.load(fixture, bundle: bundle)
            let scenario = KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: fixture.id)
            let result = try collector.run(scenario, on: loaded)

            assertSmokeShape(result, fixture: fixture)
        }

        try collector.emit()
    }

    func test_unknownXMLFixture_preservesAttachmentReferencesAndCustomDataOnWrite() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)
        let loaded = try KDBXCompatibilitySupport.load(.unknownRich, bundle: bundle)
        let scenario = KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: loaded.fixture.id)
        let result = try collector.run(scenario, on: loaded)

        assertSmokeShape(result, fixture: loaded.fixture)

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

        try collector.emit()
    }

    func test_metaWithoutRecycleBinUUID_doesNotDuplicateOpaqueMetaChildrenAcrossSaves() throws {
        // Regression: serializeMeta emitted the index-0 opaque fragments
        // unconditionally, then re-emitted them at the next emission site
        // whenever RecycleBinUUID was absent (knownChildCount never advanced
        // past 0). Every save doubled the pre-RecycleBinUUID Meta children.
        let loaded = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: bundle, sessionKey: entrySessionKey)

        var unknownXML = OpaqueXMLNodes()
        // Opaque Meta children recorded before the first modeled element all
        // sit at insertionIndex 0 (see KDBXParser.recordOpaqueXML, "Meta").
        unknownXML.append(xml: "<Generator>KeeForge-Sweep</Generator>", insertionIndex: 0)
        unknownXML.append(xml: "<DatabaseName>Sweep Meta Fixture</DatabaseName>", insertionIndex: 0)
        unknownXML.append(
            xml: "<CustomData><Item><Key>SweepMetaKey</Key><Value>SweepMetaValue</Value></Item></CustomData>",
            insertionIndex: 0
        )

        // Omit RecycleBinUUID but keep a modeled element (MaintenanceHistoryDays)
        // so the mid-list emission site is exercised, not only trailingOpaqueXML.
        let meta = KPMeta(
            recycleBinUUID: nil,
            hasRecycleBinUUIDElement: false,
            maintenanceHistoryDays: KPMeta.defaultMaintenanceHistoryDays,
            unknownXML: unknownXML
        )

        func writeAndReparseMeta(_ meta: KPMeta) throws -> KPMeta {
            let data = try KDBXWriter.write(
                rootGroup: loaded.rootGroup,
                meta: meta,
                compositeKey: loaded.compositeKey,
                header: loaded.header,
                sessionKey: entrySessionKey
            )
            return try KDBXParser.parseWithMeta(
                data: data,
                compositeKey: loaded.compositeKey,
                sessionKey: entrySessionKey
            ).meta
        }

        func assertNoDuplication(_ reparsed: KPMeta, _ label: String) {
            XCTAssertNil(reparsed.recycleBinUUID, label)
            XCTAssertFalse(reparsed.hasRecycleBinUUIDElement, label)
            XCTAssertEqual(reparsed.maintenanceHistoryDays, KPMeta.defaultMaintenanceHistoryDays, label)
            for marker in ["<Generator>", "<DatabaseName>", "<CustomData>", "SweepMetaValue"] {
                let count = reparsed.unknownXML.nodes.filter { $0.xml.contains(marker) }.count
                XCTAssertEqual(count, 1, "\(label): opaque Meta child \(marker) duplicated")
            }
            // Every fragment survives at its original position; none dropped.
            XCTAssertEqual(reparsed.unknownXML.nodes.count, 3, label)
            XCTAssertTrue(reparsed.unknownXML.nodes.allSatisfy { $0.insertionIndex == 0 }, label)
        }

        let firstSave = try writeAndReparseMeta(meta)
        assertNoDuplication(firstSave, "first save")

        // A second save of the already-reparsed Meta must remain stable — the
        // pre-fix bug compounded the duplication on every save.
        let secondSave = try writeAndReparseMeta(firstSave)
        assertNoDuplication(secondSave, "second save")

        XCTAssertEqual(firstSave.unknownXML.nodes, secondSave.unknownXML.nodes)
    }

    func test_kdbx41Fixture_capturesAndPreservesUnknownOuterHeaderFields() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)
        let loaded = try KDBXCompatibilitySupport.load(.kdbx41PublicCustomData, bundle: bundle)

        XCTAssertEqual(loaded.header.formatVersion, .kdbx4(minor: 1))
        let publicCustomData = try XCTUnwrap(
            loaded.header.unknownOuterHeaderFields.first { $0.id == 12 }
        )
        XCTAssertNotNil(publicCustomData.data.range(of: Data("KeeForgeFixture".utf8)))
        XCTAssertNotNil(publicCustomData.data.range(of: Data("KDBX 4.1 public custom data".utf8)))

        let scenario = KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: loaded.fixture.id)
        let result = try collector.run(scenario, on: loaded)

        assertSmokeShape(result, fixture: loaded.fixture)
        XCTAssertEqual(result.afterHeader.formatVersion, .kdbx4(minor: 1))
        XCTAssertEqual(result.afterHeader.unknownOuterHeaderFields, loaded.header.unknownOuterHeaderFields)

        try collector.emit()
    }

    /// `unknown-inner-header.kdbx` carries three inner-header fields KDBX4
    /// does not define, one of them spliced between the two binary-pool
    /// entries. A KeeForge save must carry all three through byte-exact,
    /// normalized to before the pool, while the pool itself and the entry's
    /// attachments stay intact.
    func test_unknownInnerHeaderFixture_capturesAndPreservesUnknownInnerHeaderFields() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)
        let loaded = try KDBXCompatibilitySupport.load(.unknownInnerHeader, bundle: bundle)

        XCTAssertEqual(
            loaded.header.unknownInnerHeaderFields,
            [
                KDBXParser.UnknownHeaderField(id: 0x21, data: Data("mid-pool-unknown-field".utf8)),
                KDBXParser.UnknownHeaderField(
                    id: 0x7F,
                    data: Data("kdbx-format-hardening-fixture:unknown-field-0x7f-marker".utf8)
                ),
                KDBXParser.UnknownHeaderField(id: 0x10, data: Data()),
            ],
            "Fixture precondition: the parser must retain all three unknown fields in on-disk order"
        )
        XCTAssertEqual(loaded.header.innerHeaderBinaryFields.count, 2)

        let scenario = KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: loaded.fixture.id)
        let result = try collector.run(scenario, on: loaded)

        assertSmokeShape(result, fixture: loaded.fixture)
        XCTAssertEqual(result.afterHeader.unknownInnerHeaderFields, loaded.header.unknownInnerHeaderFields)
        XCTAssertEqual(result.afterHeader.innerHeaderBinaryFields, loaded.header.innerHeaderBinaryFields)

        let entryID = try XCTUnwrap(result.before.entryID(titled: "Inner Header Entry"))
        let before = try XCTUnwrap(result.before.entries[entryID])
        let after = try XCTUnwrap(result.after.entries[entryID])
        XCTAssertEqual(before.attachments.map(\.name).sorted(), ["alpha-attachment.txt", "beta-attachment.txt"])
        XCTAssertEqual(after.attachments, before.attachments)
        XCTAssertEqual(after.attachmentHashes, before.attachmentHashes)
        XCTAssertEqual(after.password, "UnknownHeaderSecret1")

        try collector.emit()
    }

    func test_legacyKDBX31CompatibilityFixture_isReadOnlyAndWriterRejects() throws {
        try KDBXCompatibilitySupport.assertLegacyFixtureIsReadOnly(bundle: bundle)
    }

    /// The three master-key-change scenarios: change the password, add a key
    /// file, and remove a key file. `Scenario.apply` already pins that the old
    /// composite key fails the header HMAC and that the tree survives
    /// unchanged; this method adds the header hygiene — cipher, KDF identity,
    /// and cost parameters preserved, master seed and KDF salt rotated.
    func test_rekeyScenarios_reEncryptUnderNewKeyAndPreserveHeaderIdentity() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)

        let passwordOnly = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: bundle)
        let passwordOnlyResult = try collector.run(
            KDBXCompatibilitySupport.rekeyPasswordOnlyScenario(),
            on: passwordOnly
        )
        try assertRekeyHeaderHygiene(passwordOnlyResult, loaded: passwordOnly)
        XCTAssertNil(passwordOnlyResult.rekey?.keyFileData)

        let addKeyfile = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: bundle)
        let addKeyfileResult = try collector.run(
            KDBXCompatibilitySupport.rekeyAddKeyfileScenario(),
            on: addKeyfile
        )
        try assertRekeyHeaderHygiene(addKeyfileResult, loaded: addKeyfile)
        XCTAssertNotNil(
            addKeyfileResult.rekey?.keyFileData,
            "The add-keyfile scenario must record key-file bytes for the external gate"
        )

        let removeKeyfile = try KDBXCompatibilitySupport.load(.passwordKeyfile, bundle: bundle)
        let removeKeyfileResult = try collector.run(
            KDBXCompatibilitySupport.rekeyRemoveKeyfileScenario(),
            on: removeKeyfile
        )
        try assertRekeyHeaderHygiene(removeKeyfileResult, loaded: removeKeyfile)
        XCTAssertNil(
            removeKeyfileResult.rekey?.keyFileData,
            "The remove-keyfile scenario's manifest entry must carry no key file"
        )

        try collector.emit()
    }

    /// Rekey reuses the source header, so identity and cost settings carry
    /// over while every per-write random value must rotate.
    private func assertRekeyHeaderHygiene(
        _ result: KDBXCompatibilitySupport.ScenarioResult,
        loaded: KDBXCompatibilitySupport.LoadedFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let label = "\(loaded.fixture.id)/rekey"
        let rekey = try XCTUnwrap(result.rekey, label, file: file, line: line)
        XCTAssertNotEqual(rekey.compositeKey, loaded.compositeKey, label, file: file, line: line)

        XCTAssertEqual(result.afterHeader.cipherID, loaded.header.cipherID, label, file: file, line: line)
        XCTAssertEqual(result.afterHeader.formatVersion, loaded.header.formatVersion, label, file: file, line: line)
        XCTAssertEqual(
            result.afterHeader.kdfParameters["$UUID"] as? Data,
            loaded.header.kdfParameters["$UUID"] as? Data,
            label,
            file: file,
            line: line
        )
        // Cost parameters for both KDF families; absent keys compare nil == nil.
        XCTAssertEqual(
            result.afterHeader.kdfParameters["I"] as? UInt64,
            loaded.header.kdfParameters["I"] as? UInt64,
            label, file: file, line: line
        )
        XCTAssertEqual(
            result.afterHeader.kdfParameters["M"] as? UInt64,
            loaded.header.kdfParameters["M"] as? UInt64,
            label, file: file, line: line
        )
        XCTAssertEqual(
            result.afterHeader.kdfParameters["P"] as? UInt32,
            loaded.header.kdfParameters["P"] as? UInt32,
            label, file: file, line: line
        )
        XCTAssertEqual(
            result.afterHeader.kdfParameters["R"] as? UInt64,
            loaded.header.kdfParameters["R"] as? UInt64,
            label, file: file, line: line
        )

        let sourceSalt = try XCTUnwrap(loaded.header.kdfParameters["S"] as? Data, label, file: file, line: line)
        let writtenSalt = try XCTUnwrap(result.afterHeader.kdfParameters["S"] as? Data, label, file: file, line: line)
        XCTAssertNotEqual(writtenSalt, sourceSalt, "\(label): KDF salt must rotate", file: file, line: line)
        XCTAssertEqual(writtenSalt.count, sourceSalt.count, label, file: file, line: line)
        XCTAssertNotEqual(
            result.afterHeader.masterSeed,
            loaded.header.masterSeed,
            "\(label): master seed must rotate",
            file: file,
            line: line
        )
    }

    func test_attachmentsFixture_preservesAttachmentsAndPoolContentHashesAcrossScenarios() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)

        // fixtureSmoke: creating an unrelated entry should not disturb any
        // existing entry's attachments or their resolved pool bytes.
        let smokeLoaded = try KDBXCompatibilitySupport.load(.attachments, bundle: bundle)
        let smokeResult = try collector.run(
            KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: KDBXCompatibilitySupport.Fixture.attachments.id),
            on: smokeLoaded
        )

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
        try collector.run(KDBXCompatibilitySupport.attachmentsFixtureUpdateEntryScenario(), on: updateLoaded)

        // softDelete: recycling one dedup entry doesn't disturb its sibling.
        let softDeleteLoaded = try KDBXCompatibilitySupport.load(.attachments, bundle: bundle)
        try collector.run(KDBXCompatibilitySupport.attachmentsFixtureSoftDeleteScenario(), on: softDeleteLoaded)

        try collector.emit()
    }

    /// `group-tags.kdbx` is the pykeepass-authored KDBX 4.1 fixture whose
    /// groups carry `<Tags>` in all three states (content, empty element, no
    /// element; see `TestFixtures/README.md`). `keepassxc-cli` has no verb
    /// that prints group tags, so the external gate can only prove the
    /// rewritten database opens with its structure and protected values
    /// intact — the group-tag preservation proof is in-process, on the
    /// reparsed snapshots asserted here and in the scenarios' own checks.
    func test_groupTagsFixture_preservesGroupTagsAcrossSaves() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)

        // fixtureSmoke: creating an unrelated entry must not disturb any
        // group's tags, has-element flag, or structured <Notes>.
        let smokeLoaded = try KDBXCompatibilitySupport.load(.groupTags, bundle: bundle)
        XCTAssertEqual(
            smokeLoaded.header.formatVersion,
            .kdbx4(minor: 1),
            "Fixture precondition: group tags are a KDBX 4.1 feature and the fixture must really be 4.1"
        )
        let smokeResult = try collector.run(
            KDBXCompatibilitySupport.fixtureSmokeScenario(fixtureID: KDBXCompatibilitySupport.Fixture.groupTags.id),
            on: smokeLoaded
        )
        assertSmokeShape(smokeResult, fixture: smokeLoaded.fixture)
        XCTAssertEqual(
            smokeResult.afterHeader.formatVersion,
            .kdbx4(minor: 1),
            "A rewrite must keep the source's 4.1 version, not renegotiate it"
        )
        try assertGroupTagFixtureShape(in: smokeResult.before)
        try assertGroupTagFixtureShape(in: smokeResult.after)

        // updateEntry: editing an entry nested under both tagged groups runs
        // the copyGroup/replacingChildGroup funnel over exactly the groups
        // that carry tags; the scenario's own assertions re-check every
        // group's tags on the reparsed tree.
        let updateLoaded = try KDBXCompatibilitySupport.load(.groupTags, bundle: bundle)
        let updateResult = try collector.run(
            KDBXCompatibilitySupport.groupTagsFixtureUpdateEntryScenario(),
            on: updateLoaded
        )
        try assertGroupTagFixtureShape(in: updateResult.after)

        // updateGroup: authoring a KeeForge group tag on the one group that
        // never carried `<Tags>` must leave the other three states intact.
        // `assertGroupTagFixtureShape` deliberately isn't reused here — it
        // pins `Plain Group` as untagged, which is exactly what this edit
        // changes; the scenario asserts every group's post-edit state itself.
        let updateGroupLoaded = try KDBXCompatibilitySupport.load(.groupTags, bundle: bundle)
        let updateGroupResult = try collector.run(
            KDBXCompatibilitySupport.groupTagsFixtureUpdateGroupScenario(),
            on: updateGroupLoaded
        )
        XCTAssertEqual(
            updateGroupResult.afterHeader.formatVersion,
            .kdbx4(minor: 1),
            "A 4.1 source stays 4.1; the version floor never downgrades"
        )

        try collector.emit()
    }

    private func assertGroupTagFixtureShape(
        in snapshot: CompatibilitySnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let projects = try XCTUnwrap(
            snapshot.groups[XCTUnwrap(snapshot.groupID(named: "Projects"), file: file, line: line)],
            file: file,
            line: line
        )
        XCTAssertEqual(projects.tags, ["team", "shared"], file: file, line: line)
        XCTAssertTrue(projects.hasTagsElement, file: file, line: line)
        XCTAssertTrue(projects.hasNotesElement, file: file, line: line)
        XCTAssertEqual(
            projects.notes,
            "Group notes ride along as unknown XML next to the structured Tags element.",
            "Projects' <Notes> parses into the structured field next to the structured <Tags>",
            file: file,
            line: line
        )
        XCTAssertFalse(
            projects.unknownXML.nodes.contains { $0.xml.hasPrefix("<Notes>") },
            "Group <Notes> is structured now, so no opaque copy may remain",
            file: file,
            line: line
        )

        let clientWork = try XCTUnwrap(
            snapshot.groups[XCTUnwrap(snapshot.groupID(named: "Client Work"), file: file, line: line)],
            file: file,
            line: line
        )
        XCTAssertEqual(clientWork.tags, ["billable"], file: file, line: line)
        XCTAssertTrue(clientWork.hasTagsElement, file: file, line: line)

        let emptyTags = try XCTUnwrap(
            snapshot.groups[XCTUnwrap(snapshot.groupID(named: "Empty Tags Group"), file: file, line: line)],
            file: file,
            line: line
        )
        XCTAssertTrue(emptyTags.tags.isEmpty, file: file, line: line)
        XCTAssertTrue(emptyTags.hasTagsElement, file: file, line: line)

        let plain = try XCTUnwrap(
            snapshot.groups[XCTUnwrap(snapshot.groupID(named: "Plain Group"), file: file, line: line)],
            file: file,
            line: line
        )
        XCTAssertTrue(plain.tags.isEmpty, file: file, line: line)
        XCTAssertFalse(
            plain.hasTagsElement,
            "A group without the element in the source must never gain one",
            file: file,
            line: line
        )
    }

    /// The KeeOTP artifact keeps every raw KeeOTP source spelling/encoding in
    /// the written database (the in-process matrix below proves their
    /// semantics), but its external probe is a plain entry title: KeePassXC
    /// 2.7.12 skips entries whose raw KeeOTP field uses its unsupported
    /// key/query format, so probing a KeeOTP entry would fail for a reason
    /// that says nothing about KeeForge's output.
    func test_keeOTPArtifact_preservesEverySourceVariantAndUsesStandardExternalProbe() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)
        let loaded = try KDBXCompatibilitySupport.loadKeeOTPArtifactFixture(bundle: bundle)
        let scenario = KDBXCompatibilitySupport.keeOTPArtifactScenario()

        XCTAssertEqual(scenario.expectedSearchTerms, ["Compat Update Target"])
        XCTAssertEqual(
            loaded.rootGroup.entries.filter { $0.title.hasPrefix("KeeOTP ") }.count,
            KDBXCompatibilitySupport.keeOTPCases.count
        )

        try collector.run(scenario, on: loaded)

        try collector.emit()
    }

    /// The merge engine's output is written like any other save, so it has to
    /// survive the same round trip: a merged tree reaches `KDBXWriter` through
    /// a pristine draft rather than as an `EntryEdit`, and the artifact this
    /// emits is opened by real KeePassXC in the external gate.
    func test_mergeScenario_writesAMergedTreeThatReparsesAndOpensExternally() throws {
        let collector = try KDBXCompatibilitySupport.ArtifactCollector(testCase: self)
        let loaded = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: bundle)
        let scenario = KDBXCompatibilitySupport.mergeRemoteDivergenceScenario()

        let result = try collector.run(scenario, on: loaded)

        assertHeaderPreserved(result, loaded: loaded, scenario: scenario)
        XCTAssertEqual(
            result.afterHeader.formatVersion,
            loaded.header.formatVersion,
            "a merge must not renegotiate the source's header version"
        )

        try collector.emit()
    }

    /// `Entry.attachmentHashes` only covers binaries some `<Binary>` element
    /// references, so it cannot see the pool itself being disturbed. Pin the
    /// whole-pool digest's sensitivity: every scenario compares it across the
    /// save, and a digest that ignored any of these would be decoration.
    func test_binaryPoolDigest_detectsOrphanedReorderedAndReflaggedPoolEntries() throws {
        let sessionKey = SymmetricKey(size: .bits256)
        let rootGroup = KPGroup(name: "Root")

        func digest(_ rawFields: [Data]?) throws -> String? {
            try CompatibilitySnapshot(
                rootGroup: rootGroup,
                meta: KPMeta(),
                sessionKey: sessionKey,
                binaryPool: rawFields.map { BinaryPool(rawFields: $0) }
            ).binaryPoolDigest
        }

        // Raw pool fields keep their leading 1-byte memory-protection flag.
        let alpha = Data([0x00]) + Data("alpha".utf8)
        let beta = Data([0x00]) + Data("beta".utf8)
        let alphaProtected = Data([0x01]) + Data("alpha".utf8)

        let baseline = try XCTUnwrap(try digest([alpha, beta]))
        XCTAssertEqual(baseline, try digest([alpha, beta]), "digest must be deterministic")
        XCTAssertNotEqual(baseline, try digest([beta, alpha]), "reordering the pool must change the digest")
        XCTAssertNotEqual(baseline, try digest([alpha]), "dropping an unreferenced pool entry must change the digest")
        XCTAssertNotEqual(baseline, try digest([alpha, beta, alpha]), "an extra orphan pool entry must change the digest")
        XCTAssertNotEqual(baseline, try digest([alphaProtected, beta]), "a flipped protection flag must change the digest")
        XCTAssertNotEqual(baseline, try digest([]), "an emptied pool must change the digest")
        XCTAssertNil(try digest(nil), "no pool means no digest, never a digest that compares equal to an empty pool")
    }

    // MARK: - Artifact set integrity

    func test_artifactDescriptors_coverEverySmokeFixtureAndEveryFullEditScenario() throws {
        let descriptors = KDBXCompatibilitySupport.artifactDescriptors
        let ids = descriptors.map(\.id)
        let fileNames = descriptors.map(\.scenario.artifactFileName)

        XCTAssertEqual(Set(ids).count, ids.count, "artifact ids must be unique")
        XCTAssertEqual(Set(fileNames).count, fileNames.count, "artifact file names must be unique")

        for fixture in KDBXCompatibilitySupport.smokeFixtures {
            XCTAssertTrue(
                ids.contains("\(fixture.id)-fixture-smoke-\(fixture.id)"),
                "smoke fixture \(fixture.id) has no artifact"
            )
        }

        let richID = KDBXCompatibilitySupport.Fixture.syntheticRich.id
        for scenario in KDBXCompatibilitySupport.fullEditScenarios() {
            XCTAssertTrue(
                ids.contains("\(richID)-\(scenario.id)"),
                "full-edit scenario \(scenario.id) has no artifact"
            )
        }

        for required in [
            "synthetic-no-recycle-bin-recycle-bin-creation",
            "attachments-fixture-smoke-attachments",
            "attachments-attachments-update-entry",
            "attachments-attachments-soft-delete-entry",
            "group-tags-group-tags-update-entry",
            "group-tags-group-tags-update-group",
            "\(richID)-keeotp-source-matrix",
            "\(richID)-merge-remote-divergence",
            "aes-baseline-rekey-password-only",
            "aes-baseline-rekey-add-keyfile",
            "password-keyfile-rekey-remove-keyfile",
        ] {
            XCTAssertTrue(ids.contains(required), "missing artifact \(required)")
        }

        // The artifact set never shrinks silently: the gate's merged manifest
        // is compared against exactly this count.
        XCTAssertEqual(descriptors.count, 36)
    }

    func test_externalExpectationTables_areExhaustiveOverEveryArtifactScenario() throws {
        let scenarioIDs = Set(KDBXCompatibilitySupport.artifactDescriptors.map(\.scenario.id))

        for scenarioID in scenarioIDs {
            XCTAssertNoThrow(try KDBXCompatibilitySupport.expectedAttachments(forScenarioID: scenarioID))
            XCTAssertNoThrow(try KDBXCompatibilitySupport.expectedPasswords(forScenarioID: scenarioID))
            XCTAssertNoThrow(try KDBXCompatibilitySupport.expectedTOTPs(forScenarioID: scenarioID))
        }

        // An unknown id must fail rather than quietly return "no expectations".
        XCTAssertThrowsError(try KDBXCompatibilitySupport.expectedAttachments(forScenarioID: "not-a-scenario"))
        XCTAssertThrowsError(try KDBXCompatibilitySupport.expectedPasswords(forScenarioID: "not-a-scenario"))
        XCTAssertThrowsError(try KDBXCompatibilitySupport.expectedTOTPs(forScenarioID: "not-a-scenario"))

        let attachmentKeys = Set(KDBXCompatibilitySupport.attachmentExpectations.keys)
        let noAttachmentKeys = KDBXCompatibilitySupport.scenarioIDsWithoutAttachmentExpectations
        XCTAssertTrue(attachmentKeys.isDisjoint(with: noAttachmentKeys))
        XCTAssertEqual(attachmentKeys.union(noAttachmentKeys), scenarioIDs, "stale or missing attachment expectation ids")

        let passwordKeys = Set(KDBXCompatibilitySupport.passwordExpectations.keys)
        let noPasswordKeys = KDBXCompatibilitySupport.scenarioIDsWithoutPasswordExpectations
        XCTAssertTrue(passwordKeys.isDisjoint(with: noPasswordKeys))
        XCTAssertEqual(passwordKeys.union(noPasswordKeys), scenarioIDs, "stale or missing password expectation ids")

        let totpKeys = Set(KDBXCompatibilitySupport.totpExpectations.keys)
        let noTOTPKeys = KDBXCompatibilitySupport.scenarioIDsWithoutTOTPExpectations
        XCTAssertTrue(totpKeys.isDisjoint(with: noTOTPKeys))
        XCTAssertEqual(totpKeys.union(noTOTPKeys), scenarioIDs, "stale or missing TOTP expectation ids")

        // Every fixture that reaches the external gate contributes a password
        // check on a value it did not author itself.
        for fixture in KDBXCompatibilitySupport.smokeFixtures + [KDBXCompatibilitySupport.Fixture.attachments] {
            XCTAssertNotNil(
                KDBXCompatibilitySupport.fixtureEntryPasswords[fixture.id],
                "\(fixture.id) has no pre-existing entry password for the external gate"
            )
        }
    }

    @MainActor
    func test_keeOTPCompatibilityMatrix_preservesAndIntentionallyMutatesSources() throws {
        for testCase in KDBXCompatibilitySupport.keeOTPCases {
            for mutation in KeeOTPMutation.allCases {
                let reloaded = try editSaveReloadKeeOTP(testCase, mutation: mutation)
                let config = try XCTUnwrap(reloaded.totpConfig, "\(testCase.fieldName) \(testCase.label) \(mutation.rawValue)")
                let source = try XCTUnwrap(config.keeOTPSource)
                // Minimal sources omit default-valued parameters, so only
                // assert on parameters the original query carried.
                let hadEncoding = testCase.rawQuery.contains("Encoding=")
                let hadVendor = testCase.rawQuery.contains("vendor=")

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
                    if hadEncoding { XCTAssertTrue(source.rawQuery.contains("Encoding=\(testCase.encoding)")) }
                    if hadVendor { XCTAssertTrue(source.rawQuery.contains("vendor=keep%2Bme")) }
                    XCTAssertEqual(config.period, 45)
                    XCTAssertEqual(resolvedSecret(config), testCase.decodedSecret)
                case .secret:
                    XCTAssertTrue(source.rawQuery.contains("key=JBSWY3DP"))
                    if hadEncoding { XCTAssertTrue(source.rawQuery.contains("Encoding=Base32")) }
                    if hadVendor { XCTAssertTrue(source.rawQuery.contains("vendor=keep%2Bme")) }
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

    @MainActor
    func test_freshOTPAuthURIEnrollment_storesProtectedVerbatimURIAndLaterEditsDropIt() throws {
        let raw = "otpauth://totp/Compat:enroll@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Compat&period=45&digits=8&algorithm=SHA256"
        let entry = KPEntry(
            title: "Enrollment Target",
            password: try EncryptedValue.encrypt("password", using: entrySessionKey)
        )
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: entrySessionKey)
        viewModel.applyOTPAuthURI(try OTPAuthURI(string: raw))

        var updated = try DatabaseDraft(rootGroup: KPGroup(name: "Root", entries: [entry]), meta: KPMeta(), sessionKey: entrySessionKey)
            .apply(.updateEntry(entryID: entry.id, draft: viewModel.entryDraftPayload))
        var reloaded = try writeAndReload(updated)
        var config = try XCTUnwrap(reloaded.totpConfig)
        XCTAssertEqual(reloaded.otpURL, raw, "Enrollment must store the URI verbatim, KeePassXC-style")
        XCTAssertTrue(reloaded.protectedStringKeys.contains("otp"))
        XCTAssertEqual(config.period, 45)
        XCTAssertEqual(config.digits, 8)
        XCTAssertEqual(config.algorithm, .sha256)
        XCTAssertEqual(resolvedSecret(config), TOTPGenerator.base32Decode("JBSWY3DPEHPK3PXP"))
        XCTAssertFalse(reloaded.customFields.keys.contains { $0.hasPrefix("TimeOtp-") })

        // A later field edit makes the stored URI stale: it must be dropped,
        // falling back to TimeOtp-* authoring, never rewritten.
        let editViewModel = EntryEditViewModel(editing: reloaded, sessionKey: entrySessionKey)
        editViewModel.totpPeriod = 60
        updated = try DatabaseDraft(rootGroup: KPGroup(name: "Root", entries: [reloaded]), meta: KPMeta(), sessionKey: entrySessionKey)
            .apply(.updateEntry(entryID: reloaded.id, draft: editViewModel.entryDraftPayload))
        reloaded = try writeAndReload(updated)
        config = try XCTUnwrap(reloaded.totpConfig)
        XCTAssertNil(reloaded.otpURL)
        XCTAssertEqual(config.period, 60)
        XCTAssertEqual(resolvedSecret(config), TOTPGenerator.base32Decode("JBSWY3DPEHPK3PXP"))
    }

    func test_passkeyPrivateKey_divertedOnParse_andPreservedThroughEditSaveReload() throws {
        let loaded = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: bundle, sessionKey: entrySessionKey)
        let entry = try XCTUnwrap(firstEntry(titled: "Compat Update Target", in: loaded.rootGroup))

        // Parse diverts the PEM out of customFields into the sealed value.
        XCTAssertNil(entry.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertEqual(
            try XCTUnwrap(entry.passkeyPrivateKey).decrypt(using: entrySessionKey),
            "private-key-pem"
        )
        XCTAssertTrue(entry.protectedStringKeys.contains(PasskeyCredential.privateKeyPEMKey))
        XCTAssertNotNil(entry.passkeyCredential)

        // An unrelated edit must carry the sealed key through draft, write,
        // and reparse — including into the history snapshot the edit creates.
        let payload = EntryDraftPayload(
            title: entry.title,
            username: entry.username,
            password: try entry.password.decrypt(using: entrySessionKey),
            url: entry.url,
            notes: "Edited for passkey preservation",
            customFields: entry.customFields,
            tags: entry.tags,
            totpConfig: (entry.totpConfig).map {
                EntryDraftPayload.TOTPConfiguration(
                    secret: (try? $0.secret.decrypt(using: entrySessionKey)) ?? "",
                    period: $0.period,
                    digits: $0.digits,
                    algorithm: $0.algorithm
                )
            }
        )
        let updatedDraft = try DatabaseDraft(
            rootGroup: loaded.rootGroup,
            meta: loaded.meta,
            sessionKey: entrySessionKey
        ).apply(.updateEntry(entryID: entry.id, draft: payload))

        let written = try KDBXWriter.write(
            rootGroup: updatedDraft.rootGroup,
            meta: updatedDraft.meta,
            compositeKey: loaded.compositeKey,
            header: loaded.header,
            sessionKey: updatedDraft.writerSessionKey
        )
        let reparsed = try KDBXParser.parseWithMeta(
            data: written,
            compositeKey: loaded.compositeKey,
            sessionKey: entrySessionKey
        )
        let reloaded = try XCTUnwrap(firstEntry(titled: "Compat Update Target", in: reparsed.rootGroup))

        XCTAssertEqual(reloaded.notes, "Edited for passkey preservation")
        XCTAssertNil(reloaded.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertEqual(
            try XCTUnwrap(reloaded.passkeyPrivateKey).decrypt(using: entrySessionKey),
            "private-key-pem"
        )
        XCTAssertTrue(reloaded.protectedStringKeys.contains(PasskeyCredential.privateKeyPEMKey))

        // History entries flow through the same EntryBuilder, so the pre-edit
        // snapshot must carry the diverted key too.
        let historySnapshot = try XCTUnwrap(reloaded.history.first)
        XCTAssertNil(historySnapshot.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertEqual(
            try XCTUnwrap(historySnapshot.passkeyPrivateKey).decrypt(using: entrySessionKey),
            "private-key-pem"
        )
    }

    func test_passkeyEntry_serializeParseSerialize_isByteIdenticalAndReprotected() throws {
        let pem = "-----BEGIN PRIVATE KEY-----\nCOMPAT-BYTE-IDENTITY\n-----END PRIVATE KEY-----"
        let innerStreamKey = Data("KeeForge Passkey Inner Stream Key".utf8)
        let entry = KPEntry(
            title: "Passkey Byte Identity",
            username: "alice",
            password: try EncryptedValue.encrypt("password", using: entrySessionKey),
            customFields: [
                "AAA Leading": "before-pem",
                PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
                "ZZZ Trailing": "after-pem",
            ],
            passkeyPrivateKey: try EncryptedValue.encrypt(pem, using: entrySessionKey),
            protectedStringKeys: [PasskeyCredential.privateKeyPEMKey]
        )
        let rootGroup = KPGroup(name: "Root", entries: [entry])
        let meta = KPMeta()

        var firstSerializer = KDBXXMLSerializer(
            rootGroup: rootGroup,
            meta: meta,
            innerStreamKey: innerStreamKey,
            sessionKey: entrySessionKey
        )
        let firstXML = try firstSerializer.serialize()
        let firstXMLString = String(decoding: firstXML, as: UTF8.self)

        // The diverted key is re-emitted under its original field name as a
        // Protected value; the plaintext PEM never appears in the XML.
        XCTAssertTrue(
            firstXMLString.contains("<Key>\(PasskeyCredential.privateKeyPEMKey)</Key><Value Protected=\"True\">")
        )
        XCTAssertFalse(firstXMLString.contains("COMPAT-BYTE-IDENTITY"))

        let reparsed = try KDBXXMLParser(
            data: firstXML,
            innerStreamKey: innerStreamKey,
            innerStreamID: KDBXParser.innerStreamChaCha20,
            sessionKey: entrySessionKey
        ).parse()
        let reparsedEntry = try XCTUnwrap(firstEntry(titled: "Passkey Byte Identity", in: reparsed.rootGroup))

        XCTAssertNil(reparsedEntry.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertEqual(
            try XCTUnwrap(reparsedEntry.passkeyPrivateKey).decrypt(using: entrySessionKey),
            pem
        )
        XCTAssertEqual(reparsedEntry.customFields["AAA Leading"], "before-pem")
        XCTAssertEqual(reparsedEntry.customFields["ZZZ Trailing"], "after-pem")

        var secondSerializer = KDBXXMLSerializer(
            rootGroup: reparsed.rootGroup,
            meta: reparsed.meta,
            innerStreamKey: innerStreamKey,
            sessionKey: entrySessionKey
        )
        let secondXML = try secondSerializer.serialize()

        XCTAssertEqual(firstXML, secondXML, "Passkey round-trip must be byte-identical")
    }

    func test_passkeyEntryCreation_protectsPasskeyFieldsThroughWriteAndReparse() throws {
        let loaded = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: bundle, sessionKey: entrySessionKey)
        let pem = "-----BEGIN PRIVATE KEY-----\nCREATED-PASSKEY-PEM\n-----END PRIVATE KEY-----"
        let protectedKeys: Set<String> = [
            PasskeyCredential.credentialIDKey,
            PasskeyCredential.privateKeyPEMKey,
            PasskeyCredential.userHandleKey,
        ]
        let payload = EntryDraftPayload(
            title: "Created Passkey Entry",
            username: "alice@example.com",
            password: "created-passkey-password",
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "3q2-7wEj",
                PasskeyCredential.privateKeyPEMKey: pem,
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "AAEC-_z9",
            ],
            protectedCustomFieldKeys: protectedKeys
        )

        let updatedDraft = try DatabaseDraft(
            rootGroup: loaded.rootGroup,
            meta: loaded.meta,
            sessionKey: entrySessionKey
        ).apply(.createEntry(
            parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: loaded.rootGroup),
            draft: payload
        ))

        let written = try KDBXWriter.write(
            rootGroup: updatedDraft.rootGroup,
            meta: updatedDraft.meta,
            compositeKey: loaded.compositeKey,
            header: loaded.header,
            sessionKey: updatedDraft.writerSessionKey
        )
        let reparsed = try KDBXParser.parseWithMeta(
            data: written,
            compositeKey: loaded.compositeKey,
            sessionKey: entrySessionKey
        )
        let reloaded = try XCTUnwrap(firstEntry(titled: "Created Passkey Entry", in: reparsed.rootGroup))

        XCTAssertEqual(reloaded.protectedStringKeys.intersection(PasskeyCredential.allFieldKeys), protectedKeys)
        XCTAssertNil(reloaded.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertEqual(try XCTUnwrap(reloaded.passkeyPrivateKey).decrypt(using: entrySessionKey), pem)
        XCTAssertEqual(reloaded.customFields[PasskeyCredential.relyingPartyKey], "example.com")
        XCTAssertEqual(reloaded.customFields[PasskeyCredential.usernameKey], "alice@example.com")

        let credentialID = try XCTUnwrap(reloaded.customFields[PasskeyCredential.credentialIDKey])
        XCTAssertEqual(credentialID, "3q2-7wEj")
        XCTAssertEqual(base64URLDecode(credentialID), Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x23]))
        XCTAssertEqual(base64URLDecode(credentialID).map(base64URLEncode), credentialID)
        let userHandle = try XCTUnwrap(reloaded.customFields[PasskeyCredential.userHandleKey])
        XCTAssertEqual(userHandle, "AAEC-_z9")
        XCTAssertEqual(base64URLDecode(userHandle), Data([0x00, 0x01, 0x02, 0xFB, 0xFC, 0xFD]))
        XCTAssertEqual(base64URLDecode(userHandle).map(base64URLEncode), userHandle)

        XCTAssertNotNil(reloaded.passkeyCredential)
    }

    private func firstEntry(titled title: String, in group: KPGroup) -> KPEntry? {
        group.allEntries.first { $0.title == title }
    }

    /// Cipher and KDF identity must survive every edit; asserted against the
    /// header the scenario already reparsed, so this costs no extra KDF work.
    private func assertHeaderPreserved(
        _ result: KDBXCompatibilitySupport.ScenarioResult,
        loaded: KDBXCompatibilitySupport.LoadedFixture,
        scenario: KDBXCompatibilitySupport.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let label = "\(loaded.fixture.id)/\(scenario.id)"
        XCTAssertEqual(result.afterHeader.cipherID, loaded.header.cipherID, label, file: file, line: line)
        XCTAssertEqual(
            result.afterHeader.kdfParameters["$UUID"] as? Data,
            loaded.header.kdfParameters["$UUID"] as? Data,
            label,
            file: file,
            line: line
        )
    }

    /// Generic shape checks shared by every `fixtureSmokeScenario` run,
    /// including the two fixtures with their own deeper test method.
    private func assertSmokeShape(
        _ result: KDBXCompatibilitySupport.ScenarioResult,
        fixture: KDBXCompatibilitySupport.Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            result.written.isEmpty,
            "\(fixture.displayName) should produce encrypted output",
            file: file,
            line: line
        )
        XCTAssertEqual(result.after.entries.count, result.before.entries.count + 1, file: file, line: line)
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
            title: "KeeOTP \(testCase.fieldName) \(testCase.label)",
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
