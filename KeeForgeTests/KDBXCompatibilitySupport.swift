import CryptoKit
import Foundation
import XCTest
@testable import KeeForge

enum KDBXCompatibilitySupport {
    /// File-name prefix for the per-test-method manifest fragments emitted
    /// alongside the `.kdbx` artifacts. Every `KDBXCompatibilityTests` method
    /// that runs scenarios attaches exactly one fragment describing only the
    /// artifacts it produced; `ci_scripts/run_kdbx_compatibility_gate.sh`
    /// merges every fragment it finds in the exported attachments.
    static let artifactManifestNamePrefix = "kdbx-compatibility-manifest"

    struct KeeOTPCase {
        let fieldName: String
        let encoding: String
        let encodedKey: String
        let secret: String
        let decodedSecret: Data
        var queryOverride: String?

        var rawQuery: String {
            queryOverride ?? "key=\(encodedKey)&Type=TOTP&step=30&size=6&Encoding=\(encoding)&otpHashMode=SHA1&vendor=keep%2Bme"
        }

        var label: String {
            queryOverride == nil ? encoding : "\(encoding) Minimal"
        }
    }

    static let keeOTPCases: [KeeOTPCase] = ["otp", "OTP"].flatMap { fieldName in
        [
            KeeOTPCase(fieldName: fieldName, encoding: "Base32", encodedKey: "JBSWY3DP", secret: "JBSWY3DP", decodedSecret: Data("Hello".utf8)),
            KeeOTPCase(fieldName: fieldName, encoding: "Base64", encodedKey: "AAEC%2Fw%3D%3D", secret: "AAEC/w==", decodedSecret: Data([0x00, 0x01, 0x02, 0xFF])),
            KeeOTPCase(fieldName: fieldName, encoding: "Hex", encodedKey: "000102ff", secret: "000102ff", decodedSecret: Data([0x00, 0x01, 0x02, 0xFF])),
            KeeOTPCase(fieldName: fieldName, encoding: "UTF8", encodedKey: "p%C3%A4ss", secret: "päss", decodedSecret: Data("päss".utf8)),
            // KeeOtp2 omits parameters at their defaults; this is the most
            // common real-world payload shape.
            KeeOTPCase(
                fieldName: fieldName, encoding: "Base32", encodedKey: "JBSWY3DP", secret: "JBSWY3DP",
                decodedSecret: Data("Hello".utf8), queryOverride: "key=JBSWY3DP"
            ),
        ]
    }

    /// Recorded SHA-256 hashes for `TestFixtures/compatibility/attachments.kdbx`
    /// content, generated deterministically via `pykeepass` (see
    /// `TestFixtures/README.md`). `keepassxc-cli db-create` only produces
    /// KDBX 3.1 databases and exposes no cipher/KDF override flags, so this
    /// fixture cannot be regenerated with the CLI used by the other
    /// compatibility fixtures.
    enum AttachmentFixtureHashes {
        static let noteUnicodeTxt = "bcc1c6cd101bd5b27356a7004361fd1e1ff74ed2ef416e3252997d328efd3727"
        static let pixelPNG = "3ec322a42990a3067cc6c73f3856a86e55bdd8baf19d2166954a8fb319329a72"
        static let sharedBin = "fd184a4f05cf3d4f39ab726bda3d3a923da30e9ab2d6697b69c2d39d7ea1ab18"
    }

    struct Fixture {
        enum Source {
            case bundled(name: String, subdirectory: String? = "compatibility")
            case generated(cipherID: Data, hasRecycleBin: Bool)
        }

        let id: String
        let displayName: String
        let password: String
        let keyFileName: String?
        let source: Source

        static let aesBaseline = Fixture(
            id: "aes-baseline",
            displayName: "AES baseline fixture",
            password: "testpassword123",
            keyFileName: nil,
            source: .bundled(name: "aes-baseline")
        )

        static let passwordKeyfile = Fixture(
            id: "password-keyfile",
            displayName: "Password plus key file fixture",
            password: "demo",
            keyFileName: "password-keyfile",
            source: .bundled(name: "password-keyfile")
        )

        static let unknownRich = Fixture(
            id: "unknown-rich",
            displayName: "Unknown XML fixture",
            password: "test-round-trip",
            keyFileName: nil,
            source: .bundled(name: "unknown-rich")
        )

        static let kdbx41PublicCustomData = Fixture(
            id: "kdbx41-public-custom-data",
            displayName: "KDBX 4.1 public custom data fixture",
            password: "testpassword123",
            keyFileName: nil,
            source: .bundled(name: "kdbx41-public-custom-data")
        )

        static let legacyKDBX31 = Fixture(
            id: "legacy-kdbx31",
            displayName: "Legacy KDBX 3.1 fixture",
            password: "testpassword123",
            keyFileName: nil,
            source: .bundled(name: "legacy-kdbx31")
        )

        static let attachments = Fixture(
            id: "attachments",
            displayName: "Attachments fixture",
            password: "testpassword123",
            keyFileName: nil,
            source: .bundled(name: "attachments")
        )

        /// Foreign-authored (pykeepass) KDBX4 fixture with the ChaCha20 outer
        /// cipher. Every other bundled fixture is AES-256-CBC authored by
        /// pykeepass or KeeForge itself, so this and `foreignTwofish` are the
        /// only fixtures that prove KeeForge's ChaCha20/Twofish outer-cipher
        /// READ paths against a database KeeForge did not write. See
        /// `TestFixtures/compatibility/generate_foreign_cipher_fixtures.py`.
        static let foreignChaCha20 = Fixture(
            id: "foreign-chacha20",
            displayName: "Foreign-authored ChaCha20 fixture",
            password: "foreign-chacha20",
            keyFileName: nil,
            source: .bundled(name: "foreign-chacha20")
        )

        /// Foreign-authored (pykeepass) KDBX4 fixture with the Twofish outer
        /// cipher. See `foreignChaCha20`.
        static let foreignTwofish = Fixture(
            id: "foreign-twofish",
            displayName: "Foreign-authored Twofish fixture",
            password: "foreign-twofish",
            keyFileName: nil,
            source: .bundled(name: "foreign-twofish")
        )

        /// Foreign-authored (pykeepass) KDBX 4.1 fixture whose groups carry
        /// `<Tags>` in all three states — content (`Projects`, nested
        /// `Client Work`), an empty element (`Empty Tags Group`), and no
        /// element at all (`Plain Group`) — plus a group `<Notes>` that
        /// KeeForge keeps as unknown XML right next to the now-structured
        /// `<Tags>`. See
        /// `TestFixtures/compatibility/generate_group_tags_fixture.py` and
        /// `TestFixtures/README.md`.
        static let groupTags = Fixture(
            id: "group-tags",
            displayName: "KDBX 4.1 group tags fixture",
            password: "testpassword123",
            keyFileName: nil,
            source: .bundled(name: "group-tags")
        )

        static let syntheticRich = Fixture(
            id: "synthetic-rich",
            displayName: "Synthetic rich KDBX4 fixture",
            password: "compatibility-password",
            keyFileName: nil,
            source: .generated(cipherID: KDBXParser.aesCipherUUID, hasRecycleBin: true)
        )

        static let syntheticNoRecycleBin = Fixture(
            id: "synthetic-no-recycle-bin",
            displayName: "Synthetic fixture without recycle bin",
            password: "compatibility-password",
            keyFileName: nil,
            source: .generated(cipherID: KDBXParser.aesCipherUUID, hasRecycleBin: false)
        )

        static let syntheticChaCha = Fixture(
            id: "synthetic-chacha",
            displayName: "Synthetic ChaCha20 fixture",
            password: "compatibility-password",
            keyFileName: nil,
            source: .generated(cipherID: KDBXParser.chachaCipherUUID, hasRecycleBin: true)
        )

        static let syntheticTwofish = Fixture(
            id: "synthetic-twofish",
            displayName: "Synthetic Twofish-256-CBC fixture",
            password: "compatibility-password",
            keyFileName: nil,
            source: .generated(cipherID: KDBXParser.twofishCipherUUID, hasRecycleBin: true)
        )
    }

    /// The representative fixtures driven through `fixtureSmokeScenario`.
    ///
    /// Single source of truth: `KDBXCompatibilityTests` iterates this list and
    /// `artifactDescriptors` derives the matching artifact set from it, so the
    /// matrix and the external-opener gate can no longer drift apart. The
    /// `attachments` fixture is deliberately not here — it has a dedicated
    /// attachment-focused test that runs its smoke scenario plus two more.
    static let smokeFixtures: [Fixture] = [
        .aesBaseline,
        .passwordKeyfile,
        .unknownRich,
        .kdbx41PublicCustomData,
        .syntheticChaCha,
        .syntheticTwofish,
        .foreignChaCha20,
        .foreignTwofish,
        .groupTags,
    ]

    /// Title of the entry `fixtureSmokeScenario` creates. Shared with the
    /// external expectation tables so a rename cannot desynchronize them.
    static func fixtureSmokeCreatedTitle(fixtureID: String) -> String {
        "Compat Smoke \(fixtureID)"
    }

    /// Password `fixtureSmokeScenario` writes into the entry it creates. The
    /// gate reads this back through `keepassxc-cli` to prove KeeForge's
    /// protected-value stream is decodable by an external opener.
    static let fixtureSmokeCreatedPassword = "compat-secret"

    struct LoadedFixture {
        let fixture: Fixture
        let rootGroup: KPGroup
        let meta: KPMeta
        let header: KDBXParser.Header
        let compositeKey: Data
        let sourceData: Data
        let sessionKey: SymmetricKey
        let keyFileData: Data?
    }

    struct Scenario {
        let id: String
        let title: String
        let artifactFileName: String
        let expectedSearchTerms: [String]
        let expectedGroupPaths: [String]
        let makeEdit: (LoadedFixture) throws -> EntryEdit
        let assertChange: (CompatibilitySnapshot, CompatibilitySnapshot, LoadedFixture) throws -> Void

        func apply(to loaded: LoadedFixture) throws -> ScenarioResult {
            let beforePool = BinaryPool(rawFields: loaded.header.innerHeaderBinaryFields)
            let before = try CompatibilitySnapshot(
                rootGroup: loaded.rootGroup,
                meta: loaded.meta,
                sessionKey: loaded.sessionKey,
                binaryPool: beforePool
            )
            let draft = DatabaseDraft(rootGroup: loaded.rootGroup, meta: loaded.meta, sessionKey: loaded.sessionKey)
            let edit = try makeEdit(loaded)
            let updatedDraft = try draft.apply(edit)
            let written = try KDBXWriter.write(
                rootGroup: updatedDraft.rootGroup,
                meta: updatedDraft.meta,
                compositeKey: loaded.compositeKey,
                header: loaded.header,
                sessionKey: updatedDraft.writerSessionKey
            )
            let reparsed = try KDBXParser.parseWithMetaAndHeader(
                data: written,
                compositeKey: loaded.compositeKey,
                sessionKey: loaded.sessionKey
            )
            let afterPool = BinaryPool(rawFields: reparsed.header.innerHeaderBinaryFields)
            let after = try CompatibilitySnapshot(
                rootGroup: reparsed.rootGroup,
                meta: reparsed.meta,
                sessionKey: loaded.sessionKey,
                binaryPool: afterPool
            )

            // No supported edit adds, removes, renumbers, or reorders inner-header
            // binary pool entries (the writer re-emits the pool verbatim), so the
            // whole-pool digest must survive every scenario. Checked here rather
            // than inside individual `assertChange` closures so a scenario cannot
            // forget it.
            assertBinaryPoolUnchanged(before: before, after: after, scenarioID: id)

            try assertChange(before, after, loaded)
            return ScenarioResult(written: written, before: before, after: after, afterHeader: reparsed.header)
        }
    }

    struct ScenarioResult {
        let written: Data
        let before: CompatibilitySnapshot
        let after: CompatibilitySnapshot
        /// Header of the database reparsed from `written`. Exposed so callers
        /// can assert cipher/KDF/outer-header preservation without paying for
        /// another KDF-bearing parse of the same bytes.
        let afterHeader: KDBXParser.Header
    }

    struct ArtifactManifest: Codable {
        struct ExpectedAttachment: Codable {
            let entryTitle: String
            let attachmentName: String
            let sha256: String
        }

        /// A protected value the external opener must be able to decrypt and
        /// read back verbatim after KeeForge wrote the database.
        struct ExpectedPassword: Codable {
            let entryTitle: String
            let password: String
        }

        struct Artifact: Codable {
            let id: String
            let fileName: String
            let password: String
            let keyFileName: String?
            let expectedSearchTerms: [String]
            let expectedGroupPaths: [String]
            var expectedAttachments: [ExpectedAttachment] = []
            var expectedPasswords: [ExpectedPassword] = []
        }

        /// Every artifact id the suite is expected to emit, repeated in every
        /// fragment. The gate compares this against the merged artifact set so
        /// a test method that silently stopped contributing its fragment fails
        /// the gate instead of shrinking coverage unnoticed.
        let expectedArtifactIDs: [String]
        let artifacts: [Artifact]
    }

    // MARK: - External-opener expectations

    enum ExpectationLookupError: Error, CustomStringConvertible {
        case unlistedScenario(kind: String, scenarioID: String)

        var description: String {
            switch self {
            case .unlistedScenario(let kind, let scenarioID):
                return """
                Scenario '\(scenarioID)' has no \(kind) expectation entry and is not on the \
                explicit no-\(kind)-expectations allowlist in KDBXCompatibilitySupport. Add it to \
                one or the other — renaming a scenario must never silently drop its external checks.
                """
            }
        }
    }

    /// Expected attachment checks keyed by scenario id. Populated for
    /// scenarios where the referenced entry (and its attachment) is expected
    /// to still exist, under its post-edit title, in the written artifact.
    static let attachmentExpectations: [String: [ArtifactManifest.ExpectedAttachment]] = [
        "fixture-smoke-attachments": [
            .init(entryTitle: "Multi Attachment Entry", attachmentName: "note-ü.txt", sha256: AttachmentFixtureHashes.noteUnicodeTxt),
            .init(entryTitle: "Multi Attachment Entry", attachmentName: "pixel.png", sha256: AttachmentFixtureHashes.pixelPNG),
            .init(entryTitle: "Dedup Entry A", attachmentName: "shared.bin", sha256: AttachmentFixtureHashes.sharedBin),
            .init(entryTitle: "Dedup Entry B", attachmentName: "shared.bin", sha256: AttachmentFixtureHashes.sharedBin),
        ],
        "attachments-update-entry": [
            .init(entryTitle: "Multi Attachment Entry Updated", attachmentName: "note-ü.txt", sha256: AttachmentFixtureHashes.noteUnicodeTxt),
            .init(entryTitle: "Multi Attachment Entry Updated", attachmentName: "pixel.png", sha256: AttachmentFixtureHashes.pixelPNG),
        ],
        "attachments-soft-delete-entry": [
            .init(entryTitle: "Dedup Entry B", attachmentName: "shared.bin", sha256: AttachmentFixtureHashes.sharedBin),
        ],
    ]

    /// Scenarios that deliberately carry no external attachment check, because
    /// their fixture has no binary pool (or the scenario's artifact adds
    /// nothing the attachment-fixture artifacts don't already prove).
    static let scenarioIDsWithoutAttachmentExpectations: Set<String> = [
        "create-entry",
        "update-entry",
        "create-group",
        "hide-group-from-autofill",
        "change-group-icon",
        "soft-delete-entry",
        "soft-delete-group",
        "hard-delete-recycled-entry",
        "hard-delete-recycled-group",
        "recycle-bin-creation",
        "keeotp-source-matrix",
        "fixture-smoke-aes-baseline",
        "fixture-smoke-password-keyfile",
        "fixture-smoke-unknown-rich",
        "fixture-smoke-kdbx41-public-custom-data",
        "fixture-smoke-synthetic-chacha",
        "fixture-smoke-synthetic-twofish",
        "fixture-smoke-foreign-chacha20",
        "fixture-smoke-foreign-twofish",
        "fixture-smoke-group-tags",
        "group-tags-update-entry",
    ]

    /// An entry that already exists in each fixture, with the password that
    /// fixture ships, keyed by fixture id.
    ///
    /// Reading these back through `keepassxc-cli` after a KeeForge save proves
    /// the whole protected-value chain — foreign inner stream decoded, then
    /// re-encoded into KeeForge's own stream — rather than only proving
    /// KeeForge can read back what KeeForge just wrote. A self-consistent but
    /// non-conforming protected-stream implementation passes the in-process
    /// matrix and fails here. Values recorded with
    /// `keepassxc-cli show -s -a Password`; see `TestFixtures/README.md`.
    static let fixtureEntryPasswords: [String: ArtifactManifest.ExpectedPassword] = [
        Fixture.aesBaseline.id: .init(entryTitle: "Twitter", password: "twitterpass123"),
        Fixture.passwordKeyfile.id: .init(entryTitle: "KeyFile Test Entry", password: "keyfilepass123"),
        Fixture.unknownRich.id: .init(entryTitle: "Controlled Unknowns", password: "roundtrip-pass"),
        Fixture.kdbx41PublicCustomData.id: .init(entryTitle: "Twitter", password: "twitterpass123"),
        Fixture.attachments.id: .init(entryTitle: "Multi Attachment Entry", password: "entry-password-1"),
        Fixture.syntheticChaCha.id: .init(entryTitle: "Compat Untouched Entry", password: "untouched-password"),
        Fixture.syntheticTwofish.id: .init(entryTitle: "Compat Untouched Entry", password: "untouched-password"),
        Fixture.foreignChaCha20.id: .init(entryTitle: "Foreign Entry Alpha", password: "ForeignAlphaSecret1"),
        Fixture.foreignTwofish.id: .init(entryTitle: "Foreign Entry Alpha", password: "ForeignAlphaSecret1"),
        Fixture.groupTags.id: .init(entryTitle: "Alpha Login", password: "GroupTagAlpha1"),
    ]

    /// Expected protected-value checks keyed by scenario id. Every smoke
    /// artifact pairs the password the scenario just wrote with a password the
    /// fixture already carried; the two rich edit scenarios cover a created
    /// and an edited password on the synthetic AES database.
    static let passwordExpectations: [String: [ArtifactManifest.ExpectedPassword]] = {
        var table: [String: [ArtifactManifest.ExpectedPassword]] = [:]
        for (fixtureID, existingEntry) in fixtureEntryPasswords {
            table["fixture-smoke-\(fixtureID)"] = [
                .init(
                    entryTitle: fixtureSmokeCreatedTitle(fixtureID: fixtureID),
                    password: fixtureSmokeCreatedPassword
                ),
                existingEntry,
            ]
        }
        table["create-entry"] = [
            .init(entryTitle: "Compat Created Entry", password: "created-secret"),
            .init(entryTitle: "Compat Untouched Entry", password: "untouched-password"),
        ]
        table["update-entry"] = [
            .init(entryTitle: "Compat Update Target Updated", password: "updated-password"),
        ]
        table["attachments-update-entry"] = [
            .init(entryTitle: "Multi Attachment Entry Updated", password: "updated-multi-password"),
        ]
        table["group-tags-update-entry"] = [
            .init(entryTitle: "Beta Login Updated", password: "GroupTagBetaUpdated2"),
            .init(entryTitle: "Alpha Login", password: "GroupTagAlpha1"),
        ]
        return table
    }()

    /// Scenarios that deliberately carry no external protected-value check.
    /// Delete/hide scenarios move or remove entries without asserting a new
    /// password, and the KeeOTP artifact's external probe is deliberately a
    /// plain search (KeePassXC 2.7.12 skips its raw KeeOTP fields).
    static let scenarioIDsWithoutPasswordExpectations: Set<String> = [
        "create-group",
        "hide-group-from-autofill",
        "change-group-icon",
        "soft-delete-entry",
        "soft-delete-group",
        "hard-delete-recycled-entry",
        "hard-delete-recycled-group",
        "recycle-bin-creation",
        "attachments-soft-delete-entry",
        "keeotp-source-matrix",
    ]

    /// Fail-closed lookup: a scenario id listed in neither the expectation
    /// table nor the allowlist throws, failing the test that tried to emit it.
    static func expectedAttachments(forScenarioID scenarioID: String) throws -> [ArtifactManifest.ExpectedAttachment] {
        if let expectations = attachmentExpectations[scenarioID] {
            return expectations
        }
        guard scenarioIDsWithoutAttachmentExpectations.contains(scenarioID) else {
            throw ExpectationLookupError.unlistedScenario(kind: "attachment", scenarioID: scenarioID)
        }
        return []
    }

    /// Fail-closed lookup; see `expectedAttachments(forScenarioID:)`.
    static func expectedPasswords(forScenarioID scenarioID: String) throws -> [ArtifactManifest.ExpectedPassword] {
        if let expectations = passwordExpectations[scenarioID] {
            return expectations
        }
        guard scenarioIDsWithoutPasswordExpectations.contains(scenarioID) else {
            throw ExpectationLookupError.unlistedScenario(kind: "password", scenarioID: scenarioID)
        }
        return []
    }

    static func load(_ fixture: Fixture, bundle: Bundle, sessionKey: SymmetricKey = SymmetricKey(size: .bits256)) throws -> LoadedFixture {
        let keyFileData = try fixture.keyFileName.map { keyFileName in
            let keyURL = try TestDatabaseSupport.fixtureURL(
                named: keyFileName,
                extension: "key",
                subdirectory: "compatibility",
                bundle: bundle
            )
            return try Data(contentsOf: keyURL)
        }
        let compositeKey = KDBXCrypto.compositeKey(password: fixture.password, keyFileData: keyFileData)

        let sourceData: Data
        switch fixture.source {
        case .bundled(let name, let subdirectory):
            let databaseURL = try TestDatabaseSupport.fixtureURL(
                named: name,
                subdirectory: subdirectory,
                bundle: bundle
            )
            sourceData = try Data(contentsOf: databaseURL)
        case .generated(let cipherID, let hasRecycleBin):
            let generated = try makeSyntheticDatabase(
                cipherID: cipherID,
                hasRecycleBin: hasRecycleBin,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
            sourceData = generated.data
        }

        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: sourceData,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )

        return LoadedFixture(
            fixture: fixture,
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            header: parsed.header,
            compositeKey: compositeKey,
            sourceData: sourceData,
            sessionKey: sessionKey,
            keyFileData: keyFileData
        )
    }

    static func fullEditScenarios() -> [Scenario] {
        [
            createEntryScenario(),
            updateEntryScenario(),
            createGroupScenario(),
            hideGroupFromAutoFillScenario(),
            changeGroupIconScenario(),
            softDeleteEntryScenario(),
            softDeleteGroupScenario(),
            hardDeleteRecycledEntryScenario(),
            hardDeleteRecycledGroupScenario(),
        ]
    }

    static func recycleBinCreationScenario() -> Scenario {
        Scenario(
            id: "recycle-bin-creation",
            title: "Soft delete creates a recycle bin when missing",
            artifactFileName: "synthetic-no-recycle-bin-recycle-bin-creation.kdbx",
            expectedSearchTerms: ["Compat Soft Delete Target"],
            // The bin is created during this edit, so its name follows the
            // UI language (ecosystem-standard; see DatabaseDraft.localizedRecycleBinName).
            expectedGroupPaths: [DatabaseDraft.localizedRecycleBinName],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Soft Delete Target", in: loaded.rootGroup))
                return .deleteEntry(entryID: entry.id, sendToRecycleBin: true)
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Compat Soft Delete Target"))
                let rootGroupID = try XCTUnwrap(before.groupID(named: "Root"))
                try assertUnchangedEntries(before: before, after: after)
                try assertSurvivingGroupsPreserveScalars(before: before, after: after, excluding: [rootGroupID])
                XCTAssertNotNil(after.meta.recycleBinUUID)
                XCTAssertTrue(after.meta.hasRecycleBinUUIDElement)
                let recycleBinID = try XCTUnwrap(after.meta.recycleBinUUID)
                let recycleBinGroup = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertEqual(recycleBinGroup.name, DatabaseDraft.localizedRecycleBinName)
                XCTAssertTrue(recycleBinGroup.entryIDs.contains(entryID))
                XCTAssertEqual(after.entries.count, before.entries.count)
                XCTAssertEqual(after.groups.count, before.groups.count + 1)
            }
        )
    }

    static func changeGroupIconScenario() -> Scenario {
        Scenario(
            id: "change-group-icon",
            title: "Change a group's standard icon via IconID",
            artifactFileName: "synthetic-rich-change-group-icon.kdbx",
            expectedSearchTerms: ["Compat Untouched Entry"],
            expectedGroupPaths: ["Compat Group Delete Target"],
            makeEdit: { loaded in
                let group = try XCTUnwrap(
                    findGroup(named: "Compat Nested Child Group", in: loaded.rootGroup)
                )
                return .setGroupIcon(groupID: group.id, iconID: 37)
            },
            assertChange: { before, after, _ in
                let targetID = try XCTUnwrap(before.groupID(named: "Compat Nested Child Group"))
                let beforeGroup = try XCTUnwrap(before.groups[targetID])
                XCTAssertNotEqual(
                    beforeGroup.iconID,
                    37,
                    "Fixture precondition: the target group must not already use the chosen icon"
                )

                try assertUnchangedEntries(before: before, after: after)
                // Only the edited group may differ, and only in its icon plus its
                // modification time.
                try assertSurvivingGroupsPreserveScalars(
                    before: before,
                    after: after,
                    excluding: [targetID]
                )
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.groups.count, before.groups.count)

                let afterGroup = try XCTUnwrap(after.groups[targetID])
                XCTAssertEqual(afterGroup.iconID, 37)
                XCTAssertEqual(afterGroup.name, beforeGroup.name)
                XCTAssertEqual(afterGroup.searchingEnabled, beforeGroup.searchingEnabled)
                XCTAssertEqual(afterGroup.entryIDs, beforeGroup.entryIDs)
                XCTAssertEqual(afterGroup.groupIDs, beforeGroup.groupIDs)
                XCTAssertEqual(afterGroup.creationTime, beforeGroup.creationTime)
                // This group carries no custom icon, so nothing may be dropped from
                // its preserved XML. The removal path is covered by
                // `DatabaseDraftTests.test_setGroupIcon_clearsCustomIconSoTheStandardIconActuallyShows`.
                XCTAssertEqual(afterGroup.unknownXML, beforeGroup.unknownXML)
            }
        )
    }

    static func fixtureSmokeScenario(fixtureID: String) -> Scenario {
        let createdTitle = fixtureSmokeCreatedTitle(fixtureID: fixtureID)
        return Scenario(
            id: "fixture-smoke-\(fixtureID)",
            title: "Representative fixture write smoke",
            artifactFileName: "\(fixtureID)-fixture-smoke.kdbx",
            expectedSearchTerms: [createdTitle],
            expectedGroupPaths: [],
            makeEdit: { loaded in
                .createEntry(
                    parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: loaded.rootGroup),
                    draft: EntryDraftPayload(
                        title: createdTitle,
                        username: "compat-user",
                        password: fixtureSmokeCreatedPassword,
                        url: "https://compat.example.com",
                        notes: "External opener smoke entry"
                    )
                )
            },
            assertChange: { before, after, _ in
                try assertUnchangedEntries(before: before, after: after)
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.entries.count, before.entries.count + 1)
                XCTAssertNotNil(after.entryID(titled: createdTitle))
            }
        )
    }

    /// Update-entry scenario for the `attachments` fixture: edits the
    /// non-attachment fields of `Multi Attachment Entry` (which carries two
    /// attachments) and asserts its attachments and their resolved pool
    /// content hashes survive untouched.
    static func attachmentsFixtureUpdateEntryScenario() -> Scenario {
        Scenario(
            id: "attachments-update-entry",
            title: "Update entry preserves attachments",
            artifactFileName: "attachments-update-entry.kdbx",
            expectedSearchTerms: ["Multi Attachment Entry Updated"],
            expectedGroupPaths: [],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Multi Attachment Entry", in: loaded.rootGroup))
                return .updateEntry(
                    entryID: entry.id,
                    draft: EntryDraftPayload(
                        title: "Multi Attachment Entry Updated",
                        username: "updated-multi-user",
                        password: "updated-multi-password",
                        url: entry.url,
                        notes: entry.notes,
                        customFields: entry.customFields,
                        tags: entry.tags
                    )
                )
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Multi Attachment Entry"))
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)

                let original = try XCTUnwrap(before.entries[entryID])
                let updated = try XCTUnwrap(after.entries[entryID])
                XCTAssertEqual(updated.title, "Multi Attachment Entry Updated")
                XCTAssertEqual(updated.attachments, original.attachments)
                XCTAssertEqual(updated.attachmentHashes, original.attachmentHashes)
                XCTAssertEqual(Set(updated.attachments.map(\.name)), ["note-ü.txt", "pixel.png"])
                XCTAssertEqual(Set(updated.attachmentHashes.compactMap { $0 }), [
                    AttachmentFixtureHashes.noteUnicodeTxt,
                    AttachmentFixtureHashes.pixelPNG,
                ])
            }
        )
    }

    /// Soft-delete scenario for the `attachments` fixture: sends `Dedup
    /// Entry A` to the recycle bin (creating it, since the fixture starts
    /// without one) and asserts both dedup entries' shared attachment bytes
    /// remain resolvable and identical afterward.
    static func attachmentsFixtureSoftDeleteScenario() -> Scenario {
        Scenario(
            id: "attachments-soft-delete-entry",
            title: "Soft delete entry preserves sibling dedup attachment",
            artifactFileName: "attachments-soft-delete-entry.kdbx",
            expectedSearchTerms: ["Dedup Entry B"],
            // The attachments fixture has no recycle bin, so this edit creates
            // one with the UI-language name.
            expectedGroupPaths: [DatabaseDraft.localizedRecycleBinName],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Dedup Entry A", in: loaded.rootGroup))
                return .deleteEntry(entryID: entry.id, sendToRecycleBin: true)
            },
            assertChange: { before, after, _ in
                let deletedID = try XCTUnwrap(before.entryID(titled: "Dedup Entry A"))
                let survivingID = try XCTUnwrap(before.entryID(titled: "Dedup Entry B"))
                try assertUnchangedEntries(before: before, after: after, excluding: [deletedID])

                let deletedBefore = try XCTUnwrap(before.entries[deletedID])
                let deletedAfter = try XCTUnwrap(after.entries[deletedID])
                XCTAssertEqual(deletedAfter.attachments, deletedBefore.attachments)
                XCTAssertEqual(deletedAfter.attachmentHashes, deletedBefore.attachmentHashes)

                let survivor = try XCTUnwrap(after.entries[survivingID])
                XCTAssertEqual(survivor.attachments.map(\.name), ["shared.bin"])
                XCTAssertEqual(survivor.attachmentHashes, [AttachmentFixtureHashes.sharedBin])
                XCTAssertEqual(deletedAfter.attachmentHashes, [AttachmentFixtureHashes.sharedBin])

                let recycleBinID = try XCTUnwrap(after.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertTrue(recycleBin.entryIDs.contains(deletedID))
            }
        )
    }

    /// Update-entry scenario for the `group-tags` fixture: edits `Beta Login`
    /// (nested under both tagged groups) and asserts every group's tags and
    /// has-element flag survive the save untouched.
    ///
    /// External-proof limitation, stated deliberately: `keepassxc-cli` has no
    /// verb that prints a group's tags, so the gate's checks on this artifact
    /// are indirect — the rewritten database still opens, every listed group
    /// path still resolves (`Projects/Client Work` proves structure), and the
    /// search/password probes pass. The direct proof that every group tag
    /// survived is in-process: `assertSurvivingGroupsPreserveScalars` (whose
    /// `GroupScalars` carries `tags`/`hasTagsElement`) plus the explicit
    /// per-group assertions below and in
    /// `KDBXCompatibilityTests.test_groupTagsFixture_…`.
    static func groupTagsFixtureUpdateEntryScenario() -> Scenario {
        Scenario(
            id: "group-tags-update-entry",
            title: "Update entry preserves group tags",
            artifactFileName: "group-tags-update-entry.kdbx",
            expectedSearchTerms: ["Beta Login Updated"],
            expectedGroupPaths: ["Projects", "Projects/Client Work", "Empty Tags Group", "Plain Group"],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Beta Login", in: loaded.rootGroup))
                return .updateEntry(
                    entryID: entry.id,
                    draft: EntryDraftPayload(
                        title: "Beta Login Updated",
                        username: entry.username,
                        password: "GroupTagBetaUpdated2",
                        url: entry.url,
                        notes: entry.notes,
                        customFields: entry.customFields,
                        tags: entry.tags
                    )
                )
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Beta Login"))
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)

                let updated = try XCTUnwrap(after.entries[entryID])
                XCTAssertEqual(updated.title, "Beta Login Updated")
                XCTAssertEqual(updated.tags, ["own-tag"], "The entry's own tag rides through the edit")

                let projects = try XCTUnwrap(after.groups[XCTUnwrap(after.groupID(named: "Projects"))])
                XCTAssertEqual(projects.tags, ["team", "shared"])
                XCTAssertTrue(projects.hasTagsElement)
                XCTAssertTrue(
                    projects.unknownXML.nodes.contains { $0.xml.hasPrefix("<Notes>") },
                    "The group's opaque <Notes> sibling survives next to the structured <Tags>"
                )

                let clientWork = try XCTUnwrap(after.groups[XCTUnwrap(after.groupID(named: "Client Work"))])
                XCTAssertEqual(clientWork.tags, ["billable"])
                XCTAssertTrue(clientWork.hasTagsElement)

                let emptyTags = try XCTUnwrap(after.groups[XCTUnwrap(after.groupID(named: "Empty Tags Group"))])
                XCTAssertTrue(emptyTags.tags.isEmpty)
                XCTAssertTrue(emptyTags.hasTagsElement, "The empty <Tags></Tags> element survives the save")

                let plain = try XCTUnwrap(after.groups[XCTUnwrap(after.groupID(named: "Plain Group"))])
                XCTAssertTrue(plain.tags.isEmpty)
                XCTAssertFalse(plain.hasTagsElement, "A group that never had the element must not gain one")
            }
        )
    }

    // MARK: - Artifact set

    /// One `(fixture, scenario)` pair, i.e. exactly one `.kdbx` artifact for
    /// the external-opener gate.
    ///
    /// Descriptors carry no loaded database, so the coverage and expectation
    /// tests can enumerate the entire artifact set without paying any KDF
    /// cost. `KDBXCompatibilityTests` owns the executions: each scenario below
    /// is run by exactly one test method, which emits its bytes on the way
    /// past instead of re-running it later just to produce a file.
    struct ArtifactDescriptor {
        let fixture: Fixture
        let scenario: Scenario

        var id: String { "\(fixture.id)-\(scenario.id)" }
    }

    static var artifactDescriptors: [ArtifactDescriptor] {
        var descriptors = fullEditScenarios().map {
            ArtifactDescriptor(fixture: .syntheticRich, scenario: $0)
        }
        descriptors.append(
            ArtifactDescriptor(fixture: .syntheticNoRecycleBin, scenario: recycleBinCreationScenario())
        )
        descriptors.append(contentsOf: smokeFixtures.map {
            ArtifactDescriptor(fixture: $0, scenario: fixtureSmokeScenario(fixtureID: $0.id))
        })
        descriptors.append(
            ArtifactDescriptor(fixture: .attachments, scenario: fixtureSmokeScenario(fixtureID: Fixture.attachments.id))
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .attachments, scenario: attachmentsFixtureUpdateEntryScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .attachments, scenario: attachmentsFixtureSoftDeleteScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .groupTags, scenario: groupTagsFixtureUpdateEntryScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .syntheticRich, scenario: keeOTPArtifactScenario())
        )
        return descriptors
    }

    static var declaredArtifactIDs: Set<String> {
        Set(artifactDescriptors.map(\.id))
    }

    /// The synthetic rich fixture with one entry per KeeOTP source variant
    /// appended, as the KeeOTP artifact scenario expects to find it.
    static func loadKeeOTPArtifactFixture(bundle: Bundle) throws -> LoadedFixture {
        let loaded = try load(.syntheticRich, bundle: bundle)
        loaded.rootGroup.entries.append(contentsOf: try keeOTPCases.map {
            try makeKeeOTPEntry($0, sessionKey: loaded.sessionKey)
        })
        return loaded
    }

    static func keeOTPArtifactScenario() -> Scenario {
        Scenario(
            id: "keeotp-source-matrix",
            title: "KeeOTP source spelling and encoding matrix",
            artifactFileName: "synthetic-rich-keeotp-source-matrix.kdbx",
            // KeePassXC 2.7.12 skips entries whose raw KeeOTP field uses its
            // unsupported key/query format. The artifact still contains all
            // source variants; the external opener probe uses the
            // ordinary entry in this same database while the XCTest matrix
            // proves KeeOTP semantics.
            expectedSearchTerms: ["Compat Update Target"],
            expectedGroupPaths: [],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Update Target", in: loaded.rootGroup))
                return .updateEntry(
                    entryID: entry.id,
                    draft: EntryDraftPayload(
                        title: entry.title,
                        username: entry.username,
                        password: try entry.password.decrypt(using: loaded.sessionKey),
                        url: entry.url,
                        notes: "KeeOTP artifact matrix",
                        customFields: entry.customFields,
                        tags: entry.tags
                    )
                )
            },
            assertChange: { before, after, _ in
                for testCase in keeOTPCases {
                    let title = "KeeOTP \(testCase.fieldName) \(testCase.label)"
                    let entryID = try XCTUnwrap(before.entryID(titled: title))
                    XCTAssertEqual(after.entries[entryID], before.entries[entryID])
                }
            }
        )
    }

    private static func makeKeeOTPEntry(_ testCase: KeeOTPCase, sessionKey: SymmetricKey) throws -> KPEntry {
        let source = KeeOTPSource(fieldName: testCase.fieldName, rawQuery: testCase.rawQuery)
        return KPEntry(
            title: "KeeOTP \(testCase.fieldName) \(testCase.label)",
            password: try EncryptedValue.encrypt("password", using: sessionKey),
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt(testCase.secret, using: sessionKey),
                decodedSecret: try EncryptedValue.encrypt(testCase.decodedSecret, using: sessionKey),
                keeOTPSource: source
            ),
            otpURL: testCase.fieldName == "otp" ? testCase.rawQuery : nil,
            protectedStringKeys: ["Password"]
        )
    }

    // MARK: - Artifact emission

    enum ArtifactEmissionError: Error, CustomStringConvertible {
        case undeclaredArtifact(String)
        case duplicateArtifact(String)
        case nothingCollected(String)

        var description: String {
            switch self {
            case .undeclaredArtifact(let id):
                return "Artifact '\(id)' is not in KDBXCompatibilitySupport.artifactDescriptors; declare it there."
            case .duplicateArtifact(let id):
                return "Artifact '\(id)' was produced twice in one test method; each scenario must run exactly once."
            case .nothingCollected(let name):
                return "\(name) created an ArtifactCollector but emitted no artifacts."
            }
        }
    }

    /// Collects the compatibility artifacts produced by a single
    /// `KDBXCompatibilityTests` method and attaches them once, at the end.
    ///
    /// `run(_:on:)` *is* the scenario's one and only execution for the suite —
    /// the assertion-bearing `Scenario.apply` runs, and the bytes it produced
    /// are captured for `ci_scripts/run_kdbx_compatibility_gate.sh` on the way
    /// past. Nothing is re-run purely to emit artifacts, so the expensive
    /// Argon2 work happens once per scenario per suite run.
    final class ArtifactCollector {
        private let testCase: XCTestCase
        private let outputDirectory: URL
        private var artifacts: [ArtifactManifest.Artifact] = []
        private var attachedKeyFileNames: Set<String> = []
        private var collectedArtifactIDs: Set<String> = []
        private let declaredArtifactIDs: Set<String>

        init(testCase: XCTestCase) throws {
            self.testCase = testCase
            declaredArtifactIDs = KDBXCompatibilitySupport.declaredArtifactIDs
            outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("kdbx-compatibility-artifacts-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        /// Runs `scenario` against `loaded` (executing all of its compatibility
        /// assertions) and records the written database as a gate artifact.
        @discardableResult
        func run(_ scenario: Scenario, on loaded: LoadedFixture) throws -> ScenarioResult {
            let result = try scenario.apply(to: loaded)
            try record(scenario: scenario, loaded: loaded, written: result.written)
            return result
        }

        /// Writes the manifest fragment for everything collected so far.
        func emit() throws {
            guard !artifacts.isEmpty else {
                throw ArtifactEmissionError.nothingCollected(testCase.name)
            }

            let manifest = ArtifactManifest(
                expectedArtifactIDs: declaredArtifactIDs.sorted(),
                artifacts: artifacts
            )
            let fragmentName = "\(KDBXCompatibilitySupport.artifactManifestNamePrefix)-\(Self.slug(for: testCase)).json"
            let fragmentURL = outputDirectory.appendingPathComponent(fragmentName)
            try JSONEncoder.compatibilityManifest.encode(manifest).write(to: fragmentURL, options: .atomic)
            attach(fragmentURL, named: fragmentName)
        }

        private func record(scenario: Scenario, loaded: LoadedFixture, written: Data) throws {
            let artifactID = "\(loaded.fixture.id)-\(scenario.id)"
            guard declaredArtifactIDs.contains(artifactID) else {
                throw ArtifactEmissionError.undeclaredArtifact(artifactID)
            }
            guard collectedArtifactIDs.insert(artifactID).inserted else {
                throw ArtifactEmissionError.duplicateArtifact(artifactID)
            }

            let artifactURL = outputDirectory.appendingPathComponent(scenario.artifactFileName)
            try written.write(to: artifactURL, options: .atomic)
            attach(artifactURL, named: scenario.artifactFileName)

            var keyFileAttachmentName: String?
            if let keyFileData = loaded.keyFileData, let fixtureKeyFileName = loaded.fixture.keyFileName {
                let name = "\(fixtureKeyFileName).key"
                keyFileAttachmentName = name
                if attachedKeyFileNames.insert(name).inserted {
                    let keyFileURL = outputDirectory.appendingPathComponent(name)
                    try keyFileData.write(to: keyFileURL, options: .atomic)
                    attach(keyFileURL, named: name)
                }
            }

            artifacts.append(
                ArtifactManifest.Artifact(
                    id: artifactID,
                    fileName: scenario.artifactFileName,
                    password: loaded.fixture.password,
                    keyFileName: keyFileAttachmentName,
                    expectedSearchTerms: scenario.expectedSearchTerms,
                    expectedGroupPaths: scenario.expectedGroupPaths,
                    expectedAttachments: try KDBXCompatibilitySupport.expectedAttachments(forScenarioID: scenario.id),
                    expectedPasswords: try KDBXCompatibilitySupport.expectedPasswords(forScenarioID: scenario.id)
                )
            )
        }

        private func attach(_ url: URL, named name: String) {
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = name
            attachment.lifetime = .keepAlways
            testCase.add(attachment)
        }

        /// File-name-safe fragment of the test's name, so each method's
        /// manifest fragment is distinguishable in the exported attachments.
        private static func slug(for testCase: XCTestCase) -> String {
            let sanitized = testCase.name.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
            }
            return String(sanitized).split(separator: "-").joined(separator: "-")
        }
    }

    static func assertLegacyFixtureIsReadOnly(bundle: Bundle) throws {
        let loaded = try load(.legacyKDBX31, bundle: bundle)
        XCTAssertEqual(loaded.header.formatVersion, .kdbx3_1)
        XCTAssertTrue(loaded.header.formatVersion.requiresReadOnlyMode)
        XCTAssertThrowsError(
            try KDBXWriter.write(
                rootGroup: loaded.rootGroup,
                meta: loaded.meta,
                compositeKey: loaded.compositeKey,
                header: loaded.header,
                sessionKey: loaded.sessionKey
            )
        ) { error in
            guard case KDBXWriter.WriteError.unsupportedSourceFormat(.kdbx3_1) = error else {
                XCTFail("Expected KDBX 3.1 writer rejection, got \(error)")
                return
            }
        }
    }

    /// Fast Argon2id KDF parameters for tests that need a real, decryptable
    /// KDBX write/parse round trip but don't care about KDF cost. Kept in
    /// this internal (not `private extension`-scoped) section so other test
    /// files — e.g. AttachmentTests.swift — can reuse it instead of
    /// redeclaring their own copy.
    static func fastArgon2idParameters() throws -> [String: Any] {
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

struct CompatibilitySnapshot {
    struct Entry: Equatable {
        let id: UUID
        let title: String
        let username: String
        let password: String
        let url: String
        let notes: String
        let iconID: Int
        let tags: [String]
        let hasTagsElement: Bool
        let customFields: [String: String]
        /// Decrypted passkey private key PEM diverted out of customFields
        /// (`KPEntry.passkeyPrivateKey`), so drops or corruption of the
        /// sealed key are caught by snapshot equality.
        let passkeyPrivateKeyPEM: String?
        let totp: TOTP?
        let otpURL: String?
        let creationTime: Date?
        let lastModificationTime: Date?
        var history: [Entry]
        let unknownXML: OpaqueXMLNodes
        let protectedStringKeys: Set<String>
        let attachments: [KPAttachment]
        /// SHA-256 hex digest of each attachment's resolved pool bytes, in
        /// the same order as `attachments`. `nil` for a dangling ref (no
        /// pool entry at that index) so a missing binary doesn't silently
        /// compare equal to another missing binary with a different ref.
        let attachmentHashes: [String?]
    }

    struct TOTP: Equatable {
        let secret: String
        let period: Int
        let digits: Int
        let algorithm: TOTPAlgorithm
    }

    struct Group: Equatable {
        let id: UUID
        let name: String
        let iconID: Int
        let tags: [String]
        let hasTagsElement: Bool
        let isExpanded: Bool
        let searchingEnabled: KPInheritableBool?
        let creationTime: Date?
        let lastModificationTime: Date?
        let recycleBinUUID: UUID?
        let unknownXML: OpaqueXMLNodes
        let entryIDs: [UUID]
        let groupIDs: [UUID]

        var scalars: GroupScalars {
            GroupScalars(
                id: id,
                name: name,
                iconID: iconID,
                tags: tags,
                hasTagsElement: hasTagsElement,
                isExpanded: isExpanded,
                searchingEnabled: searchingEnabled,
                creationTime: creationTime,
                lastModificationTime: lastModificationTime,
                recycleBinUUID: recycleBinUUID,
                unknownXML: unknownXML
            )
        }
    }

    struct GroupScalars: Equatable {
        let id: UUID
        let name: String
        let iconID: Int
        /// Covered here so an unrelated edit cannot silently drop, reorder,
        /// or invent a group's KDBX 4.1 `<Tags>` (read-only in KeeForge)
        /// without a compatibility scenario failing.
        let tags: [String]
        let hasTagsElement: Bool
        let isExpanded: Bool
        /// Covered here so an unrelated edit cannot silently drop or flip a
        /// group's `<EnableSearching>` without a compatibility scenario failing.
        let searchingEnabled: KPInheritableBool?
        let creationTime: Date?
        let lastModificationTime: Date?
        let recycleBinUUID: UUID?
        let unknownXML: OpaqueXMLNodes
    }

    let entries: [UUID: Entry]
    let groups: [UUID: Group]
    let meta: KPMeta
    /// Ordered digest over the *entire* inner-header binary pool, including
    /// entries no `<Binary>` element references.
    ///
    /// `Entry.attachmentHashes` only covers referenced binaries, so on its own
    /// it cannot see an orphaned pool entry being dropped, the pool being
    /// reordered or renumbered, or a protection flag flipping on an
    /// unreferenced binary. This folds each pool slot's index, protection flag,
    /// and content hash into one value instead. `nil` only when the snapshot
    /// was built without a pool.
    let binaryPoolDigest: String?

    init(rootGroup: KPGroup, meta: KPMeta, sessionKey: SymmetricKey, binaryPool: BinaryPool? = nil) throws {
        var entries: [UUID: Entry] = [:]
        var groups: [UUID: Group] = [:]
        try Self.capture(group: rootGroup, sessionKey: sessionKey, binaryPool: binaryPool, entries: &entries, groups: &groups)
        self.entries = entries
        self.groups = groups
        self.meta = meta
        self.binaryPoolDigest = Self.digest(of: binaryPool)
    }

    private static func digest(of binaryPool: BinaryPool?) -> String? {
        guard let binaryPool else { return nil }

        var hasher = SHA256()
        hasher.update(data: Data("count=\(binaryPool.count)".utf8))
        for index in 0..<binaryPool.count {
            guard let item = binaryPool[index] else { continue }
            hasher.update(data: Data("|\(index):\(item.isProtected ? 1 : 0):".utf8))
            hasher.update(data: Data(SHA256.hash(data: item.data)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func entryID(titled title: String) -> UUID? {
        entries.first { $0.value.title == title }?.key
    }

    func groupID(named name: String) -> UUID? {
        groups.first { $0.value.name == name }?.key
    }

    private static func capture(
        group: KPGroup,
        sessionKey: SymmetricKey,
        binaryPool: BinaryPool?,
        entries: inout [UUID: Entry],
        groups: inout [UUID: Group]
    ) throws {
        let capturedGroup = Group(
            id: group.id,
            name: group.name,
            iconID: group.iconID,
            tags: group.tags,
            hasTagsElement: group.hasTagsElement,
            isExpanded: group.isExpanded,
            searchingEnabled: group.searchingEnabled,
            creationTime: group.creationTime,
            lastModificationTime: group.lastModificationTime,
            recycleBinUUID: group.recycleBinUUID,
            unknownXML: group.unknownXML,
            entryIDs: group.entries.map(\.id),
            groupIDs: group.groups.map(\.id)
        )
        groups[group.id] = capturedGroup

        for entry in group.entries {
            entries[entry.id] = try capture(entry: entry, sessionKey: sessionKey, binaryPool: binaryPool)
        }

        for child in group.groups {
            try capture(group: child, sessionKey: sessionKey, binaryPool: binaryPool, entries: &entries, groups: &groups)
        }
    }

    private static func attachmentHashes(for attachments: [KPAttachment], binaryPool: BinaryPool?) -> [String?] {
        attachments.map { attachment in
            guard let binaryPool, let item = binaryPool[attachment.ref] else { return nil }
            let digest = SHA256.hash(data: item.data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func capture(entry: KPEntry, sessionKey: SymmetricKey, binaryPool: BinaryPool?) throws -> Entry {
        let capturedTOTP: TOTP?
        if let totp = entry.totpConfig {
            capturedTOTP = TOTP(
                secret: try totp.secret.decrypt(using: sessionKey),
                period: totp.period,
                digits: totp.digits,
                algorithm: totp.algorithm
            )
        } else {
            capturedTOTP = nil
        }

        return Entry(
            id: entry.id,
            title: entry.title,
            username: entry.username,
            password: try entry.password.decrypt(using: sessionKey),
            url: entry.url,
            notes: entry.notes,
            iconID: entry.iconID,
            tags: entry.tags,
            hasTagsElement: entry.hasTagsElement,
            customFields: entry.customFields,
            passkeyPrivateKeyPEM: try entry.passkeyPrivateKey.map { try $0.decrypt(using: sessionKey) },
            totp: capturedTOTP,
            otpURL: entry.otpURL,
            creationTime: entry.creationTime,
            lastModificationTime: entry.lastModificationTime,
            history: try entry.history.map { try capture(entry: $0, sessionKey: sessionKey, binaryPool: binaryPool) },
            unknownXML: entry.unknownXML,
            protectedStringKeys: entry.protectedStringKeys,
            attachments: entry.attachments,
            attachmentHashes: attachmentHashes(for: entry.attachments, binaryPool: binaryPool)
        )
    }
}

private extension KDBXCompatibilitySupport {
    static func createEntryScenario() -> Scenario {
        Scenario(
            id: "create-entry",
            title: "Create entry with rich editable fields",
            artifactFileName: "synthetic-rich-create-entry.kdbx",
            expectedSearchTerms: ["Compat Created Entry"],
            expectedGroupPaths: [],
            makeEdit: { loaded in
                .createEntry(
                    parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: loaded.rootGroup),
                    draft: EntryDraftPayload(
                        title: "Compat Created Entry",
                        username: "created-user",
                        password: "created-secret",
                        url: "https://created.example.com/login",
                        notes: "Created through compatibility matrix",
                        customFields: [
                            "CustomKey": "CustomValue",
                            PasskeyCredential.credentialIDKey: "created-passkey-id",
                            PasskeyCredential.relyingPartyKey: "created.example.com",
                            PasskeyCredential.usernameKey: "created-passkey-user",
                            PasskeyCredential.userHandleKey: "created-user-handle",
                            PasskeyCredential.privateKeyPEMKey: "created-private-key",
                        ],
                        tags: ["compat", "created"],
                        totpConfig: .init(secret: "JBSWY3DPEHPK3PXP", period: 45, digits: 8, algorithm: .sha256)
                    )
                )
            },
            assertChange: { before, after, _ in
                try assertUnchangedEntries(before: before, after: after)
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.entries.count, before.entries.count + 1)
                let createdID = try XCTUnwrap(after.entryID(titled: "Compat Created Entry"))
                let created = try XCTUnwrap(after.entries[createdID])
                XCTAssertEqual(created.username, "created-user")
                XCTAssertEqual(created.password, "created-secret")
                // The PEM supplied via the draft's custom fields is diverted
                // into the sealed passkeyPrivateKey and never stays in
                // customFields.
                XCTAssertNil(created.customFields[PasskeyCredential.privateKeyPEMKey])
                XCTAssertEqual(created.passkeyPrivateKeyPEM, "created-private-key")
                XCTAssertEqual(created.totp?.secret, "JBSWY3DPEHPK3PXP")
            }
        )
    }

    static func updateEntryScenario() -> Scenario {
        Scenario(
            id: "update-entry",
            title: "Update entry preserves rich non-edited data",
            artifactFileName: "synthetic-rich-update-entry.kdbx",
            expectedSearchTerms: ["Compat Update Target Updated"],
            expectedGroupPaths: [],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Update Target", in: loaded.rootGroup))
                return .updateEntry(
                    entryID: entry.id,
                    draft: EntryDraftPayload(
                        title: "Compat Update Target Updated",
                        username: "updated-user",
                        password: "updated-password",
                        url: "https://updated.example.com",
                        notes: "Updated through compatibility matrix",
                        customFields: entry.customFields,
                        tags: entry.tags + ["updated"],
                        totpConfig: .init(secret: "JBSWY3DPEHPK3PXP", period: 30, digits: 6, algorithm: .sha1),
                        lastModificationTime: entry.lastModificationTime
                    )
                )
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Compat Update Target"))
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)

                let original = try XCTUnwrap(before.entries[entryID])
                let updated = try XCTUnwrap(after.entries[entryID])
                XCTAssertEqual(updated.title, "Compat Update Target Updated")
                XCTAssertEqual(updated.username, "updated-user")
                XCTAssertEqual(updated.password, "updated-password")
                XCTAssertNil(updated.customFields[PasskeyCredential.privateKeyPEMKey])
                XCTAssertEqual(updated.passkeyPrivateKeyPEM, original.passkeyPrivateKeyPEM)
                XCTAssertNotNil(updated.passkeyPrivateKeyPEM)
                XCTAssertTrue(updated.protectedStringKeys.contains(PasskeyCredential.privateKeyPEMKey))
                XCTAssertEqual(updated.unknownXML, original.unknownXML)
                XCTAssertEqual(updated.history.count, original.history.count + 1)
                var expectedHistory = original
                expectedHistory.history = []
                XCTAssertEqual(updated.history.first, expectedHistory)
            }
        )
    }

    static func createGroupScenario() -> Scenario {
        Scenario(
            id: "create-group",
            title: "Create group",
            artifactFileName: "synthetic-rich-create-group.kdbx",
            expectedSearchTerms: ["Compat Untouched Entry"],
            expectedGroupPaths: ["Compat Created Group"],
            makeEdit: { loaded in
                .createGroup(
                    parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: loaded.rootGroup),
                    name: "Compat Created Group"
                )
            },
            assertChange: { before, after, _ in
                try assertUnchangedEntries(before: before, after: after)
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.groups.count, before.groups.count + 1)
                let createdID = try XCTUnwrap(after.groupID(named: "Compat Created Group"))
                let created = try XCTUnwrap(after.groups[createdID])
                XCTAssertTrue(created.entryIDs.isEmpty)
                XCTAssertTrue(created.groupIDs.isEmpty)
            }
        )
    }

    /// Hiding a group from AutoFill writes `<EnableSearching>False</EnableSearching>`
    /// into a group that previously had no such element. The artifact proves the
    /// result still opens in KeePassXC and that the surrounding tree is untouched;
    /// `expectedSearchTerms` deliberately names an entry *outside* the hidden
    /// group, because a KeePass-family client is entitled to skip the hidden one.
    static func hideGroupFromAutoFillScenario() -> Scenario {
        Scenario(
            id: "hide-group-from-autofill",
            title: "Hide group from AutoFill via EnableSearching",
            artifactFileName: "synthetic-rich-hide-group-from-autofill.kdbx",
            expectedSearchTerms: ["Compat Untouched Entry"],
            expectedGroupPaths: ["Compat Group Delete Target"],
            makeEdit: { loaded in
                let group = try XCTUnwrap(
                    findGroup(named: "Compat Nested Child Group", in: loaded.rootGroup)
                )
                return .setGroupSearchingEnabled(groupID: group.id, value: .disabled)
            },
            assertChange: { before, after, _ in
                let targetID = try XCTUnwrap(before.groupID(named: "Compat Nested Child Group"))
                let beforeGroup = try XCTUnwrap(before.groups[targetID])
                XCTAssertNil(
                    beforeGroup.searchingEnabled,
                    "Fixture precondition: the target group starts without the element"
                )

                try assertUnchangedEntries(before: before, after: after)
                // Only the edited group may differ, and only in this flag plus
                // its modification time.
                try assertSurvivingGroupsPreserveScalars(
                    before: before,
                    after: after,
                    excluding: [targetID]
                )
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.groups.count, before.groups.count)

                let afterGroup = try XCTUnwrap(after.groups[targetID])
                XCTAssertEqual(afterGroup.searchingEnabled, .disabled)
                XCTAssertEqual(afterGroup.name, beforeGroup.name)
                XCTAssertEqual(afterGroup.iconID, beforeGroup.iconID)
                XCTAssertEqual(afterGroup.entryIDs, beforeGroup.entryIDs)
                XCTAssertEqual(afterGroup.groupIDs, beforeGroup.groupIDs)
                XCTAssertEqual(afterGroup.unknownXML, beforeGroup.unknownXML)
                XCTAssertEqual(afterGroup.creationTime, beforeGroup.creationTime)
            }
        )
    }

    static func softDeleteEntryScenario() -> Scenario {
        Scenario(
            id: "soft-delete-entry",
            title: "Soft delete entry to existing recycle bin",
            artifactFileName: "synthetic-rich-soft-delete-entry.kdbx",
            expectedSearchTerms: ["Compat Soft Delete Target"],
            expectedGroupPaths: ["Recycle Bin"],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Soft Delete Target", in: loaded.rootGroup))
                return .deleteEntry(entryID: entry.id, sendToRecycleBin: true)
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Compat Soft Delete Target"))
                try assertUnchangedEntries(before: before, after: after)
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                let recycleBinID = try XCTUnwrap(before.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertTrue(recycleBin.entryIDs.contains(entryID))
                XCTAssertEqual(after.entries.count, before.entries.count)
            }
        )
    }

    static func hardDeleteRecycledEntryScenario() -> Scenario {
        Scenario(
            id: "hard-delete-recycled-entry",
            title: "Hard delete entry from recycle bin creates tombstone",
            artifactFileName: "synthetic-rich-hard-delete-recycled-entry.kdbx",
            expectedSearchTerms: ["Compat Untouched Entry"],
            expectedGroupPaths: ["Recycle Bin"],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Recycled Entry", in: loaded.rootGroup))
                return .deleteEntry(entryID: entry.id, sendToRecycleBin: false)
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Compat Recycled Entry"))
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                XCTAssertNil(after.entries[entryID])
                XCTAssertEqual(after.entries.count, before.entries.count - 1)
                XCTAssertEqual(after.meta.recycleBinUUID, before.meta.recycleBinUUID)
                XCTAssertTrue(after.meta.deletedObjects.contains { $0.uuid == entryID })
                let recycleBinID = try XCTUnwrap(before.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertFalse(recycleBin.entryIDs.contains(entryID))
            }
        )
    }

    static func softDeleteGroupScenario() -> Scenario {
        Scenario(
            id: "soft-delete-group",
            title: "Soft delete group to recycle bin",
            artifactFileName: "synthetic-rich-soft-delete-group.kdbx",
            expectedSearchTerms: ["Compat Nested Entry"],
            expectedGroupPaths: ["Recycle Bin/Compat Group Delete Target"],
            makeEdit: { loaded in
                let group = try XCTUnwrap(findGroup(named: "Compat Group Delete Target", in: loaded.rootGroup))
                return .deleteGroup(groupID: group.id, sendToRecycleBin: true)
            },
            assertChange: { before, after, _ in
                let groupID = try XCTUnwrap(before.groupID(named: "Compat Group Delete Target"))
                try assertUnchangedEntries(before: before, after: after)
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                let recycleBinID = try XCTUnwrap(before.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertTrue(recycleBin.groupIDs.contains(groupID))
                XCTAssertEqual(after.groups.count, before.groups.count)
            }
        )
    }

    static func hardDeleteRecycledGroupScenario() -> Scenario {
        Scenario(
            id: "hard-delete-recycled-group",
            title: "Hard delete group from recycle bin creates subtree tombstones",
            artifactFileName: "synthetic-rich-hard-delete-recycled-group.kdbx",
            expectedSearchTerms: ["Compat Untouched Entry"],
            expectedGroupPaths: ["Recycle Bin"],
            makeEdit: { loaded in
                let group = try XCTUnwrap(findGroup(named: "Compat Recycled Group Delete Target", in: loaded.rootGroup))
                return .deleteGroup(groupID: group.id, sendToRecycleBin: false)
            },
            assertChange: { before, after, _ in
                let groupID = try XCTUnwrap(before.groupID(named: "Compat Recycled Group Delete Target"))
                let childGroupID = try XCTUnwrap(before.groupID(named: "Compat Recycled Nested Child Group"))
                let nestedEntryID = try XCTUnwrap(before.entryID(titled: "Compat Recycled Nested Entry"))
                let deletedIDs: Set<UUID> = [groupID, childGroupID, nestedEntryID]
                try assertUnchangedEntries(before: before, after: after, excluding: [nestedEntryID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after, excluding: [groupID, childGroupID])
                XCTAssertNil(after.groups[groupID])
                XCTAssertNil(after.groups[childGroupID])
                XCTAssertNil(after.entries[nestedEntryID])
                XCTAssertTrue(deletedIDs.isSubset(of: Set(after.meta.deletedObjects.map(\.uuid))))
                let recycleBinID = try XCTUnwrap(before.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertFalse(recycleBin.groupIDs.contains(groupID))
            }
        )
    }

    static func makeSyntheticDatabase(
        cipherID: Data,
        hasRecycleBin: Bool,
        compositeKey: Data,
        sessionKey: SymmetricKey
    ) throws -> (data: Data, rootGroup: KPGroup, meta: KPMeta) {
        let recycleBinID = hasRecycleBin ? UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000043")! : nil
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let updateTarget = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000101")!,
            title: "Compat Update Target",
            username: "update-user",
            password: try EncryptedValue.encrypt("original-password", using: sessionKey),
            url: "https://update.example.com",
            notes: "Original note",
            tags: ["compat"],
            customFields: [
                "Secret Custom": "custom-secret",
                PasskeyCredential.credentialIDKey: "credential-id",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "passkey-user",
                PasskeyCredential.userHandleKey: "user-handle",
                PasskeyCredential.privateKeyPEMKey: "private-key-pem",
            ],
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            ),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            unknownXML: OpaqueXMLNodes(nodes: [
                OpaqueXMLNodes.Node(
                    insertionIndex: 9,
                    xml: "<CustomData><Item><Key>CompatUnknown</Key><Value>PreserveMe</Value></Item></CustomData>"
                ),
            ]),
            protectedStringKeys: ["Secret Custom", PasskeyCredential.privateKeyPEMKey]
        )

        let softDeleteTarget = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000102")!,
            title: "Compat Soft Delete Target",
            username: "soft-user",
            password: try EncryptedValue.encrypt("soft-password", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let untouchedEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000104")!,
            title: "Compat Untouched Entry",
            username: "untouched-user",
            password: try EncryptedValue.encrypt("untouched-password", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let emptyTagsEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000105")!,
            title: "Compat Empty Tags",
            password: try EncryptedValue.encrypt("empty-tags-password", using: sessionKey),
            hasTagsElement: true,
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let otpURI = "otpauth://totp/Compat:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Compat&period=30&digits=6&algorithm=SHA1"
        let otpEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000106")!,
            title: "Compat OTP URI",
            password: try EncryptedValue.encrypt("otp-password", using: sessionKey),
            totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)),
            otpURL: otpURI,
            creationTime: timestamp,
            lastModificationTime: timestamp,
            protectedStringKeys: ["otp"]
        )

        let nestedEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000107")!,
            title: "Compat Nested Entry",
            password: try EncryptedValue.encrypt("nested-password", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let nestedChildGroup = KPGroup(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000302")!,
            name: "Compat Nested Child Group",
            entries: [nestedEntry],
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let deleteTargetGroup = KPGroup(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000301")!,
            name: "Compat Group Delete Target",
            groups: [nestedChildGroup],
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let recycledEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000108")!,
            title: "Compat Recycled Entry",
            username: "recycled-user",
            password: try EncryptedValue.encrypt("recycled-password", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let recycledNestedEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000109")!,
            title: "Compat Recycled Nested Entry",
            password: try EncryptedValue.encrypt("recycled-nested-password", using: sessionKey),
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let recycledNestedChildGroup = KPGroup(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000304")!,
            name: "Compat Recycled Nested Child Group",
            entries: [recycledNestedEntry],
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let recycledDeleteTargetGroup = KPGroup(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000303")!,
            name: "Compat Recycled Group Delete Target",
            groups: [recycledNestedChildGroup],
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let recycleBinGroup = recycleBinID.map {
            KPGroup(
                id: $0,
                name: "Recycle Bin",
                iconID: 43,
                entries: [recycledEntry],
                groups: [recycledDeleteTargetGroup],
                creationTime: timestamp,
                lastModificationTime: timestamp
            )
        }

        var visibleGroups = [deleteTargetGroup]
        if let recycleBinGroup {
            visibleGroups.append(recycleBinGroup)
        }

        let visibleRoot = KPGroup(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000201")!,
            name: "Compatibility Root",
            entries: [updateTarget, softDeleteTarget, untouchedEntry, emptyTagsEntry, otpEntry],
            groups: visibleGroups,
            creationTime: timestamp,
            lastModificationTime: timestamp
        )

        let root = KPGroup(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000200")!,
            name: "Root",
            groups: [visibleRoot],
            creationTime: timestamp,
            lastModificationTime: timestamp,
            recycleBinUUID: recycleBinID
        )

        let meta = KPMeta(
            recycleBinUUID: recycleBinID,
            hasRecycleBinUUIDElement: recycleBinID != nil,
            maintenanceHistoryDays: KPMeta.defaultMaintenanceHistoryDays,
            historyMaxItems: KPMeta.defaultHistoryMaxItems,
            historyMaxSize: KPMeta.defaultHistoryMaxSize
        )

        let data = try KDBXWriter.write(
            rootGroup: root,
            meta: meta,
            compositeKey: compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: cipherID,
                kdfParameters: fastArgon2idParameters()
            ),
            sessionKey: sessionKey
        )

        return (data, root, meta)
    }

    static func findEntry(titled title: String, in group: KPGroup) -> KPEntry? {
        if let entry = group.entries.first(where: { $0.title == title }) {
            return entry
        }

        for childGroup in group.groups {
            if let entry = findEntry(titled: title, in: childGroup) {
                return entry
            }
        }

        return nil
    }

    static func findGroup(named name: String, in group: KPGroup) -> KPGroup? {
        if group.name == name {
            return group
        }

        for childGroup in group.groups {
            if let match = findGroup(named: name, in: childGroup) {
                return match
            }
        }

        return nil
    }

    static func assertUnchangedEntries(
        before: CompatibilitySnapshot,
        after: CompatibilitySnapshot,
        excluding excludedIDs: Set<UUID> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (entryID, beforeEntry) in before.entries where !excludedIDs.contains(entryID) {
            let afterEntry = try XCTUnwrap(after.entries[entryID], "Missing unchanged entry \(beforeEntry.title)", file: file, line: line)
            XCTAssertEqual(afterEntry, beforeEntry, "Entry changed unexpectedly: \(beforeEntry.title)", file: file, line: line)
        }
    }

    static func assertSurvivingGroupsPreserveScalars(
        before: CompatibilitySnapshot,
        after: CompatibilitySnapshot,
        excluding excludedIDs: Set<UUID> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (groupID, beforeGroup) in before.groups where !excludedIDs.contains(groupID) {
            guard let afterGroup = after.groups[groupID] else {
                continue
            }
            XCTAssertEqual(afterGroup.scalars, beforeGroup.scalars, "Group scalar changed unexpectedly: \(beforeGroup.name)", file: file, line: line)
        }
    }

    /// Asserts the whole inner-header binary pool survived the save byte-for-byte,
    /// including entries nothing references. Complements — never replaces — the
    /// per-attachment `Entry.attachmentHashes` comparisons in `assertUnchangedEntries`.
    static func assertBinaryPoolUnchanged(
        before: CompatibilitySnapshot,
        after: CompatibilitySnapshot,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(before.binaryPoolDigest, "\(scenarioID): before-snapshot has no binary pool", file: file, line: line)
        XCTAssertNotNil(after.binaryPoolDigest, "\(scenarioID): after-snapshot has no binary pool", file: file, line: line)
        XCTAssertEqual(
            after.binaryPoolDigest,
            before.binaryPoolDigest,
            "\(scenarioID): inner-header binary pool changed across save",
            file: file,
            line: line
        )
    }

    static func assertMetaUnchanged(
        before: CompatibilitySnapshot,
        after: CompatibilitySnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.meta, before.meta, file: file, line: line)
    }
}

private extension JSONEncoder {
    /// Stable encoding for the manifest fragments, so a fragment that is
    /// exported twice (xcresulttool name mangling) merges cleanly instead of
    /// looking like conflicting content to the gate.
    static var compatibilityManifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
