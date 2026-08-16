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

    /// Recorded SHA-256 hashes for the attachments in
    /// `TestFixtures/kitchen-sink.kdbx`, pinned in
    /// `TestFixtures/generators/kitchen_sink.py` and re-verified there through
    /// `keepassxc-cli attachment-export` (see `TestFixtures/README.md`).
    enum AttachmentFixtureHashes {
        static let noteUnicodeTxt = "bcc1c6cd101bd5b27356a7004361fd1e1ff74ed2ef416e3252997d328efd3727"
        static let pixelPNG = "3ec322a42990a3067cc6c73f3856a86e55bdd8baf19d2166954a8fb319329a72"
        static let sharedBin = "fd184a4f05cf3d4f39ab726bda3d3a923da30e9ab2d6697b69c2d39d7ea1ab18"
        /// The `Round Trip` entry's attachment, referenced by its current
        /// version and by its stored history version.
        static let roundTripTxt = "22e06efe984efab5605bccf1c0c1e208db740e16cac328dcbfa27cecee8458db"
    }

    /// SHA-256 hashes of the two attachments in
    /// `TestFixtures/compatibility/unknown-inner-header.kdbx`. Its binary pool
    /// is what the spliced unknown inner-header fields sit among, so the gate
    /// exporting these proves the pool survived the rewrite that normalized
    /// those fields.
    enum UnknownInnerHeaderFixtureHashes {
        static let alphaAttachmentTxt = "2e1e53db7251ba3852ea965523b8ff3ab8b7426adf50277d0d8d41d40630bdfd"
        static let betaAttachmentTxt = "ee48b95cd61f6f910959979dc94199de8012611f0050e85c5d7cd15e3d95d4b0"
    }

    struct Fixture {
        enum Source {
            case bundled(name: String, subdirectory: String? = "compatibility")
            case generated(cipherID: Data, hasRecycleBin: Bool)
        }

        /// Artifact ID consumed by the gate's manifests and by the allow-lists
        /// in `KDBXCompatibilityTests`; deliberately independent of the
        /// bundled resource a fixture reads, so a fixture can share a file
        /// with the unit-test suites without renaming its coverage.
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
            source: .bundled(name: "test", subdirectory: nil)
        )

        static let passwordKeyfile = Fixture(
            id: "password-keyfile",
            displayName: "Password plus key file fixture",
            password: "demo",
            keyFileName: "demo-keyfile",
            source: .bundled(name: "demo-keyfile", subdirectory: nil)
        )

        static let legacyKDBX31 = Fixture(
            id: "legacy-kdbx31",
            displayName: "Legacy KDBX 3.1 fixture",
            password: "testpassword123",
            keyFileName: nil,
            source: .bundled(name: "legacy-kdbx31")
        )

        /// Foreign-authored (pykeepass) KDBX 4.1 fixture that carries, in one
        /// file, everything the narrow per-feature fixtures used to own: a
        /// three-item binary pool (including a dedup pair two entries share and
        /// a non-ASCII filename), group `<Tags>` in all three states —
        /// content (`Projects`, nested `Client Work`), an empty element
        /// (`Empty Tags Group`), no element at all (`Plain Group`) — a group
        /// `<Notes>` sitting next to one of them, entry tags, a
        /// `Meta/CustomIcons` image, a protected custom field that also lives
        /// in history, a TOTP entry, and a populated `Recycle Bin` with
        /// `Meta/RecycleBinUUID` set. It also carries the whole opaque-XML
        /// corpus: a `PublicCustomData` (id 0x0C) outer-header field KeeForge
        /// does not model, a `Round Trip` entry whose `<AutoType>` and
        /// `<CustomData>` sit in deliberately awkward positions and whose
        /// attachment is referenced from its history version too, and a
        /// schema-invalid second `Meta/CustomData` sibling. See
        /// `TestFixtures/generators/kitchen_sink.py` and
        /// `TestFixtures/README.md`.
        ///
        /// It lives at the `TestFixtures/` root rather than in
        /// `compatibility/`, because the UI suites bundle it too.
        static let kitchenSink = Fixture(
            id: "kitchen-sink",
            displayName: "Kitchen-sink content fixture",
            password: "testpassword123",
            keyFileName: nil,
            source: .bundled(name: "kitchen-sink", subdirectory: nil)
        )

        /// Foreign-authored (pykeepass) KDBX4 fixture with the ChaCha20 outer
        /// cipher. Every other bundled fixture is AES-256-CBC authored by
        /// pykeepass or KeeForge itself, so this and `foreignTwofish` are the
        /// only fixtures that prove KeeForge's ChaCha20/Twofish outer-cipher
        /// READ paths against a database KeeForge did not write. See
        /// `TestFixtures/generators/foreign_ciphers.py`.
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

        /// KDBX4 fixture carrying three inner-header fields KeeForge does not
        /// recognize (0x7F with an ASCII marker, a zero-length 0x10, and a
        /// 0x21 spliced between the two binary-pool entries), authored by a
        /// standalone decrypt/re-encrypt script because no library round-trips
        /// unknown inner-header items. See
        /// `TestFixtures/generators/unknown_inner_header.py`.
        static let unknownInnerHeader = Fixture(
            id: "unknown-inner-header",
            displayName: "Unknown inner-header fields fixture",
            password: "unknown-inner-header",
            keyFileName: nil,
            source: .bundled(name: "unknown-inner-header")
        )

        /// Foreign-authored (pykeepass) KDBX4 fixture whose Argon2 KDF uses a
        /// high iteration count with low memory (1500 x 1 MiB, above the
        /// retired fixed 1000-iteration cap), the acceptance case for the
        /// `KDFExecutionPolicy` work-budget model (issue #74). See
        /// `TestFixtures/generators/argon2_high_iterations.py`.
        static let argon2HighIterations = Fixture(
            id: "argon2-high-iterations",
            displayName: "Argon2 high-iteration KDF fixture",
            password: "argon2-high-iterations",
            keyFileName: nil,
            source: .bundled(name: "argon2-high-iterations")
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
    /// `kitchenSink` fixture is deliberately not here — it has a dedicated
    /// test that runs its smoke scenario plus four more.
    static let smokeFixtures: [Fixture] = [
        .aesBaseline,
        .passwordKeyfile,
        .syntheticChaCha,
        .syntheticTwofish,
        .foreignChaCha20,
        .foreignTwofish,
        .unknownInnerHeader,
        .argon2HighIterations,
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
        let compositeKey: SymmetricKey
        let sourceData: Data
        let sessionKey: SymmetricKey
        let keyFileData: Data?
        /// Bundle the fixture came from, so scenario closures (e.g. a rekey
        /// target that adds a bundled key file) can load sibling fixtures.
        let bundle: Bundle
    }

    /// The credentials a rekey scenario writes with. `password`/`keyFileName`/
    /// `keyFileData` are the EFFECTIVE post-rekey credentials the external
    /// gate must use to open the artifact; `compositeKey` is derived from them.
    struct RekeyTarget {
        let compositeKey: SymmetricKey
        let password: String
        let keyFileName: String?
        let keyFileData: Data?
    }

    struct Scenario {
        let id: String
        let title: String
        let artifactFileName: String
        let expectedSearchTerms: [String]
        let expectedGroupPaths: [String]
        /// nil for rekey-only scenarios: a master-key change is deliberately
        /// not modeled as a content edit, so the whole tree must survive the
        /// save byte-semantically unchanged.
        var makeEdit: ((LoadedFixture) throws -> EntryEdit)?
        /// When set, the whole tree is replaced instead of an `EntryEdit`
        /// being applied. A merge result is not a sequence of edits, so it
        /// reaches the writer through a pristine draft — the same path
        /// `DatabaseViewModel` uses for a merge or a master-key change.
        /// Mutually exclusive with `makeEdit`.
        var makeMergedTree: ((LoadedFixture) throws -> (rootGroup: KPGroup, meta: KPMeta))?
        /// When set, the write uses the rekey composite key instead of the
        /// fixture's, `apply` pins that the old key no longer opens the
        /// output, and the artifact manifest carries the new credentials.
        var rekey: ((LoadedFixture) throws -> RekeyTarget)?
        let assertChange: (CompatibilitySnapshot, CompatibilitySnapshot, LoadedFixture) throws -> Void

        func apply(to loaded: LoadedFixture) throws -> ScenarioResult {
            let beforePool = BinaryPool(rawFields: loaded.header.innerHeaderBinaryFields)
            let before = try CompatibilitySnapshot(
                rootGroup: loaded.rootGroup,
                meta: loaded.meta,
                sessionKey: loaded.sessionKey,
                binaryPool: beforePool
            )
            let updatedDraft: DatabaseDraft
            if let makeMergedTree {
                let merged = try makeMergedTree(loaded)
                updatedDraft = DatabaseDraft(
                    rootGroup: merged.rootGroup,
                    meta: merged.meta,
                    sessionKey: loaded.sessionKey
                )
            } else {
                let draft = DatabaseDraft(rootGroup: loaded.rootGroup, meta: loaded.meta, sessionKey: loaded.sessionKey)
                updatedDraft = try makeEdit.map { try draft.apply($0(loaded)) } ?? draft
            }
            let rekeyTarget = try rekey?(loaded)
            let writeKey = rekeyTarget?.compositeKey ?? loaded.compositeKey
            let written = try KDBXWriter.write(
                rootGroup: updatedDraft.rootGroup,
                meta: updatedDraft.meta,
                compositeKey: writeKey,
                header: loaded.header,
                sessionKey: updatedDraft.writerSessionKey
            )
            if rekeyTarget != nil {
                XCTAssertThrowsError(
                    try KDBXParser.parseWithMetaAndHeader(
                        data: written,
                        compositeKey: loaded.compositeKey,
                        sessionKey: loaded.sessionKey
                    ),
                    "\(id): the old composite key must no longer open the rekeyed database"
                ) { error in
                    guard case KDBXCrypto.CryptoError.hmacMismatch = error else {
                        XCTFail("\(id): expected header HMAC rejection under the old key, got \(error)")
                        return
                    }
                }
            }
            let reparsed = try KDBXParser.parseWithMetaAndHeader(
                data: written,
                compositeKey: writeKey,
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
            return ScenarioResult(
                written: written,
                before: before,
                after: after,
                afterHeader: reparsed.header,
                rekey: rekeyTarget
            )
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
        /// The credentials the scenario rekeyed to, nil for ordinary edits.
        let rekey: RekeyTarget?
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

        /// A TOTP configuration the external opener must generate a code
        /// from (`keepassxc-cli show --totp`). The gate recomputes the
        /// expected code with its own reference implementation for the
        /// 30-second (or `period`-second) windows in effect just before and
        /// just after the CLI call, and accepts either — so a window
        /// rollover mid-check can never flake the gate.
        struct ExpectedTOTP: Codable {
            let entryTitle: String
            /// Base32 secret, as enrolled.
            let secret: String
            let period: Int
            let digits: Int
            /// `TOTPAlgorithm.rawValue` ("SHA1" / "SHA256" / "SHA512").
            let algorithm: String
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
            var expectedTOTPs: [ExpectedTOTP] = []
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
        "fixture-smoke-kitchen-sink": [
            .init(entryTitle: "Multi Attachment Entry", attachmentName: "note-ü.txt", sha256: AttachmentFixtureHashes.noteUnicodeTxt),
            .init(entryTitle: "Multi Attachment Entry", attachmentName: "pixel.png", sha256: AttachmentFixtureHashes.pixelPNG),
            .init(entryTitle: "Dedup Entry A", attachmentName: "shared.bin", sha256: AttachmentFixtureHashes.sharedBin),
            .init(entryTitle: "Dedup Entry B", attachmentName: "shared.bin", sha256: AttachmentFixtureHashes.sharedBin),
            .init(entryTitle: "Controlled Unknowns", attachmentName: "round-trip.txt", sha256: AttachmentFixtureHashes.roundTripTxt),
        ],
        "attachments-update-entry": [
            .init(entryTitle: "Multi Attachment Entry Updated", attachmentName: "note-ü.txt", sha256: AttachmentFixtureHashes.noteUnicodeTxt),
            .init(entryTitle: "Multi Attachment Entry Updated", attachmentName: "pixel.png", sha256: AttachmentFixtureHashes.pixelPNG),
        ],
        "attachments-soft-delete-entry": [
            .init(entryTitle: "Dedup Entry B", attachmentName: "shared.bin", sha256: AttachmentFixtureHashes.sharedBin),
        ],
        "fixture-smoke-unknown-inner-header": [
            .init(
                entryTitle: "Inner Header Entry",
                attachmentName: "alpha-attachment.txt",
                sha256: UnknownInnerHeaderFixtureHashes.alphaAttachmentTxt
            ),
            .init(
                entryTitle: "Inner Header Entry",
                attachmentName: "beta-attachment.txt",
                sha256: UnknownInnerHeaderFixtureHashes.betaAttachmentTxt
            ),
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
        "add-entry-custom-icon",
        "update-group",
        "restore-entry-version",
        "soft-delete-entry",
        "soft-delete-group",
        "hard-delete-recycled-entry",
        "hard-delete-recycled-group",
        "move-entry",
        "move-group",
        "recycle-bin-creation",
        "keeotp-source-matrix",
        "fixture-smoke-aes-baseline",
        "fixture-smoke-password-keyfile",
        "fixture-smoke-synthetic-chacha",
        "fixture-smoke-synthetic-twofish",
        "fixture-smoke-foreign-chacha20",
        "fixture-smoke-foreign-twofish",
        "fixture-smoke-argon2-high-iterations",
        "group-tags-update-entry",
        "group-tags-update-group",
        "merge-remote-divergence",
        "rekey-password-only",
        "rekey-add-keyfile",
        "rekey-remove-keyfile",
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
        Fixture.kitchenSink.id: .init(entryTitle: "Multi Attachment Entry", password: "entry-password-1"),
        Fixture.syntheticChaCha.id: .init(entryTitle: "Compat Untouched Entry", password: "untouched-password"),
        Fixture.syntheticTwofish.id: .init(entryTitle: "Compat Untouched Entry", password: "untouched-password"),
        Fixture.foreignChaCha20.id: .init(entryTitle: "Foreign Entry Alpha", password: "ForeignAlphaSecret1"),
        Fixture.foreignTwofish.id: .init(entryTitle: "Foreign Entry Alpha", password: "ForeignAlphaSecret1"),
        Fixture.unknownInnerHeader.id: .init(entryTitle: "Inner Header Entry", password: "UnknownHeaderSecret1"),
        Fixture.argon2HighIterations.id: .init(entryTitle: "High Iteration Entry", password: "HighIterationSecret1"),
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
        // The group edits touch no entry, so both artifacts probe passwords
        // their own scenario did not write. On `update-group` that also covers
        // the 4.0 → 4.1 header bump: a bumped file whose protected-value stream
        // an external opener could no longer decode would fail here.
        table["update-group"] = [
            .init(entryTitle: "Compat Nested Entry", password: "nested-password"),
            .init(entryTitle: "Compat Untouched Entry", password: "untouched-password"),
        ]
        table["group-tags-update-group"] = [
            .init(entryTitle: "Delta Login", password: "GroupTagDelta4"),
            .init(entryTitle: "Alpha Login", password: "GroupTagAlpha1"),
        ]
        // A merge grafts protected values across from a database KeeForge did
        // not write this session; reading them back externally is what proves
        // they were re-encrypted into the artifact's own inner stream rather
        // than carried over as foreign ciphertext. The untouched entry pins
        // that the rest of the file survived the whole-tree write.
        table["merge-remote-divergence"] = [
            .init(entryTitle: mergeAddedEntryTitle, password: mergeAddedPassword),
            .init(entryTitle: "Compat Update Target", password: mergeRemotePassword),
            .init(entryTitle: "Compat Untouched Entry", password: "untouched-password"),
        ]
        // The rekey artifacts are opened with the NEW credentials, so reading
        // a pre-existing protected value back proves the whole database —
        // including its protected-value stream — was re-encrypted intact.
        table["rekey-password-only"] = [fixtureEntryPasswords[Fixture.aesBaseline.id]!]
        table["rekey-add-keyfile"] = [fixtureEntryPasswords[Fixture.aesBaseline.id]!]
        table["rekey-remove-keyfile"] = [fixtureEntryPasswords[Fixture.passwordKeyfile.id]!]
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
        "add-entry-custom-icon",
        "restore-entry-version",
        "soft-delete-entry",
        "soft-delete-group",
        "hard-delete-recycled-entry",
        "hard-delete-recycled-group",
        "move-entry",
        "move-group",
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

    /// TOTP configurations the external opener must generate codes from.
    /// `update-entry` carries the fresh-enrollment path (verbatim protected
    /// `otp` URI, the editor's primary output); `create-entry` carries the
    /// `TimeOtp-*` authoring path used once a stored URI goes stale. Together
    /// they prove real KeePassXC computes codes from both spellings KeeForge
    /// writes — the in-process matrix alone would only prove KeeForge agrees
    /// with itself.
    static let totpExpectations: [String: [ArtifactManifest.ExpectedTOTP]] = [
        "create-entry": [
            .init(
                entryTitle: "Compat Created Entry",
                secret: "JBSWY3DPEHPK3PXP",
                period: 45,
                digits: 8,
                algorithm: TOTPAlgorithm.sha256.rawValue
            ),
        ],
        "update-entry": [
            .init(
                entryTitle: "Compat Update Target Updated",
                secret: "JBSWY3DPEHPK3PXP",
                period: 30,
                digits: 6,
                algorithm: TOTPAlgorithm.sha1.rawValue
            ),
        ],
    ]

    /// Scenarios that deliberately carry no external TOTP check. The KeeOTP
    /// matrix stays internal (KeePassXC skips raw KeeOTP fields entirely);
    /// everything else simply writes no TOTP.
    static let scenarioIDsWithoutTOTPExpectations: Set<String> = {
        var ids: Set<String> = [
            "create-group",
            "hide-group-from-autofill",
            "change-group-icon",
            "add-entry-custom-icon",
            "update-group",
            "restore-entry-version",
            "soft-delete-entry",
            "soft-delete-group",
            "hard-delete-recycled-entry",
            "hard-delete-recycled-group",
            "move-entry",
            "move-group",
            "recycle-bin-creation",
            "attachments-update-entry",
            "attachments-soft-delete-entry",
            "group-tags-update-entry",
            "group-tags-update-group",
            "keeotp-source-matrix",
            "merge-remote-divergence",
            "rekey-password-only",
            "rekey-add-keyfile",
            "rekey-remove-keyfile",
        ]
        for fixture in smokeFixtures {
            ids.insert("fixture-smoke-\(fixture.id)")
        }
        ids.insert("fixture-smoke-\(Fixture.kitchenSink.id)")
        return ids
    }()

    /// Fail-closed lookup; see `expectedAttachments(forScenarioID:)`.
    static func expectedTOTPs(forScenarioID scenarioID: String) throws -> [ArtifactManifest.ExpectedTOTP] {
        if let expectations = totpExpectations[scenarioID] {
            return expectations
        }
        guard scenarioIDsWithoutTOTPExpectations.contains(scenarioID) else {
            throw ExpectationLookupError.unlistedScenario(kind: "TOTP", scenarioID: scenarioID)
        }
        return []
    }

    static func load(_ fixture: Fixture, bundle: Bundle, sessionKey: SymmetricKey = SymmetricKey(size: .bits256)) throws -> LoadedFixture {
        let keyFileData = try fixture.keyFileName.map { keyFileName in
            let keyURL = try TestDatabaseSupport.fixtureURL(
                named: keyFileName,
                extension: "key",
                bundle: bundle
            )
            return try Data(contentsOf: keyURL)
        }
        let compositeKey = try KDBXCrypto.compositeKey(password: fixture.password, keyFileData: keyFileData)

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
            keyFileData: keyFileData,
            bundle: bundle
        )
    }

    static func fullEditScenarios() -> [Scenario] {
        [
            createEntryScenario(),
            updateEntryScenario(),
            createGroupScenario(),
            hideGroupFromAutoFillScenario(),
            changeGroupIconScenario(),
            addEntryCustomIconScenario(),
            updateGroupScenario(),
            restoreEntryVersionScenario(),
            softDeleteEntryScenario(),
            softDeleteGroupScenario(),
            hardDeleteRecycledEntryScenario(),
            hardDeleteRecycledGroupScenario(),
            moveEntryScenario(),
            moveGroupScenario(),
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
                // Recycling moves the entry, so its `<LocationChanged>` — and
                // nothing else about it — is allowed to differ.
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                assertOnlyLocationChangedDiffers(
                    before: try XCTUnwrap(before.entries[entryID]),
                    after: try XCTUnwrap(after.entries[entryID])
                )
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

    static func restoreEntryVersionScenario() -> Scenario {
        Scenario(
            id: "restore-entry-version",
            title: "Restore an entry's earlier History version",
            artifactFileName: "synthetic-rich-restore-entry-version.kdbx",
            expectedSearchTerms: ["Compat Restore Target"],
            expectedGroupPaths: ["Compat Group Delete Target"],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Restore Target", in: loaded.rootGroup))
                return .restoreEntryVersion(entryID: entry.id, historyIndex: 0)
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Compat Restore Target"))
                let beforeEntry = try XCTUnwrap(before.entries[entryID])
                XCTAssertEqual(beforeEntry.history.count, 1, "Fixture precondition: one stored version")

                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.entries.count, before.entries.count)

                let afterEntry = try XCTUnwrap(after.entries[entryID])
                XCTAssertEqual(afterEntry.username, "previous-user")
                XCTAssertEqual(afterEntry.url, "https://previous.example.com")
                XCTAssertEqual(afterEntry.password, "previous-password")

                // The replaced state is kept, so the restore stays reversible after a
                // full write/reparse round trip.
                XCTAssertEqual(afterEntry.history.count, 2)
                XCTAssertEqual(afterEntry.history[0].username, "current-user")
                XCTAssertEqual(afterEntry.history[0].password, "current-password")
            }
        )
    }

    /// Storing a downloaded website icon: the one edit that adds bytes to
    /// `Meta/CustomIcons`, which the writer otherwise replays verbatim.
    ///
    /// The proof that matters is the full write/reparse cycle — the icon is
    /// spliced into a preserved fragment as text, so nothing but a real parse of
    /// the real file says whether it landed as an element or as garbage inside
    /// one. `keepassxc-cli` has no verb that prints custom icons, so the icon
    /// half of the check stays in-process here, the way group tags do in
    /// `updateGroupScenario`; the artifact still proves the *file* opens.
    static func addEntryCustomIconScenario() -> Scenario {
        // A real 1×1 PNG rather than arbitrary bytes: what goes into a vault
        // should be what the feature actually writes.
        let iconData = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ) ?? Data()
        let iconUUID = UUID()

        return Scenario(
            id: "add-entry-custom-icon",
            title: "Store a downloaded website icon and point an entry at it",
            artifactFileName: "synthetic-rich-add-entry-custom-icon.kdbx",
            expectedSearchTerms: ["Compat Untouched Entry"],
            expectedGroupPaths: ["Compat Group Delete Target"],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Untouched Entry", in: loaded.rootGroup))
                return .addEntryCustomIcon(
                    entryID: entry.id,
                    iconUUID: iconUUID,
                    imageData: iconData
                )
            },
            assertChange: { before, after, _ in
                XCTAssertFalse(iconData.isEmpty, "Fixture precondition: the test PNG must decode")
                XCTAssertNil(
                    before.meta.customIcons[iconUUID],
                    "Fixture precondition: the icon must not already be in the file"
                )

                // The icon survived being written and parsed back, byte for byte.
                XCTAssertEqual(after.meta.customIcons[iconUUID], iconData)

                // Every icon the source already carried is still there and
                // unchanged: the splice must not rewrite its neighbours.
                for (uuid, data) in before.meta.customIcons {
                    XCTAssertEqual(after.meta.customIcons[uuid], data, "existing custom icon \(uuid) changed")
                }
                XCTAssertEqual(after.meta.customIcons.count, before.meta.customIcons.count + 1)

                // Meta is otherwise untouched — this edit may add an icon and
                // nothing else.
                XCTAssertEqual(after.meta.recycleBinUUID, before.meta.recycleBinUUID)
                XCTAssertEqual(after.meta.historyMaxItems, before.meta.historyMaxItems)
                XCTAssertEqual(after.meta.historyMaxSize, before.meta.historyMaxSize)
                XCTAssertEqual(after.meta.deletedObjects, before.meta.deletedObjects)

                let entryID = try XCTUnwrap(before.entryID(titled: "Compat Untouched Entry"))
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)

                // The reference reached the file too, so another client shows
                // the icon rather than the entry's standard one.
                let afterEntry = try XCTUnwrap(after.entries[entryID])
                let beforeEntry = try XCTUnwrap(before.entries[entryID])
                XCTAssertTrue(
                    afterEntry.unknownXML.nodes.contains {
                        $0.xml == "<CustomIconUUID>\(iconUUID.kdbxBase64String)</CustomIconUUID>"
                    },
                    "the entry must carry the reference after a full round trip"
                )
                XCTAssertEqual(afterEntry.iconID, beforeEntry.iconID, "the standard icon it overrides is left alone")
                XCTAssertEqual(afterEntry.title, beforeEntry.title)
                XCTAssertEqual(afterEntry.password, beforeEntry.password)
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

    /// The group editor's whole payload in one edit: rename, author `<Tags>`
    /// on a group that never had them, and set structured `<Notes>`.
    ///
    /// Authoring a group tag is what forces the writer's 4.0 → 4.1 header bump,
    /// so this scenario's artifact is also the one that proves a bumped file
    /// still opens in real KeePassXC. The tags themselves are not externally
    /// verifiable — `keepassxc-cli` has no verb that prints group tags — so
    /// that half of the proof stays in-process, here and in
    /// `KDBXCompatibilityTests.test_allSupportedEditScenarios_…`.
    static func updateGroupScenario() -> Scenario {
        let renamedName = "Compat Renamed Group"
        let authoredNotes = "Renamed, tagged, and annotated by the group editor."
        return Scenario(
            id: "update-group",
            title: "Update group renames, tags, and annotates in one edit",
            artifactFileName: "synthetic-rich-update-group.kdbx",
            expectedSearchTerms: ["Compat Nested Entry"],
            // The rename has to land for this path to resolve at all.
            expectedGroupPaths: ["Compat Group Delete Target/\(renamedName)"],
            makeEdit: { loaded in
                let group = try XCTUnwrap(
                    findGroup(named: "Compat Nested Child Group", in: loaded.rootGroup)
                )
                return .updateGroup(
                    groupID: group.id,
                    draft: GroupDraftPayload(
                        name: renamedName,
                        tags: ["compat", "renamed"],
                        notes: authoredNotes,
                        iconID: group.iconID,
                        searchingEnabled: inheritableBoolPayload(for: group.searchingEnabled)
                    )
                )
            },
            assertChange: { before, after, _ in
                let targetID = try XCTUnwrap(before.groupID(named: "Compat Nested Child Group"))
                let beforeGroup = try XCTUnwrap(before.groups[targetID])
                XCTAssertFalse(
                    beforeGroup.hasTagsElement,
                    "Fixture precondition: the target group starts without a <Tags> element"
                )
                XCTAssertTrue(beforeGroup.tags.isEmpty, "Fixture precondition: the target group starts untagged")
                XCTAssertFalse(
                    beforeGroup.hasNotesElement,
                    "Fixture precondition: the target group starts without a <Notes> element"
                )

                try assertUnchangedEntries(before: before, after: after)
                // Siblings, ancestors, and the recycled subtree may not move:
                // only the edited group is exempt from the scalar comparison.
                try assertSurvivingGroupsPreserveScalars(
                    before: before,
                    after: after,
                    excluding: [targetID]
                )
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.groups.count, before.groups.count)
                XCTAssertNil(
                    after.groupID(named: "Compat Nested Child Group"),
                    "The pre-rename name must not survive anywhere in the tree"
                )

                let afterGroup = try XCTUnwrap(after.groups[targetID])
                XCTAssertEqual(afterGroup.name, renamedName)
                XCTAssertEqual(afterGroup.tags, ["compat", "renamed"])
                XCTAssertTrue(
                    afterGroup.hasTagsElement,
                    "Authored tags must come back as a real <Tags> element after the round trip"
                )
                XCTAssertEqual(afterGroup.notes, authoredNotes)
                XCTAssertTrue(afterGroup.hasNotesElement)
                XCTAssertFalse(
                    afterGroup.unknownXML.nodes.contains { $0.xml.hasPrefix("<Notes>") },
                    "Group <Notes> is structured, so no opaque copy may be written next to it"
                )
                // The icon was not touched, so nothing on the icon path may be
                // dropped and the group's children must be exactly as before.
                XCTAssertEqual(afterGroup.iconID, beforeGroup.iconID)
                XCTAssertEqual(afterGroup.searchingEnabled, beforeGroup.searchingEnabled)
                XCTAssertEqual(afterGroup.entryIDs, beforeGroup.entryIDs)
                XCTAssertEqual(afterGroup.groupIDs, beforeGroup.groupIDs)
                XCTAssertEqual(afterGroup.creationTime, beforeGroup.creationTime)
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

    /// Update-entry scenario for the `kitchen-sink` fixture: edits the
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

    /// Soft-delete scenario for the `kitchen-sink` fixture: sends `Dedup
    /// Entry A` into the recycle bin the fixture already carries and asserts
    /// both dedup entries' shared attachment bytes remain resolvable and
    /// identical afterward. Recycling into an existing bin is the complement of
    /// `recycleBinCreationScenario`, which covers the bin-less path.
    static func attachmentsFixtureSoftDeleteScenario() -> Scenario {
        Scenario(
            id: "attachments-soft-delete-entry",
            title: "Soft delete entry preserves sibling dedup attachment",
            artifactFileName: "attachments-soft-delete-entry.kdbx",
            expectedSearchTerms: ["Dedup Entry B"],
            // The fixture's own bin, authored by pykeepass — no group is
            // created and the UI-language name is never used.
            expectedGroupPaths: ["Recycle Bin"],
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
                assertOnlyLocationChangedDiffers(before: deletedBefore, after: deletedAfter)
                XCTAssertEqual(deletedAfter.attachments, deletedBefore.attachments)
                XCTAssertEqual(deletedAfter.attachmentHashes, deletedBefore.attachmentHashes)

                let survivor = try XCTUnwrap(after.entries[survivingID])
                XCTAssertEqual(survivor.attachments.map(\.name), ["shared.bin"])
                XCTAssertEqual(survivor.attachmentHashes, [AttachmentFixtureHashes.sharedBin])
                XCTAssertEqual(deletedAfter.attachmentHashes, [AttachmentFixtureHashes.sharedBin])

                XCTAssertEqual(
                    after.meta.recycleBinUUID,
                    before.meta.recycleBinUUID,
                    "The fixture's own bin is reused, so no new one is registered"
                )
                XCTAssertEqual(after.groups.count, before.groups.count)
                let recycleBinID = try XCTUnwrap(after.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertEqual(recycleBin.name, "Recycle Bin")
                XCTAssertTrue(recycleBin.entryIDs.contains(deletedID))
                let trashedID = try XCTUnwrap(before.entryID(titled: "Trashed Login"))
                XCTAssertTrue(
                    recycleBin.entryIDs.contains(trashedID),
                    "The entry the fixture already had in the bin stays there"
                )
            }
        )
    }

    /// Update-entry scenario for the `kitchen-sink` fixture: edits `Beta Login`
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
    /// `KDBXCompatibilityTests.test_kitchenSinkFixture_…`.
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
                XCTAssertTrue(projects.hasNotesElement)
                XCTAssertEqual(
                    projects.notes,
                    "Group notes ride along as unknown XML next to the structured Tags element.",
                    "The group's structured <Notes> survives next to the structured <Tags>"
                )
                XCTAssertFalse(
                    projects.unknownXML.nodes.contains { $0.xml.hasPrefix("<Notes>") },
                    "Group <Notes> is structured now, so no opaque copy may remain"
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

    /// Update-group scenario for the `kitchen-sink` fixture: authors a KeeForge
    /// group tag and structured `<Notes>` on `Plain Group` — the one group in
    /// the fixture that never carried a `<Tags>` element — while re-saving its
    /// name unchanged.
    ///
    /// Not redundant with `update-group` on the synthetic fixture: that one
    /// authors a tag into a KeeForge-written 4.0 file with no opaque group
    /// children and bumps the header. This one adds a tag to a foreign
    /// (pykeepass) 4.1 file whose groups carry opaque children in a
    /// non-canonical child order, and must leave the other three `<Tags>`
    /// states — content, empty element, absent — untouched while doing it.
    ///
    /// Same external-proof limitation as `groupTagsFixtureUpdateEntryScenario`:
    /// the gate can only prove the rewritten database still opens, lists, and
    /// decrypts; the tag proof is the in-process assertions below.
    static func groupTagsFixtureUpdateGroupScenario() -> Scenario {
        let authoredTag = "keeforge-authored"
        let authoredNotes = "Group notes authored by KeeForge on a file that already had group tags."
        return Scenario(
            id: "group-tags-update-group",
            title: "Update group authors a tag on a file that already has group tags",
            artifactFileName: "group-tags-update-group.kdbx",
            expectedSearchTerms: ["Delta Login"],
            expectedGroupPaths: ["Projects", "Projects/Client Work", "Empty Tags Group", "Plain Group"],
            makeEdit: { loaded in
                let group = try XCTUnwrap(findGroup(named: "Plain Group", in: loaded.rootGroup))
                return .updateGroup(
                    groupID: group.id,
                    draft: GroupDraftPayload(
                        name: group.name,
                        tags: [authoredTag],
                        notes: authoredNotes,
                        iconID: group.iconID,
                        searchingEnabled: inheritableBoolPayload(for: group.searchingEnabled)
                    )
                )
            },
            assertChange: { before, after, _ in
                let targetID = try XCTUnwrap(before.groupID(named: "Plain Group"))
                let beforeGroup = try XCTUnwrap(before.groups[targetID])
                XCTAssertFalse(
                    beforeGroup.hasTagsElement,
                    "Fixture precondition: Plain Group carries no <Tags> element"
                )

                try assertUnchangedEntries(before: before, after: after)
                // The other three group-tag states must survive an edit that
                // adds a fourth.
                try assertSurvivingGroupsPreserveScalars(
                    before: before,
                    after: after,
                    excluding: [targetID]
                )
                assertMetaUnchanged(before: before, after: after)
                XCTAssertEqual(after.groups.count, before.groups.count)

                let afterGroup = try XCTUnwrap(after.groups[targetID])
                XCTAssertEqual(
                    afterGroup.name,
                    "Plain Group",
                    "Re-saving a group under its own name is not a sibling collision"
                )
                XCTAssertEqual(afterGroup.tags, [authoredTag])
                XCTAssertTrue(afterGroup.hasTagsElement)
                XCTAssertEqual(afterGroup.notes, authoredNotes)
                XCTAssertTrue(afterGroup.hasNotesElement)
                XCTAssertEqual(afterGroup.iconID, beforeGroup.iconID)
                XCTAssertEqual(afterGroup.searchingEnabled, beforeGroup.searchingEnabled)
                XCTAssertEqual(afterGroup.entryIDs, beforeGroup.entryIDs)
                XCTAssertEqual(afterGroup.groupIDs, beforeGroup.groupIDs)
                XCTAssertEqual(afterGroup.creationTime, beforeGroup.creationTime)
                // Adding a `<Tags>` child renumbers nothing before it, but the
                // content contract is the load-bearing one: nothing the foreign
                // writer left opaque may be dropped or invented.
                XCTAssertEqual(
                    Set(afterGroup.unknownXML.nodes.map(\.xml)),
                    Set(beforeGroup.unknownXML.nodes.map(\.xml))
                )

                let projects = try XCTUnwrap(after.groups[XCTUnwrap(after.groupID(named: "Projects"))])
                XCTAssertEqual(projects.tags, ["team", "shared"])
                XCTAssertTrue(projects.hasTagsElement)
                XCTAssertEqual(
                    projects.notes,
                    "Group notes ride along as unknown XML next to the structured Tags element."
                )

                let clientWork = try XCTUnwrap(after.groups[XCTUnwrap(after.groupID(named: "Client Work"))])
                XCTAssertEqual(clientWork.tags, ["billable"])

                let emptyTags = try XCTUnwrap(after.groups[XCTUnwrap(after.groupID(named: "Empty Tags Group"))])
                XCTAssertTrue(emptyTags.tags.isEmpty)
                XCTAssertTrue(emptyTags.hasTagsElement, "The empty <Tags></Tags> element survives the save")
            }
        )
    }

    // MARK: - Merge scenario

    /// Fixed identities for the objects the merge scenario's remote side
    /// introduces, so assertions can key on them.
    static let mergeRemoteGroupID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000401")!
    static let mergeRemoteEntryID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000402")!
    static let mergeRemotePassword = "merged-remote-password"
    static let mergeAddedPassword = "merge-added-password"
    static let mergeAddedEntryTitle = "Compat Merge Remote Addition"
    static let mergeRemoteGroupName = "Compat Merge Remote Group"

    /// A record-level merge, written out and reopened.
    ///
    /// The three effects a merge has to land at once are all present: the
    /// remote wins a content conflict (its version becomes current, local's
    /// drops into history), a remote-only group and entry are grafted in, and
    /// a remote move reparents an entry. The external gate then asks real
    /// KeePassXC to open the result, list the grafted group, and decrypt a
    /// protected value the merge carried across from the other side — the one
    /// thing an in-process reparse cannot prove.
    static func mergeRemoteDivergenceScenario() -> Scenario {
        Scenario(
            id: "merge-remote-divergence",
            title: "Merge a divergent remote: conflict, graft, and move in one write",
            artifactFileName: "synthetic-rich-merge-remote-divergence.kdbx",
            expectedSearchTerms: [mergeAddedEntryTitle, "Compat Update Target"],
            expectedGroupPaths: [mergeRemoteGroupName, "Compat Group Delete Target"],
            makeMergedTree: { loaded in
                let local = KDBXMerger.Side(
                    rootGroup: loaded.rootGroup,
                    meta: loaded.meta,
                    binaryPoolFields: loaded.header.innerHeaderBinaryFields
                )
                let outcome = try KDBXMerger.merge(
                    local: local,
                    remote: try makeMergeRemoteSide(loaded),
                    sessionKey: loaded.sessionKey
                )
                guard case .merged(let merged) = outcome else {
                    throw MergeScenarioError.declined
                }
                XCTAssertTrue(merged.summary.hasChanges, "merge-remote-divergence: the pair does diverge")
                return (merged.rootGroup, merged.meta)
            },
            assertChange: { before, after, _ in
                let visibleRootID = try XCTUnwrap(before.groupID(named: "Compatibility Root"))
                let deleteTargetID = try XCTUnwrap(before.groupID(named: "Compat Group Delete Target"))
                let conflictID = try XCTUnwrap(before.entryID(titled: "Compat Update Target"))
                let movedID = try XCTUnwrap(before.entryID(titled: "Compat Empty Tags"))

                try assertUnchangedEntries(before: before, after: after, excluding: [conflictID, movedID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)

                // The newer remote version wins the entry outright and the
                // losing local one survives as history.
                let localConflict = try XCTUnwrap(before.entries[conflictID])
                let mergedConflict = try XCTUnwrap(after.entries[conflictID])
                XCTAssertEqual(mergedConflict.password, mergeRemotePassword)
                XCTAssertEqual(mergedConflict.notes, "Remote merge edit")
                XCTAssertEqual(mergedConflict.history.map(\.password), [localConflict.password])
                XCTAssertEqual(mergedConflict.history.map(\.notes), [localConflict.notes])

                // The remote-only group and its entry survive the write.
                let graftedGroup = try XCTUnwrap(after.groups[mergeRemoteGroupID])
                XCTAssertEqual(graftedGroup.name, mergeRemoteGroupName)
                XCTAssertEqual(graftedGroup.entryIDs, [mergeRemoteEntryID])
                XCTAssertEqual(try XCTUnwrap(after.entries[mergeRemoteEntryID]).password, mergeAddedPassword)
                XCTAssertEqual(try XCTUnwrap(after.groups[visibleRootID]).groupIDs.last, mergeRemoteGroupID)

                // The remote move reparents the entry and changes nothing else
                // about it.
                XCTAssertTrue(try XCTUnwrap(after.groups[deleteTargetID]).entryIDs.contains(movedID))
                XCTAssertFalse(try XCTUnwrap(after.groups[visibleRootID]).entryIDs.contains(movedID))
                assertOnlyLocationChangedDiffers(
                    before: try XCTUnwrap(before.entries[movedID]),
                    after: try XCTUnwrap(after.entries[movedID])
                )
            }
        )
    }

    enum MergeScenarioError: Error, CustomStringConvertible {
        case declined

        var description: String {
            "merge-remote-divergence: the engine declined a pair it must be able to merge."
        }
    }

    /// The remote side of the merge scenario: the same database as another
    /// device would have left it. Written out and parsed back, so the merge
    /// runs on two independent parses sharing one session key, exactly as
    /// `DatabaseViewModel` will run it against a downloaded file.
    private static func makeMergeRemoteSide(_ loaded: LoadedFixture) throws -> KDBXMerger.Side {
        let remoteRoot = loaded.rootGroup.deepCopy()
        let visibleRoot = try XCTUnwrap(remoteRoot.groups.first)
        // Later than the fixture's single timestamp, so the remote edit wins.
        let remoteTimestamp = Date(timeIntervalSince1970: 1_700_003_600)

        let conflictIndex = try XCTUnwrap(visibleRoot.entries.firstIndex { $0.title == "Compat Update Target" })
        visibleRoot.entries[conflictIndex].password = try EncryptedValue.encrypt(
            mergeRemotePassword,
            using: loaded.sessionKey
        )
        visibleRoot.entries[conflictIndex].notes = "Remote merge edit"
        visibleRoot.entries[conflictIndex].lastModificationTime = remoteTimestamp

        let movedIndex = try XCTUnwrap(visibleRoot.entries.firstIndex { $0.title == "Compat Empty Tags" })
        var moved = visibleRoot.entries.remove(at: movedIndex)
        moved.locationChanged = remoteTimestamp
        let moveDestination = try XCTUnwrap(findGroup(named: "Compat Group Delete Target", in: remoteRoot))
        moveDestination.entries.append(moved)

        visibleRoot.groups.append(
            KPGroup(
                id: mergeRemoteGroupID,
                name: mergeRemoteGroupName,
                entries: [
                    KPEntry(
                        id: mergeRemoteEntryID,
                        title: mergeAddedEntryTitle,
                        username: "merge-added-user",
                        password: try EncryptedValue.encrypt(mergeAddedPassword, using: loaded.sessionKey),
                        creationTime: remoteTimestamp,
                        lastModificationTime: remoteTimestamp,
                        locationChanged: remoteTimestamp
                    )
                ],
                creationTime: remoteTimestamp,
                lastModificationTime: remoteTimestamp,
                locationChanged: remoteTimestamp
            )
        )

        let remoteData = try KDBXWriter.write(
            rootGroup: remoteRoot,
            meta: loaded.meta,
            compositeKey: loaded.compositeKey,
            header: loaded.header,
            sessionKey: loaded.sessionKey
        )
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: remoteData,
            compositeKey: loaded.compositeKey,
            sessionKey: loaded.sessionKey
        )
        return KDBXMerger.Side(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            binaryPoolFields: parsed.header.innerHeaderBinaryFields
        )
    }

    // MARK: - Rekey scenarios

    /// Password the rekey scenarios change to. Shared with the manifest via
    /// `RekeyTarget.password` so the external gate opens the artifacts with it.
    static let rekeyNewPassword = "rekeyed-master-password-1"

    /// Shared assertion body for every rekey scenario: a master-key change is
    /// not a content edit, so the tree, groups, and meta must all survive the
    /// save unchanged. The old-key rejection and header rotation checks live
    /// in `Scenario.apply` and the running test method respectively.
    private static func assertRekeyLeavesTreeUnchanged(
        before: CompatibilitySnapshot,
        after: CompatibilitySnapshot
    ) throws {
        try assertUnchangedEntries(before: before, after: after)
        try assertSurvivingGroupsPreserveScalars(before: before, after: after)
        assertMetaUnchanged(before: before, after: after)
        XCTAssertEqual(after.entries.count, before.entries.count)
        XCTAssertEqual(after.groups.count, before.groups.count)
    }

    /// `.aesBaseline` (password only) rekeyed to a different password.
    static func rekeyPasswordOnlyScenario() -> Scenario {
        Scenario(
            id: "rekey-password-only",
            title: "Change master password only",
            artifactFileName: "aes-baseline-rekey-password-only.kdbx",
            expectedSearchTerms: ["Twitter"],
            expectedGroupPaths: ["Social"],
            rekey: { _ in
                RekeyTarget(
                    compositeKey: try KDBXCrypto.compositeKey(password: rekeyNewPassword, keyFileData: nil),
                    password: rekeyNewPassword,
                    keyFileName: nil,
                    keyFileData: nil
                )
            },
            assertChange: { before, after, _ in
                try assertRekeyLeavesTreeUnchanged(before: before, after: after)
            }
        )
    }

    /// `.aesBaseline` rekeyed to its existing password plus `.passwordKeyfile`'s
    /// bundled key file, so "add a key file" is the only change.
    static func rekeyAddKeyfileScenario() -> Scenario {
        Scenario(
            id: "rekey-add-keyfile",
            title: "Add a key file to the master key",
            artifactFileName: "aes-baseline-rekey-add-keyfile.kdbx",
            expectedSearchTerms: ["Twitter"],
            expectedGroupPaths: ["Social"],
            rekey: { loaded in
                let keyFileName = try XCTUnwrap(Fixture.passwordKeyfile.keyFileName)
                let keyURL = try TestDatabaseSupport.fixtureURL(
                    named: keyFileName,
                    extension: "key",
                    bundle: loaded.bundle
                )
                let keyFileData = try Data(contentsOf: keyURL)
                return RekeyTarget(
                    compositeKey: try KDBXCrypto.compositeKey(
                        password: loaded.fixture.password,
                        keyFileData: keyFileData
                    ),
                    password: loaded.fixture.password,
                    keyFileName: keyFileName,
                    keyFileData: keyFileData
                )
            },
            assertChange: { before, after, _ in
                try assertRekeyLeavesTreeUnchanged(before: before, after: after)
            }
        )
    }

    /// `.passwordKeyfile` (password + key file) rekeyed to password only.
    static func rekeyRemoveKeyfileScenario() -> Scenario {
        Scenario(
            id: "rekey-remove-keyfile",
            title: "Remove the key file from the master key",
            artifactFileName: "password-keyfile-rekey-remove-keyfile.kdbx",
            expectedSearchTerms: ["KeyFile Test Entry"],
            expectedGroupPaths: [],
            rekey: { loaded in
                XCTAssertNotNil(
                    loaded.keyFileData,
                    "Fixture precondition: the source composite key includes a key file to remove"
                )
                return RekeyTarget(
                    compositeKey: try KDBXCrypto.compositeKey(
                        password: loaded.fixture.password,
                        keyFileData: nil
                    ),
                    password: loaded.fixture.password,
                    keyFileName: nil,
                    keyFileData: nil
                )
            },
            assertChange: { before, after, _ in
                try assertRekeyLeavesTreeUnchanged(before: before, after: after)
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
            ArtifactDescriptor(fixture: .kitchenSink, scenario: fixtureSmokeScenario(fixtureID: Fixture.kitchenSink.id))
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .kitchenSink, scenario: attachmentsFixtureUpdateEntryScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .kitchenSink, scenario: attachmentsFixtureSoftDeleteScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .kitchenSink, scenario: groupTagsFixtureUpdateEntryScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .kitchenSink, scenario: groupTagsFixtureUpdateGroupScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .syntheticRich, scenario: keeOTPArtifactScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .syntheticRich, scenario: mergeRemoteDivergenceScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .aesBaseline, scenario: rekeyPasswordOnlyScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .aesBaseline, scenario: rekeyAddKeyfileScenario())
        )
        descriptors.append(
            ArtifactDescriptor(fixture: .passwordKeyfile, scenario: rekeyRemoveKeyfileScenario())
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
            try record(scenario: scenario, loaded: loaded, written: result.written, rekey: result.rekey)
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

        private func record(scenario: Scenario, loaded: LoadedFixture, written: Data, rekey: RekeyTarget?) throws {
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

            // A rekeyed artifact only opens with the credentials it was
            // rekeyed to, so the manifest must carry the EFFECTIVE post-rekey
            // password and key file, not the fixture's.
            let effectivePassword: String
            let effectiveKeyFileName: String?
            let effectiveKeyFileData: Data?
            if let rekey {
                effectivePassword = rekey.password
                effectiveKeyFileName = rekey.keyFileName
                effectiveKeyFileData = rekey.keyFileData
            } else {
                effectivePassword = loaded.fixture.password
                effectiveKeyFileName = loaded.fixture.keyFileName
                effectiveKeyFileData = loaded.keyFileData
            }

            var keyFileAttachmentName: String?
            if let keyFileData = effectiveKeyFileData, let keyFileName = effectiveKeyFileName {
                let name = "\(keyFileName).key"
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
                    password: effectivePassword,
                    keyFileName: keyFileAttachmentName,
                    expectedSearchTerms: scenario.expectedSearchTerms,
                    expectedGroupPaths: scenario.expectedGroupPaths,
                    expectedAttachments: try KDBXCompatibilitySupport.expectedAttachments(forScenarioID: scenario.id),
                    expectedPasswords: try KDBXCompatibilitySupport.expectedPasswords(forScenarioID: scenario.id),
                    expectedTOTPs: try KDBXCompatibilitySupport.expectedTOTPs(forScenarioID: scenario.id)
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

        // A master-key change is a write under a different composite key, so
        // the read-only gate must reject it identically — rekey never becomes
        // a KDBX 3.1 escape hatch.
        let rekeyCompositeKey = try KDBXCrypto.compositeKey(
            password: rekeyNewPassword,
            keyFileData: nil
        )
        XCTAssertNotEqual(rekeyCompositeKey, loaded.compositeKey)
        XCTAssertThrowsError(
            try KDBXWriter.write(
                rootGroup: loaded.rootGroup,
                meta: loaded.meta,
                compositeKey: rekeyCompositeKey,
                header: loaded.header,
                sessionKey: loaded.sessionKey
            )
        ) { error in
            guard case KDBXWriter.WriteError.unsupportedSourceFormat(.kdbx3_1) = error else {
                XCTFail("Expected KDBX 3.1 writer rejection for a rekey write, got \(error)")
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
        /// Covered here so only an edit that actually reparents the entry may
        /// touch `<Times>/<LocationChanged>` — every other scenario has to keep
        /// it byte-identical across the save.
        var locationChanged: Date?
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
        let notes: String
        let hasNotesElement: Bool
        let iconID: Int
        let tags: [String]
        let hasTagsElement: Bool
        let isExpanded: Bool
        let searchingEnabled: KPInheritableBool?
        let creationTime: Date?
        let lastModificationTime: Date?
        let locationChanged: Date?
        let recycleBinUUID: UUID?
        let unknownXML: OpaqueXMLNodes
        let entryIDs: [UUID]
        let groupIDs: [UUID]

        var scalars: GroupScalars {
            GroupScalars(
                id: id,
                name: name,
                notes: notes,
                hasNotesElement: hasNotesElement,
                iconID: iconID,
                tags: tags,
                hasTagsElement: hasTagsElement,
                isExpanded: isExpanded,
                searchingEnabled: searchingEnabled,
                creationTime: creationTime,
                lastModificationTime: lastModificationTime,
                locationChanged: locationChanged,
                recycleBinUUID: recycleBinUUID,
                unknownXML: Self.canonicallyOrdered(unknownXML)
            )
        }

        /// The in-memory order of unknown fragments follows the source
        /// document's child order, so a rewrite that normalizes a foreign
        /// file's non-canonical child order (pykeepass emits `<Times>` before
        /// `<Name>`; KeeForge writes each known element at KeePass's position)
        /// permutes fragments from *different* paths
        /// in the array while preserving every fragment's content and
        /// insertion position. The scalar comparison enforces the position
        /// contract — nothing dropped, moved, or invented — not the array
        /// order, so sort deterministically before comparing. Byte-level
        /// ordering within a path stays covered by the round-trip suite and
        /// the external gate.
        private static func canonicallyOrdered(_ unknownXML: OpaqueXMLNodes) -> OpaqueXMLNodes {
            OpaqueXMLNodes(nodes: unknownXML.nodes.sorted { lhs, rhs in
                if lhs.path != rhs.path {
                    return lhs.path.joined(separator: "/") < rhs.path.joined(separator: "/")
                }
                if lhs.insertionIndex != rhs.insertionIndex {
                    return lhs.insertionIndex < rhs.insertionIndex
                }
                return lhs.xml < rhs.xml
            })
        }
    }

    struct GroupScalars: Equatable {
        let id: UUID
        let name: String
        /// Covered here so an unrelated edit cannot silently drop or invent a
        /// group's structured `<Notes>`.
        let notes: String
        let hasNotesElement: Bool
        let iconID: Int
        /// Covered here so an unrelated edit cannot silently drop, reorder,
        /// or invent a group's KDBX 4.1 `<Tags>` without a compatibility
        /// scenario failing. Only `updateGroup` may author one.
        let tags: [String]
        let hasTagsElement: Bool
        let isExpanded: Bool
        /// Covered here so an unrelated edit cannot silently drop or flip a
        /// group's `<EnableSearching>` without a compatibility scenario failing.
        let searchingEnabled: KPInheritableBool?
        let creationTime: Date?
        let lastModificationTime: Date?
        /// Covered here so only an edit that actually reparents the group may
        /// touch `<Times>/<LocationChanged>`; recycling is such a move, every
        /// other scenario must leave it alone.
        var locationChanged: Date?
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
            notes: group.notes,
            hasNotesElement: group.hasNotesElement,
            iconID: group.iconID,
            tags: group.tags,
            hasTagsElement: group.hasTagsElement,
            isExpanded: group.isExpanded,
            searchingEnabled: group.searchingEnabled,
            creationTime: group.creationTime,
            lastModificationTime: group.lastModificationTime,
            locationChanged: group.locationChanged,
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
            locationChanged: entry.locationChanged,
            history: try entry.history.map { try capture(entry: $0, sessionKey: sessionKey, binaryPool: binaryPool) },
            unknownXML: entry.unknownXML,
            protectedStringKeys: entry.protectedStringKeys,
            attachments: entry.attachments,
            attachmentHashes: attachmentHashes(for: entry.attachments, binaryPool: binaryPool)
        )
    }
}

private extension KDBXCompatibilitySupport {
    /// Setup link `update-entry` enrolls on its target. Its parameters are all
    /// otpauth defaults, so it stays consistent with the scenario's
    /// `totpConfig` (30s / 6 digits / SHA1) and the `update-entry` row in
    /// `totpExpectations`.
    static let updateEntryEnrolledOTPAuthURI =
        "otpauth://totp/Compat:updated-user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Compat"

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
                            PasskeyCredential.credentialIDKey: "3q2-7wEj",
                            PasskeyCredential.relyingPartyKey: "created.example.com",
                            PasskeyCredential.usernameKey: "created-passkey-user",
                            PasskeyCredential.userHandleKey: "AAEC-_z9",
                            PasskeyCredential.privateKeyPEMKey: "created-private-key",
                        ],
                        protectedCustomFieldKeys: [
                            PasskeyCredential.credentialIDKey,
                            PasskeyCredential.privateKeyPEMKey,
                            PasskeyCredential.userHandleKey,
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
                XCTAssertTrue(created.protectedStringKeys.isSuperset(of: [
                    PasskeyCredential.credentialIDKey,
                    PasskeyCredential.privateKeyPEMKey,
                    PasskeyCredential.userHandleKey,
                ]))
                XCTAssertFalse(created.protectedStringKeys.contains(PasskeyCredential.relyingPartyKey))
                XCTAssertFalse(created.protectedStringKeys.contains(PasskeyCredential.usernameKey))
                let credentialID = try XCTUnwrap(created.customFields[PasskeyCredential.credentialIDKey])
                XCTAssertEqual(credentialID, "3q2-7wEj")
                XCTAssertEqual(base64URLDecode(credentialID), Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x23]))
                let userHandle = try XCTUnwrap(created.customFields[PasskeyCredential.userHandleKey])
                XCTAssertEqual(userHandle, "AAEC-_z9")
                XCTAssertEqual(base64URLDecode(userHandle), Data([0x00, 0x01, 0x02, 0xFB, 0xFC, 0xFD]))
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
                        // Fresh enrollment: the verbatim URI is what the entry
                        // editor stores when a setup link/QR is applied, so
                        // this artifact carries the feature's primary output.
                        totpConfig: .init(
                            secret: "JBSWY3DPEHPK3PXP",
                            period: 30,
                            digits: 6,
                            algorithm: .sha1,
                            otpauthURI: updateEntryEnrolledOTPAuthURI
                        ),
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
                XCTAssertEqual(
                    updated.otpURL,
                    updateEntryEnrolledOTPAuthURI,
                    "fresh enrollment must store the otpauth URI verbatim, KeePassXC-style"
                )
                XCTAssertTrue(updated.protectedStringKeys.contains("otp"))
                XCTAssertFalse(updated.customFields.keys.contains { $0.hasPrefix("TimeOtp-") })
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
                // The recycled entry is exempt only because recycling is a
                // move: its `<Times>/<LocationChanged>` advances. Everything
                // else about it must be identical, asserted field-for-field
                // below rather than by loosening the comparison.
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                let recycleBinID = try XCTUnwrap(before.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertTrue(recycleBin.entryIDs.contains(entryID))
                XCTAssertEqual(after.entries.count, before.entries.count)

                let beforeEntry = try XCTUnwrap(before.entries[entryID])
                let afterEntry = try XCTUnwrap(after.entries[entryID])
                assertOnlyLocationChangedDiffers(before: beforeEntry, after: afterEntry)
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
                // Only the recycled group moved, so only it is exempt — its
                // subtree did not move relative to it and must be untouched.
                try assertSurvivingGroupsPreserveScalars(before: before, after: after, excluding: [groupID])
                assertMetaUnchanged(before: before, after: after)
                let recycleBinID = try XCTUnwrap(before.meta.recycleBinUUID)
                let recycleBin = try XCTUnwrap(after.groups[recycleBinID])
                XCTAssertTrue(recycleBin.groupIDs.contains(groupID))
                XCTAssertEqual(after.groups.count, before.groups.count)

                let beforeGroup = try XCTUnwrap(before.groups[groupID])
                let afterGroup = try XCTUnwrap(after.groups[groupID])
                assertOnlyLocationChangedDiffers(before: beforeGroup, after: afterGroup)
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

    static func moveEntryScenario() -> Scenario {
        Scenario(
            id: "move-entry",
            title: "Move entry to another group",
            artifactFileName: "synthetic-rich-move-entry.kdbx",
            expectedSearchTerms: ["Compat Soft Delete Target"],
            expectedGroupPaths: ["Compat Group Delete Target/Compat Nested Child Group"],
            makeEdit: { loaded in
                let entry = try XCTUnwrap(findEntry(titled: "Compat Soft Delete Target", in: loaded.rootGroup))
                let destination = try XCTUnwrap(findGroup(named: "Compat Nested Child Group", in: loaded.rootGroup))
                return .moveEntry(entryID: entry.id, destinationGroupID: destination.id)
            },
            assertChange: { before, after, _ in
                let entryID = try XCTUnwrap(before.entryID(titled: "Compat Soft Delete Target"))
                let sourceID = try XCTUnwrap(before.groupID(named: "Compatibility Root"))
                let destinationID = try XCTUnwrap(before.groupID(named: "Compat Nested Child Group"))
                // A move reparents, so the moved entry's `<LocationChanged>` —
                // and nothing else about it — is allowed to differ.
                try assertUnchangedEntries(before: before, after: after, excluding: [entryID])
                assertOnlyLocationChangedDiffers(
                    before: try XCTUnwrap(before.entries[entryID]),
                    after: try XCTUnwrap(after.entries[entryID])
                )
                try assertSurvivingGroupsPreserveScalars(before: before, after: after)
                assertMetaUnchanged(before: before, after: after)
                XCTAssertTrue(try XCTUnwrap(after.groups[destinationID]).entryIDs.contains(entryID))
                XCTAssertFalse(try XCTUnwrap(after.groups[sourceID]).entryIDs.contains(entryID))
                XCTAssertEqual(after.entries.count, before.entries.count)
                XCTAssertEqual(after.groups.count, before.groups.count)
            }
        )
    }

    static func moveGroupScenario() -> Scenario {
        Scenario(
            id: "move-group",
            title: "Move group with its subtree to another group",
            artifactFileName: "synthetic-rich-move-group.kdbx",
            expectedSearchTerms: ["Compat Nested Entry"],
            expectedGroupPaths: ["Compat Nested Child Group"],
            makeEdit: { loaded in
                let group = try XCTUnwrap(findGroup(named: "Compat Nested Child Group", in: loaded.rootGroup))
                let destination = try XCTUnwrap(findGroup(named: "Compatibility Root", in: loaded.rootGroup))
                return .moveGroup(groupID: group.id, destinationGroupID: destination.id)
            },
            assertChange: { before, after, _ in
                let groupID = try XCTUnwrap(before.groupID(named: "Compat Nested Child Group"))
                let sourceID = try XCTUnwrap(before.groupID(named: "Compat Group Delete Target"))
                let destinationID = try XCTUnwrap(before.groupID(named: "Compatibility Root"))
                try assertUnchangedEntries(before: before, after: after)
                // Only the moved group changed parent, so only it is exempt —
                // its subtree did not move relative to it and must be untouched.
                try assertSurvivingGroupsPreserveScalars(before: before, after: after, excluding: [groupID])
                assertOnlyLocationChangedDiffers(
                    before: try XCTUnwrap(before.groups[groupID]),
                    after: try XCTUnwrap(after.groups[groupID])
                )
                assertMetaUnchanged(before: before, after: after)
                XCTAssertTrue(try XCTUnwrap(after.groups[destinationID]).groupIDs.contains(groupID))
                XCTAssertFalse(try XCTUnwrap(after.groups[sourceID]).groupIDs.contains(groupID))
                XCTAssertEqual(after.entries.count, before.entries.count)
                XCTAssertEqual(after.groups.count, before.groups.count)
            }
        )
    }

    static func makeSyntheticDatabase(
        cipherID: Data,
        hasRecycleBin: Bool,
        compositeKey: SymmetricKey,
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

        // Carries one stored `<History>` version so the restore scenario has something
        // to bring back; every scenario applies exactly one edit, so the history cannot
        // be produced inside the scenario itself.
        let restoreTargetEntry = KPEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000110")!,
            title: "Compat Restore Target",
            username: "current-user",
            password: try EncryptedValue.encrypt("current-password", using: sessionKey),
            url: "https://current.example.com",
            creationTime: timestamp,
            lastModificationTime: timestamp,
            history: [
                // A history version carries its parent's UUID, as KDBX requires.
                KPEntry(
                    id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000110")!,
                    title: "Compat Restore Target",
                    username: "previous-user",
                    password: try EncryptedValue.encrypt("previous-password", using: sessionKey),
                    url: "https://previous.example.com",
                    creationTime: timestamp,
                    lastModificationTime: timestamp.addingTimeInterval(-3_600)
                )
            ]
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
            entries: [updateTarget, softDeleteTarget, untouchedEntry, emptyTagsEntry, otpEntry, restoreTargetEntry],
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

    /// Mirrors a parsed group's `<EnableSearching>` state back into the draft
    /// payload, so a group edit that isn't about AutoFill visibility forwards
    /// the value verbatim instead of clearing it.
    static func inheritableBoolPayload(for value: KPInheritableBool?) -> InheritableBoolPayload? {
        switch value {
        case nil: return nil
        case .inherit: return .inherit
        case .enabled: return .enabled
        case .disabled: return .disabled
        }
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

    /// Pins the exact shape of a recycle: the object moved, so its
    /// `<Times>/<LocationChanged>` advanced past what it was and nothing else
    /// about it changed. Written as "equal after normalizing that one field"
    /// rather than as a shorter comparison, so a scenario that starts changing
    /// something else still fails.
    static func assertOnlyLocationChangedDiffers(
        before: CompatibilitySnapshot.Entry,
        after: CompatibilitySnapshot.Entry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertLocationChangedAdvanced(
            from: before.locationChanged,
            to: after.locationChanged,
            label: before.title,
            file: file,
            line: line
        )
        var normalized = after
        normalized.locationChanged = before.locationChanged
        XCTAssertEqual(normalized, before, "Recycled entry changed beyond its move: \(before.title)", file: file, line: line)
    }

    static func assertOnlyLocationChangedDiffers(
        before: CompatibilitySnapshot.Group,
        after: CompatibilitySnapshot.Group,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertLocationChangedAdvanced(
            from: before.locationChanged,
            to: after.locationChanged,
            label: before.name,
            file: file,
            line: line
        )
        var normalized = after.scalars
        normalized.locationChanged = before.locationChanged
        XCTAssertEqual(normalized, before.scalars, "Recycled group changed beyond its move: \(before.name)", file: file, line: line)
        XCTAssertEqual(after.entryIDs, before.entryIDs, file: file, line: line)
        XCTAssertEqual(after.groupIDs, before.groupIDs, file: file, line: line)
    }

    private static func assertLocationChangedAdvanced(
        from before: Date?,
        to after: Date?,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let moved = after else {
            XCTFail("\(label): a recycle must stamp <LocationChanged>", file: file, line: line)
            return
        }
        guard let before else { return }
        XCTAssertGreaterThan(
            moved,
            before,
            "\(label): <LocationChanged> must move forward when the object is recycled",
            file: file,
            line: line
        )
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
