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
        let databaseA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let databaseB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let identities: [any ASCredentialIdentity] = [
            passwordIdentity(domain: "z.com", user: "z", recordIdentifier: current(databaseB, UUID())),
            passwordIdentity(domain: "a.com", user: "a", recordIdentifier: current(databaseA, UUID())),
        ]

        // databaseB is encountered first but sorts after by display name.
        let names: [UUID: String] = [databaseA: "Apples", databaseB: "Zucchini"]
        let result = AutoFillStoreInspectorGrouping.makeBuckets(from: identities) { names[$0] }

        XCTAssertEqual(result.databaseBuckets.map(\.displayName), ["Apples", "Zucchini"])

        let tied = AutoFillStoreInspectorGrouping.makeBuckets(from: identities) { _ in "Same name" }
        XCTAssertEqual(tied.databaseBuckets.map(\.databaseID), [databaseA, databaseB])
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

    func testInspectorReadFailsForUnreadableStore() async {
        let fake = FakeCredentialIdentityStore()
        fake.enumerationError = .nonConformingIdentities(count: 2)
        do {
            _ = try await AutoFillStoreInspectorViewModel.buildSnapshot(store: fake, capabilities: await fake.capabilities()) { _ in nil }
            XCTFail("An unreadable store must not produce an empty snapshot")
        } catch {
            XCTAssertEqual(error as? CredentialIdentityStoreReadError, .nonConformingIdentities(count: 2))
        }
    }

    func testInspectorReadAcceptsGenuinelyEmptyStore() async throws {
        let fake = FakeCredentialIdentityStore()
        let snapshot = try await AutoFillStoreInspectorViewModel.buildSnapshot(
            store: fake, capabilities: await fake.capabilities()
        ) { _ in nil }
        XCTAssertEqual(snapshot.totalCount, 0)
    }

    func testRefreshExposesProviderStateWhileEnumerationIsPending() async {
        let fake = FakeCredentialIdentityStore()
        fake.isEnabledValue = false
        fake.supportsIncrementalUpdatesValue = false
        let enumerationStarted = expectation(description: "Enumeration started")
        let releaseEnumeration = DispatchSemaphore(value: 0)
        fake.onEnumerate = {
            enumerationStarted.fulfill()
            _ = releaseEnumeration.wait(timeout: .now() + 5)
        }
        let model = AutoFillStoreInspectorViewModel(store: fake)
        model.refresh()
        await fulfillment(of: [enumerationStarted], timeout: 2)

        XCTAssertEqual(model.capabilities?.isEnabled, false)
        XCTAssertEqual(model.capabilities?.supportsIncrementalUpdates, false)
        XCTAssertTrue(model.isRefreshing)
        XCTAssertNil(model.snapshot, "Pending enumeration must not report a zero count")
        XCTAssertNil(model.enumerationError)
        model.refresh()

        releaseEnumeration.signal()
        await waitForRefresh(model)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.snapshot?.totalCount, 0)
        XCTAssertEqual(model.snapshot?.isEnabled, false)
        XCTAssertTrue(fake.calls.isEmpty, "Inspector must never mutate the real store")
    }

    func testRefreshPreservesProviderStateOnReadErrorAndRecovers() async {
        let fake = FakeCredentialIdentityStore()
        fake.enumerationError = .nonConformingIdentities(count: 2)
        let model = AutoFillStoreInspectorViewModel(store: fake)
        model.refresh()
        await waitForRefresh(model)

        XCTAssertEqual(model.capabilities?.isEnabled, true)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.enumerationError?.contains("2 identities") == true)

        fake.enumerationError = nil
        fake.isEnabledValue = false
        model.refresh()
        XCTAssertNil(model.enumerationError)
        await waitForRefresh(model)
        XCTAssertNil(model.enumerationError)
        XCTAssertEqual(model.capabilities?.isEnabled, false)
        XCTAssertEqual(model.snapshot?.totalCount, 0)
        XCTAssertEqual(model.snapshot?.isEnabled, false)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    private func waitForRefresh(_ model: AutoFillStoreInspectorViewModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isRefreshing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isRefreshing, "Inspector refresh did not finish")
    }

    func testIdentityMetadataIncludesKindServiceLabelAndRecordIdentifier() {
        let record = current(UUID(), UUID())
        let row = AutoFillStoreInspectorGrouping.row(for: passwordIdentity(domain: "example.com", user: "user", recordIdentifier: record))
        XCTAssertEqual(row.metadata, "password|example.com|user|\(record)")
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
