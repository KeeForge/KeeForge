import CryptoKit
import Foundation
import XCTest
@testable import KeeForge

enum KDBXCompatibilitySupport {
    static let artifactManifestName = "kdbx-compatibility-manifest.json"

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
    }

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
            let before = try CompatibilitySnapshot(rootGroup: loaded.rootGroup, meta: loaded.meta, sessionKey: loaded.sessionKey)
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
            let after = try CompatibilitySnapshot(
                rootGroup: reparsed.rootGroup,
                meta: reparsed.meta,
                sessionKey: loaded.sessionKey
            )

            try assertChange(before, after, loaded)
            return ScenarioResult(written: written, before: before, after: after)
        }
    }

    struct ScenarioResult {
        let written: Data
        let before: CompatibilitySnapshot
        let after: CompatibilitySnapshot
    }

    struct ArtifactManifest: Codable {
        struct Artifact: Codable {
            let id: String
            let fileName: String
            let password: String
            let keyFileName: String?
            let expectedSearchTerms: [String]
            let expectedGroupPaths: [String]
        }

        let artifacts: [Artifact]
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
            expectedGroupPaths: ["Recycle Bin"],
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
                XCTAssertEqual(recycleBinGroup.name, "Recycle Bin")
                XCTAssertTrue(recycleBinGroup.entryIDs.contains(entryID))
                XCTAssertEqual(after.entries.count, before.entries.count)
                XCTAssertEqual(after.groups.count, before.groups.count + 1)
            }
        )
    }

    static func fixtureSmokeScenario(fixtureID: String) -> Scenario {
        let createdTitle = "Compat Smoke \(fixtureID)"
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
                        password: "compat-secret",
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

    static func artifactPlans(bundle: Bundle) throws -> [(fixture: LoadedFixture, scenario: Scenario)] {
        var plans: [(LoadedFixture, Scenario)] = []

        let richFixture = try load(.syntheticRich, bundle: bundle)
        for scenario in fullEditScenarios() {
            plans.append((richFixture, scenario))
        }

        let noRecycleBinFixture = try load(.syntheticNoRecycleBin, bundle: bundle)
        plans.append((noRecycleBinFixture, recycleBinCreationScenario()))

        let smokeFixtures: [Fixture] = [.aesBaseline, .passwordKeyfile, .unknownRich, .kdbx41PublicCustomData, .syntheticChaCha]
        for fixture in smokeFixtures {
            let loaded = try load(fixture, bundle: bundle)
            plans.append((loaded, fixtureSmokeScenario(fixtureID: fixture.id)))
        }

        return plans
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
        let totp: TOTP?
        let otpURL: String?
        let creationTime: Date?
        let lastModificationTime: Date?
        var history: [Entry]
        let unknownXML: OpaqueXMLNodes
        let protectedStringKeys: Set<String>
        let attachments: [KPAttachment]
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
        let isExpanded: Bool
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
                isExpanded: isExpanded,
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
        let isExpanded: Bool
        let creationTime: Date?
        let lastModificationTime: Date?
        let recycleBinUUID: UUID?
        let unknownXML: OpaqueXMLNodes
    }

    let entries: [UUID: Entry]
    let groups: [UUID: Group]
    let meta: KPMeta

    init(rootGroup: KPGroup, meta: KPMeta, sessionKey: SymmetricKey) throws {
        var entries: [UUID: Entry] = [:]
        var groups: [UUID: Group] = [:]
        try Self.capture(group: rootGroup, sessionKey: sessionKey, entries: &entries, groups: &groups)
        self.entries = entries
        self.groups = groups
        self.meta = meta
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
        entries: inout [UUID: Entry],
        groups: inout [UUID: Group]
    ) throws {
        let capturedGroup = Group(
            id: group.id,
            name: group.name,
            iconID: group.iconID,
            isExpanded: group.isExpanded,
            creationTime: group.creationTime,
            lastModificationTime: group.lastModificationTime,
            recycleBinUUID: group.recycleBinUUID,
            unknownXML: group.unknownXML,
            entryIDs: group.entries.map(\.id),
            groupIDs: group.groups.map(\.id)
        )
        groups[group.id] = capturedGroup

        for entry in group.entries {
            entries[entry.id] = try capture(entry: entry, sessionKey: sessionKey)
        }

        for child in group.groups {
            try capture(group: child, sessionKey: sessionKey, entries: &entries, groups: &groups)
        }
    }

    private static func capture(entry: KPEntry, sessionKey: SymmetricKey) throws -> Entry {
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
            totp: capturedTOTP,
            otpURL: entry.otpURL,
            creationTime: entry.creationTime,
            lastModificationTime: entry.lastModificationTime,
            history: try entry.history.map { try capture(entry: $0, sessionKey: sessionKey) },
            unknownXML: entry.unknownXML,
            protectedStringKeys: entry.protectedStringKeys,
            attachments: entry.attachments
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
                XCTAssertEqual(created.customFields[PasskeyCredential.privateKeyPEMKey], "created-private-key")
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
                XCTAssertEqual(updated.customFields[PasskeyCredential.privateKeyPEMKey], original.customFields[PasskeyCredential.privateKeyPEMKey])
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

    static func assertMetaUnchanged(
        before: CompatibilitySnapshot,
        after: CompatibilitySnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.meta, before.meta, file: file, line: line)
    }
}
