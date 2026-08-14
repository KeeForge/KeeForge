import CryptoKit
import XCTest
@testable import KeeForge

/// `KDBXMerger` against real KeePassXC output.
///
/// Every scenario under `TestFixtures/Merge/` is a `local.kdbx` / `remote.kdbx`
/// pair plus `merged-reference.kdbx`, the file `keepassxc-cli merge -s`
/// produced from that pair. The suite parses all three with one session key,
/// merges, and compares the engine's tree to the reference *semantically*:
/// objects are matched by UUID, so sibling order never enters the comparison,
/// and timestamps compare at the one-second granularity KDBX stores.
///
/// The reference is not authoritative everywhere. `keepassxc-cli` runs
/// KeePassXC's `Merger` in KeepNewer mode (there is no CLI flag for
/// Synchronize), so it never applies `DeletedObjects`, never adopts
/// `Meta/RecycleBinUUID`, and leaves a merge-moved entry's `LocationChanged`
/// stale. Those three gaps are handled explicitly below — the spec outcome is
/// asserted instead of the reference — and every remaining aspect is compared
/// against real KeePassXC behaviour.
///
/// Deliberately outside the comparison: element-presence flags
/// (`hasNotesElement`, `hasTagsElement`, `searchingEnabled`, `isExpanded`) and
/// `unknownXML`. The reference was rewritten end to end by KeePassXC's
/// serializer, so those reflect its authoring conventions rather than the
/// merge; KeeForge's own preservation of them is pinned by
/// `KDBXRoundTripTests` and by `KDBXMergerTests`' verbatim-graft test.
///
/// Scenario enumeration is driven by `Merge/manifest.json`, so a new fixture
/// scenario needs no edit here unless it declares an oracle deviation.
final class KDBXMergerOracleTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: Self.self) }

    // MARK: - Per-scenario expectations the oracle cannot supply

    /// What the algorithm spec requires where `merged-reference.kdbx` shows
    /// something else. Required for (and only for) scenarios the fixture
    /// manifest flags `oracleMatchesSpec: false`.
    private struct SpecOutcome: Sendable {
        /// Objects the reference gets wrong, excluded from the tree
        /// comparison and asserted through the fields below instead.
        var excludedObjects: Set<String> = []
        var aliveObjects: Set<String> = []
        var deletedObjects: Set<String> = []
        var tombstonedObjects: Set<String> = []
        var tombstoneFreeObjects: Set<String> = []
        /// Local had no recycle bin and adopts the remote's UUID (spec step
        /// 6b); the reference keeps an all-zero `RecycleBinUUID`.
        var adoptsRemoteRecycleBinUUID = false
    }

    /// Keys are `manifest.baseTree` paths, resolved to the fixed fixture UUIDs.
    private static let specOutcomes: [String: SpecOutcome] = [
        // Local deleted Alpha, remote edited it afterwards: it comes back and
        // takes the tombstone with it. The reference resurrects it too, but
        // keeps the tombstone next to the live entry.
        "delete-local-then-edit-remote": SpecOutcome(
            aliveObjects: ["/Work/Alpha"],
            tombstoneFreeObjects: ["/Work/Alpha"]
        ),
        // Remote edited Alpha, local deleted it afterwards: it stays deleted
        // and the tombstone propagates. The reference re-adds it.
        "edit-remote-then-delete-local": SpecOutcome(
            excludedObjects: ["/Work/Alpha"],
            deletedObjects: ["/Work/Alpha"],
            tombstonedObjects: ["/Work/Alpha"]
        ),
        // Mirror direction of the same rule.
        "edit-local-then-delete-remote": SpecOutcome(
            excludedObjects: ["/Work/Alpha"],
            deletedObjects: ["/Work/Alpha"],
            tombstonedObjects: ["/Work/Alpha"]
        ),
        "recycle-vs-edit": SpecOutcome(adoptsRemoteRecycleBinUUID: true),
    ]

    /// Divergent binary pools with live attachment references: the writer
    /// re-emits the pool of the file it replaces and cannot renumber refs, so
    /// the engine declines instead of grafting a ref that could dangle.
    private static let decliningScenarioIDs: Set<String> = ["attachment-divergence"]

    /// Scenarios whose two sides hold the same content, so the merge is a
    /// no-op and must not mark the database dirty.
    private static let unchangedScenarioIDs: Set<String> = ["identical-no-changes"]

    // MARK: - Coverage

    func test_manifestAndScenarioDirectories_coverEachOther() throws {
        let manifest = try loadManifest()
        let directory = try mergeFixtureDirectory()

        let onDisk = Set(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
        )
        let declared = Set(manifest.scenarios.map(\.id))

        XCTAssertFalse(declared.isEmpty, "the merge fixture manifest declares no scenarios")
        XCTAssertEqual(
            onDisk,
            declared,
            "every TestFixtures/Merge/<scenario> directory must be declared in manifest.json and vice versa"
        )

        for scenario in manifest.scenarios {
            for name in ["local", "remote", "merged-reference"] {
                let url = directory
                    .appendingPathComponent(scenario.id, isDirectory: true)
                    .appendingPathComponent("\(name).kdbx")
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: url.path),
                    "\(scenario.id) is missing \(name).kdbx"
                )
            }
        }

        // Fail-closed, like the compatibility gate's expectation tables: a
        // scenario that declares an oracle deviation must say what the spec
        // requires instead, and a stale entry here must not survive a rename.
        XCTAssertEqual(
            Set(Self.specOutcomes.keys),
            Set(manifest.scenarios.filter { !$0.oracleMatchesSpec }.map(\.id)),
            "every oracleMatchesSpec:false scenario needs a SpecOutcome, and only those"
        )
        XCTAssertTrue(Self.decliningScenarioIDs.isSubset(of: declared))
        XCTAssertTrue(Self.unchangedScenarioIDs.isSubset(of: declared))
    }

    // MARK: - The oracle sweep

    func test_everyScenario_matchesTheOracleAndTheSpec() throws {
        let manifest = try loadManifest()

        // One scenario's failure must not hide the rest, so a thrown error is
        // reported and the sweep continues. Every assertion names its scenario.
        for scenario in manifest.scenarios {
            do {
                try verify(scenario, manifest: manifest)
            } catch {
                XCTFail("\(scenario.id): \(error)")
            }
        }
    }

    private func verify(_ scenario: Manifest.ScenarioEntry, manifest: Manifest) throws {
        let sessionKey = SymmetricKey(size: .bits256)
        let directory = try mergeFixtureDirectory().appendingPathComponent(scenario.id, isDirectory: true)

        func parse(_ name: String) throws -> (rootGroup: KPGroup, meta: KPMeta, header: KDBXParser.Header) {
            try KDBXParser.parseWithMetaAndHeader(
                data: try Data(contentsOf: directory.appendingPathComponent("\(name).kdbx")),
                password: manifest.password,
                sessionKey: sessionKey
            )
        }

        let localParse = try parse("local")
        let remoteParse = try parse("remote")
        let localSide = KDBXMerger.Side(
            rootGroup: localParse.rootGroup,
            meta: localParse.meta,
            binaryPoolFields: localParse.header.innerHeaderBinaryFields
        )
        let remoteSide = KDBXMerger.Side(
            rootGroup: remoteParse.rootGroup,
            meta: remoteParse.meta,
            binaryPoolFields: remoteParse.header.innerHeaderBinaryFields
        )

        let outcome = try KDBXMerger.merge(local: localSide, remote: remoteSide, sessionKey: sessionKey)

        guard !Self.decliningScenarioIDs.contains(scenario.id) else {
            guard case .declined(let blockers) = outcome else {
                XCTFail("\(scenario.id): expected the merge to be declined")
                return
            }
            XCTAssertEqual(blockers, [.attachmentPoolDivergence], "\(scenario.id): unexpected blockers")
            return
        }
        guard case .merged(let merged) = outcome else {
            XCTFail("\(scenario.id): expected a merged result, got \(outcome)")
            return
        }

        let local = try SemanticTree(rootGroup: localParse.rootGroup, meta: localParse.meta, sessionKey: sessionKey)
        let remote = try SemanticTree(rootGroup: remoteParse.rootGroup, meta: remoteParse.meta, sessionKey: sessionKey)
        let result = try SemanticTree(rootGroup: merged.rootGroup, meta: merged.meta, sessionKey: sessionKey)

        if Self.unchangedScenarioIDs.contains(scenario.id) {
            XCTAssertFalse(
                merged.summary.hasChanges,
                "\(scenario.id): identical sides must not report a change"
            )
            assertSemanticallyEqual(result, local, excluding: [], scenario: scenario.id, oracleName: "local.kdbx")
        }

        let spec = Self.specOutcomes[scenario.id] ?? SpecOutcome()
        let excluded = try Set(spec.excludedObjects.map { try objectID(for: $0, manifest: manifest) })

        let referenceParse = try parse("merged-reference")
        let reference = try SemanticTree(
            rootGroup: referenceParse.rootGroup,
            meta: referenceParse.meta,
            sessionKey: sessionKey
        )
        assertSemanticallyEqual(
            result,
            reference,
            excluding: excluded,
            scenario: scenario.id,
            oracleName: "merged-reference.kdbx"
        )
        assertEntryLocations(result, reference: reference, local: local, remote: remote, scenario: scenario.id)

        try assertSpecOutcome(
            spec,
            result: result,
            remote: remote,
            localRecycleBinUUID: local.recycleBinUUID,
            scenario: scenario,
            manifest: manifest
        )
        assertTombstonesResolve(result, local: local, remote: remote, scenario: scenario.id)
        try assertIdempotent(
            merged,
            localSide: localSide,
            remoteSide: remoteSide,
            sessionKey: sessionKey,
            expected: result,
            scenario: scenario.id
        )
    }

    // MARK: - Comparisons

    private func assertSemanticallyEqual(
        _ result: SemanticTree,
        _ oracle: SemanticTree,
        excluding excluded: Set<UUID>,
        scenario: String,
        oracleName: String
    ) {
        let resultGroups = Set(result.groups.keys).subtracting(excluded)
        let oracleGroups = Set(oracle.groups.keys).subtracting(excluded)
        XCTAssertEqual(
            resultGroups,
            oracleGroups,
            "\(scenario): merged groups differ from \(oracleName) "
            + "(missing \(oracleGroups.subtracting(resultGroups)), extra \(resultGroups.subtracting(oracleGroups)))"
        )
        for id in resultGroups.intersection(oracleGroups) {
            XCTAssertEqual(
                result.groups[id],
                oracle.groups[id],
                "\(scenario): group \(id) differs from \(oracleName)"
            )
        }

        let resultEntries = Set(result.entries.keys).subtracting(excluded)
        let oracleEntries = Set(oracle.entries.keys).subtracting(excluded)
        XCTAssertEqual(
            resultEntries,
            oracleEntries,
            "\(scenario): merged entries differ from \(oracleName) "
            + "(missing \(oracleEntries.subtracting(resultEntries)), extra \(resultEntries.subtracting(oracleEntries)))"
        )
        for id in resultEntries.intersection(oracleEntries) {
            // `locationChanged` is compared separately: KeePassXC reparents an
            // entry without adopting the source value.
            XCTAssertEqual(
                result.entries[id]?.ignoringLocationChanged,
                oracle.entries[id]?.ignoringLocationChanged,
                "\(scenario): entry \(id) differs from \(oracleName)"
            )
        }
    }

    /// `Merger` adopts a moved *group*'s `LocationChanged` but not a moved
    /// entry's, so the reference keeps the stale local value there. KeeForge
    /// adopts it (spec step 5); for every entry the merge did not move, the
    /// reference is authoritative.
    private func assertEntryLocations(
        _ result: SemanticTree,
        reference: SemanticTree,
        local: SemanticTree,
        remote: SemanticTree,
        scenario: String
    ) {
        for (id, entry) in result.entries {
            let movedByMerge = local.entries[id].map { $0.parentID != entry.parentID } ?? false
            guard movedByMerge else {
                guard let referenceEntry = reference.entries[id] else { continue }
                XCTAssertEqual(
                    entry.locationChanged,
                    referenceEntry.locationChanged,
                    "\(scenario): entry \(id) LocationChanged differs from merged-reference.kdbx"
                )
                continue
            }
            XCTAssertEqual(
                entry.locationChanged,
                remote.entries[id]?.locationChanged,
                "\(scenario): a merge-moved entry must adopt the remote LocationChanged"
            )
        }
    }

    private func assertSpecOutcome(
        _ spec: SpecOutcome,
        result: SemanticTree,
        remote: SemanticTree,
        localRecycleBinUUID: UUID?,
        scenario: Manifest.ScenarioEntry,
        manifest: Manifest
    ) throws {
        for path in spec.aliveObjects {
            let id = try objectID(for: path, manifest: manifest)
            XCTAssertTrue(result.contains(id), "\(scenario.id): \(path) must survive the merge")
        }
        for path in spec.deletedObjects {
            let id = try objectID(for: path, manifest: manifest)
            XCTAssertFalse(result.contains(id), "\(scenario.id): \(path) must not survive the merge")
        }
        for path in spec.tombstonedObjects {
            let id = try objectID(for: path, manifest: manifest)
            XCTAssertNotNil(
                result.tombstones[id],
                "\(scenario.id): \(path)'s tombstone must be kept so the deletion reaches a third replica"
            )
        }
        for path in spec.tombstoneFreeObjects {
            let id = try objectID(for: path, manifest: manifest)
            XCTAssertNil(
                result.tombstones[id],
                "\(scenario.id): \(path) was edited after its deletion, so its tombstone must be dropped"
            )
        }
        // v1 keeps local Meta except the recycle-bin UUID, which is adopted
        // when local has none (spec step 6b) — otherwise the bin group would
        // arrive through the tree walk with nothing recognizing it as a bin.
        // KeePassXC never adopts it (explicit TODO in `mergeMetadata`), so the
        // reference cannot judge this field for any scenario.
        XCTAssertEqual(
            result.recycleBinUUID,
            localRecycleBinUUID ?? remote.recycleBinUUID,
            "\(scenario.id): merged RecycleBinUUID must be local's, or the remote's when local had none"
        )

        guard spec.adoptsRemoteRecycleBinUUID else { return }
        XCTAssertNil(localRecycleBinUUID, "\(scenario.id): fixture precondition — local has no recycle bin")
        XCTAssertNotNil(remote.recycleBinUUID, "\(scenario.id): fixture precondition — remote has one")
    }

    /// The merged tombstone list holds exactly the tombstones whose object is
    /// not live in the merged tree: an object that outlived its deletion takes
    /// its tombstone with it, and a group kept alive by surviving content does
    /// the same. Applies to every scenario, which is what the reference — with
    /// no deletion pass at all — can never show.
    private func assertTombstonesResolve(
        _ result: SemanticTree,
        local: SemanticTree,
        remote: SemanticTree,
        scenario: String
    ) {
        var union: [UUID: Date] = [:]
        for side in [local.tombstones, remote.tombstones] {
            for (id, deletionTime) in side {
                union[id] = union[id].map { min($0, deletionTime) } ?? deletionTime
            }
        }

        for (id, deletionTime) in union {
            if result.contains(id) {
                XCTAssertNil(
                    result.tombstones[id],
                    "\(scenario): \(id) is live in the merged tree, so its tombstone must be gone"
                )
            } else {
                XCTAssertEqual(
                    result.tombstones[id],
                    deletionTime,
                    "\(scenario): \(id) is deleted, so its tombstone must survive at the earliest deletion time"
                )
            }
        }

        XCTAssertTrue(
            Set(result.tombstones.keys).isSubset(of: Set(union.keys)),
            "\(scenario): the merge invented tombstones neither side had"
        )
    }

    private func assertIdempotent(
        _ merged: KDBXMerger.Merged,
        localSide: KDBXMerger.Side,
        remoteSide: KDBXMerger.Side,
        sessionKey: SymmetricKey,
        expected: SemanticTree,
        scenario: String
    ) throws {
        let second = try KDBXMerger.merge(
            local: KDBXMerger.Side(
                rootGroup: merged.rootGroup,
                meta: merged.meta,
                binaryPoolFields: localSide.binaryPoolFields
            ),
            remote: remoteSide,
            sessionKey: sessionKey
        )
        guard case .merged(let again) = second else {
            XCTFail("\(scenario): re-merging the merged result must not decline")
            return
        }

        XCTAssertFalse(
            again.summary.hasChanges,
            "\(scenario): merging the same remote twice must report no second change, got \(again.summary)"
        )
        let repeated = try SemanticTree(rootGroup: again.rootGroup, meta: again.meta, sessionKey: sessionKey)
        assertSemanticallyEqual(
            repeated,
            expected,
            excluding: [],
            scenario: scenario,
            oracleName: "the first merge"
        )
    }

    // MARK: - Semantic tree

    /// Merge-relevant facts of one database, keyed by UUID. Objects are
    /// matched by identity rather than position, so sibling order — an
    /// artefact of how the reference's writer re-appended a conflict winner —
    /// never reaches an assertion.
    private struct SemanticTree {
        /// One version of an entry: what it holds, not where it lives.
        struct Version: Equatable {
            var title: String
            var username: String
            var password: String
            var url: String
            var notes: String
            var iconID: Int
            var customIconUUID: UUID?
            var tags: [String]
            var customFields: [String: String]
            var otpURL: String?
            var totp: String?
            var expires: Bool
            var expiryTime: Date?
            var creationTime: Date?
            var lastModificationTime: Date?
            var attachments: [String]
        }

        struct EntryFacts: Equatable {
            var parentID: UUID
            var current: Version
            /// Order matters: history is a chronology, not a set.
            var history: [Version]
            var locationChanged: Date?

            var ignoringLocationChanged: EntryFacts {
                var copy = self
                copy.locationChanged = nil
                return copy
            }
        }

        struct GroupFacts: Equatable {
            var parentID: UUID?
            var name: String
            var notes: String
            var iconID: Int
            var customIconUUID: UUID?
            var tags: [String]
            var creationTime: Date?
            var lastModificationTime: Date?
            var locationChanged: Date?
        }

        var groups: [UUID: GroupFacts] = [:]
        var entries: [UUID: EntryFacts] = [:]
        var tombstones: [UUID: Date] = [:]
        var recycleBinUUID: UUID?

        init(rootGroup: KPGroup, meta: KPMeta, sessionKey: SymmetricKey) throws {
            recycleBinUUID = meta.recycleBinUUID
            for tombstone in meta.deletedObjects {
                tombstones[tombstone.uuid] = KDBXMerger.truncatedToSeconds(tombstone.deletionTime)
            }
            try capture(rootGroup, parentID: nil, sessionKey: sessionKey)
        }

        func contains(_ id: UUID) -> Bool {
            entries[id] != nil || groups[id] != nil
        }

        private mutating func capture(_ group: KPGroup, parentID: UUID?, sessionKey: SymmetricKey) throws {
            groups[group.id] = GroupFacts(
                parentID: parentID,
                name: group.name,
                notes: group.notes,
                iconID: group.iconID,
                customIconUUID: group.customIconUUID,
                tags: group.tags,
                creationTime: Self.seconds(group.creationTime),
                lastModificationTime: Self.seconds(group.lastModificationTime),
                locationChanged: Self.seconds(group.locationChanged)
            )

            for entry in group.entries {
                entries[entry.id] = EntryFacts(
                    parentID: group.id,
                    current: try Self.version(of: entry, sessionKey: sessionKey),
                    history: try entry.history.map { try Self.version(of: $0, sessionKey: sessionKey) },
                    locationChanged: Self.seconds(entry.locationChanged)
                )
            }

            for child in group.groups {
                try capture(child, parentID: group.id, sessionKey: sessionKey)
            }
        }

        private static func version(of entry: KPEntry, sessionKey: SymmetricKey) throws -> Version {
            var totp: String?
            if let config = entry.totpConfig {
                totp = [
                    try config.secret.decrypt(using: sessionKey),
                    String(config.period),
                    String(config.digits),
                    config.algorithm.rawValue,
                ].joined(separator: "|")
            }

            return Version(
                title: entry.title,
                username: entry.username,
                password: try entry.password.decrypt(using: sessionKey),
                url: entry.url,
                notes: entry.notes,
                iconID: entry.iconID,
                customIconUUID: entry.customIconUUID,
                tags: entry.tags,
                customFields: entry.customFields,
                otpURL: entry.otpURL,
                totp: totp,
                expires: entry.expires,
                expiryTime: seconds(entry.expiryTime),
                creationTime: seconds(entry.creationTime),
                lastModificationTime: seconds(entry.lastModificationTime),
                attachments: entry.attachments.map { "\($0.name)#\($0.ref)" }
            )
        }

        private static func seconds(_ date: Date?) -> Date? {
            date.map(KDBXMerger.truncatedToSeconds)
        }
    }

    // MARK: - Fixtures

    private struct Manifest: Decodable {
        let password: String
        let baseTree: BaseTree
        let scenarios: [ScenarioEntry]

        struct BaseTree: Decodable {
            let groups: [String: String]
            let entries: [String: EntryIdentity]

            struct EntryIdentity: Decodable {
                let uuid: String
            }
        }

        struct ScenarioEntry: Decodable {
            let id: String
            let oracleMatchesSpec: Bool
        }
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case missingDirectory
        case unknownObjectPath(String)
        case malformedUUID(String)

        var description: String {
            switch self {
            case .missingDirectory:
                return """
                The merge fixtures are not in the test bundle. TestFixtures/Merge is registered in \
                project.yml as a folder reference (the scenario directories share file names); \
                re-run `xcodegen generate`.
                """
            case .unknownObjectPath(let path):
                return "'\(path)' is not a group or entry in the fixture manifest's baseTree."
            case .malformedUUID(let value):
                return "'\(value)' is not a UUID."
            }
        }
    }

    private func mergeFixtureDirectory() throws -> URL {
        let directory = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("Merge", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw FixtureError.missingDirectory
        }
        return directory
    }

    private func loadManifest() throws -> Manifest {
        let url = try mergeFixtureDirectory().appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: try Data(contentsOf: url))
    }

    /// Resolves a `baseTree` path (`/Work/Alpha`, `Work`) to its fixed UUID.
    private func objectID(for path: String, manifest: Manifest) throws -> UUID {
        let raw = manifest.baseTree.entries[path]?.uuid ?? manifest.baseTree.groups[path]
        guard let raw else { throw FixtureError.unknownObjectPath(path) }
        guard let uuid = UUID(uuidString: raw) else { throw FixtureError.malformedUUID(raw) }
        return uuid
    }
}
