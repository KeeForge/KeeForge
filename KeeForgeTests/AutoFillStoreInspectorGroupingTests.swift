// Identities are hand-built with current / legacy / garbage record identifiers,
// mirroring CredentialIdentityStoreManagerTests — no KPEntry, no store.
#if DEBUG
@preconcurrency import AuthenticationServices
import XCTest
@testable import KeeForge

@MainActor
final class AutoFillStoreInspectorGroupingTests: XCTestCase {
    // MARK: - row(for:)

    func testRowExtractsPasswordMetadata() {
        let identity = passwordIdentity(
            domain: "github.com",
            user: "octocat",
            recordIdentifier: current(UUID(), UUID())
        )
        let row = AutoFillStoreInspectorGrouping.row(for: identity)

        XCTAssertEqual(row.serviceIdentifier, "github.com")
        XCTAssertEqual(row.label, "octocat")
        XCTAssertEqual(row.kind, .password)
    }

    func testRowExtractsPasskeyMetadata() {
        let identity = passkeyIdentity(
            relyingParty: "example.com",
            userName: "alice@example.com",
            recordIdentifier: current(UUID(), UUID())
        )
        let row = AutoFillStoreInspectorGrouping.row(for: identity)

        XCTAssertEqual(row.serviceIdentifier, "example.com")
        XCTAssertEqual(row.label, "alice@example.com")
        XCTAssertEqual(row.kind, .passkey)
    }

    func testRowExtractsOneTimeCodeMetadata() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time code identities require iOS 18 / macOS 15")
        }
        let identity = ASOneTimeCodeCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(identifier: "totp.example.com", type: .domain),
            label: "TOTP Label",
            recordIdentifier: current(UUID(), UUID())
        )
        let row = AutoFillStoreInspectorGrouping.row(for: identity)

        XCTAssertEqual(row.serviceIdentifier, "totp.example.com")
        XCTAssertEqual(row.label, "TOTP Label")
        XCTAssertEqual(row.kind, .oneTimeCode)
    }

    // MARK: - makeBuckets

    func testEmptyStoreYieldsEmptyBuckets() {
        let result = AutoFillStoreInspectorGrouping.makeBuckets(from: []) { _ in nil }

        XCTAssertTrue(result.databaseBuckets.isEmpty)
        XCTAssertTrue(result.legacyRows.isEmpty)
        XCTAssertTrue(result.unrecognizedRows.isEmpty)
    }

    func testMixedTagsGroupByDatabaseLegacyAndUnrecognized() {
        let databaseA = UUID()
        let databaseB = UUID()
        let legacyID = UUID().uuidString

        let identities: [any ASCredentialIdentity] = [
            passwordIdentity(domain: "a1.com", user: "a1", recordIdentifier: current(databaseA, UUID())),
            passwordIdentity(domain: "a2.com", user: "a2", recordIdentifier: current(databaseA, UUID())),
            passwordIdentity(domain: "b1.com", user: "b1", recordIdentifier: current(databaseB, UUID())),
            passwordIdentity(domain: "legacy.com", user: "legacy", recordIdentifier: legacyID),
            passwordIdentity(domain: "garbage.com", user: "garbage", recordIdentifier: "not-an-identifier"),
        ]

        let names: [UUID: String] = [databaseA: "Alpha", databaseB: "Bravo"]
        let result = AutoFillStoreInspectorGrouping.makeBuckets(from: identities) { names[$0] }

        XCTAssertEqual(result.databaseBuckets.count, 2)

        let bucketA = result.databaseBuckets.first { $0.databaseID == databaseA }
        XCTAssertEqual(bucketA?.count, 2)
        XCTAssertEqual(Set((bucketA?.rows ?? []).map(\.serviceIdentifier)), ["a1.com", "a2.com"])
        XCTAssertEqual(bucketA?.displayName, "Alpha")

        let bucketB = result.databaseBuckets.first { $0.databaseID == databaseB }
        XCTAssertEqual(bucketB?.count, 1)

        XCTAssertEqual(result.legacyRows.count, 1)
        XCTAssertEqual(result.legacyRows.first?.serviceIdentifier, "legacy.com")
        XCTAssertEqual(result.unrecognizedRows.count, 1)
        XCTAssertEqual(result.unrecognizedRows.first?.serviceIdentifier, "garbage.com")
    }

    func testRegisteredDatabaseResolvesNameUnregisteredFallsBackToUUID() {
        let registered = UUID()
        let unregistered = UUID()

        let identities: [any ASCredentialIdentity] = [
            passwordIdentity(domain: "r.com", user: "r", recordIdentifier: current(registered, UUID())),
            passwordIdentity(domain: "u.com", user: "u", recordIdentifier: current(unregistered, UUID())),
        ]

        let names: [UUID: String] = [registered: "My Vault"]
        let result = AutoFillStoreInspectorGrouping.makeBuckets(from: identities) { names[$0] }

        let registeredBucket = result.databaseBuckets.first { $0.databaseID == registered }
        XCTAssertEqual(registeredBucket?.displayName, "My Vault")

        let unregisteredBucket = result.databaseBuckets.first { $0.databaseID == unregistered }
        XCTAssertEqual(unregisteredBucket?.displayName, unregistered.uuidString)
    }

    func testDatabaseBucketsAreSortedByDisplayNameThenUUID() {
        let databaseA = UUID()
        let databaseB = UUID()

        let identities: [any ASCredentialIdentity] = [
            passwordIdentity(domain: "z.com", user: "z", recordIdentifier: current(databaseB, UUID())),
            passwordIdentity(domain: "a.com", user: "a", recordIdentifier: current(databaseA, UUID())),
        ]

        // databaseB is encountered first but sorts after by display name.
        let names: [UUID: String] = [databaseA: "Apples", databaseB: "Zucchini"]
        let result = AutoFillStoreInspectorGrouping.makeBuckets(from: identities) { names[$0] }

        XCTAssertEqual(result.databaseBuckets.map(\.displayName), ["Apples", "Zucchini"])
    }

    // MARK: - makeSnapshot

    func testSnapshotDisabledEmptyStore() {
        let snapshot = AutoFillStoreInspectorGrouping.makeSnapshot(
            isEnabled: false,
            supportsIncrementalUpdates: false,
            identities: []
        ) { _ in nil }

        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertFalse(snapshot.supportsIncrementalUpdates)
        XCTAssertEqual(snapshot.totalCount, 0)
        XCTAssertTrue(snapshot.databaseBuckets.isEmpty)
    }

    func testSnapshotCountsAndBuckets() {
        let databaseA = UUID()
        let identities: [any ASCredentialIdentity] = [
            passwordIdentity(domain: "a1.com", user: "a1", recordIdentifier: current(databaseA, UUID())),
            passwordIdentity(domain: "a2.com", user: "a2", recordIdentifier: current(databaseA, UUID())),
            passwordIdentity(domain: "legacy.com", user: "legacy", recordIdentifier: UUID().uuidString),
        ]

        let snapshot = AutoFillStoreInspectorGrouping.makeSnapshot(
            isEnabled: true,
            supportsIncrementalUpdates: true,
            identities: identities
        ) { _ in "Vault" }

        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertTrue(snapshot.supportsIncrementalUpdates)
        XCTAssertEqual(snapshot.totalCount, 3)
        XCTAssertEqual(snapshot.databaseBuckets.count, 1)
        XCTAssertEqual(snapshot.databaseBuckets.first?.count, 2)
        XCTAssertEqual(snapshot.legacyRows.count, 1)
        XCTAssertTrue(snapshot.unrecognizedRows.isEmpty)
    }

    // MARK: - Builders

    private func current(_ databaseID: UUID, _ entryID: UUID) -> String {
        CredentialRecordIdentifier(databaseID: databaseID, entryID: entryID).encoded
    }

    private func passwordIdentity(
        domain: String,
        user: String,
        recordIdentifier: String
    ) -> ASPasswordCredentialIdentity {
        ASPasswordCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
            user: user,
            recordIdentifier: recordIdentifier
        )
    }

    private func passkeyIdentity(
        relyingParty: String,
        userName: String,
        recordIdentifier: String
    ) -> ASPasskeyCredentialIdentity {
        ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: relyingParty,
            userName: userName,
            credentialID: Data([0x01, 0x02, 0x03]),
            userHandle: Data([0x04, 0x05, 0x06]),
            recordIdentifier: recordIdentifier
        )
    }
}
#endif
