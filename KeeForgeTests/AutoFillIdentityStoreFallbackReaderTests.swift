// Reconstruction is driven from real fixture SQLite files replicating the
// `credential_identities` schema. Gated to DEBUG simulator because the reader
// under test is; the unit suites always run on a simulator destination.
#if DEBUG && targetEnvironment(simulator)
@preconcurrency import AuthenticationServices
import Foundation
import SQLite3
import XCTest
@testable import KeeForge

final class AutoFillIdentityStoreFallbackReaderTests: XCTestCase {

    // MARK: - Fixtures

    private var scratchURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in scratchURLs {
            try? FileManager.default.removeItem(at: url)
        }
        scratchURLs.removeAll()
    }

    private func scratchDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeforge-fallback-\(UUID().uuidString).db")
        scratchURLs.append(url)
        return url
    }

    /// The exact production schema discovered on the harness simulator.
    private static let productionSchema = """
    CREATE TABLE credential_identities (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      identity_type INTEGER DEFAULT 0,
      service_id TEXT NOT NULL,
      service_id_type INTEGER NOT NULL DEFAULT 0,
      external_record_id TEXT DEFAULT NULL,
      user TEXT DEFAULT NULL,
      rank INTEGER NOT NULL DEFAULT 0,
      credential_id TEXT DEFAULT NULL,
      user_handle TEXT DEFAULT NULL,
      service_display_name TEXT DEFAULT NULL,
      UNIQUE(service_id, service_id_type, external_record_id, user, identity_type) ON CONFLICT REPLACE
    );
    """

    private func makeDatabase(at url: URL, sql: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw FixtureError.open
        }
        defer { sqlite3_close_v2(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw FixtureError.exec(message)
        }
    }

    private enum FixtureError: Error {
        case open
        case exec(String)
    }

    private func record(_ database: UUID, _ entry: UUID) -> String {
        CredentialRecordIdentifier(databaseID: database, entryID: entry).encoded
    }

    // MARK: - Reader reconstruction

    func testReconstructsPasswordOneTimeCodeAndPasskey() async throws {
        let url = scratchDatabaseURL()
        let dbA = UUID()
        let dbB = UUID()
        let recPassword = record(dbA, UUID())
        let recOTC = record(dbA, UUID())
        let recPasskey = record(dbB, UUID())
        let credentialID = Data([0x0A, 0x0B, 0x0C, 0x0D])
        let userHandle = Data([0x01, 0x02, 0x03, 0x04])

        let sql = Self.productionSchema + """
        INSERT INTO credential_identities (identity_type, service_id, service_id_type, external_record_id, user, credential_id, user_handle)
        VALUES
          (1, 'pw.example.com', 0, '\(recPassword)', 'pw-user', NULL, NULL),
          (4, 'otc.example.com', 0, '\(recOTC)', 'otc-label', NULL, NULL),
          (2, 'passkey.example.com', 0, '\(recPasskey)', 'pk-user', '\(credentialID.base64EncodedString())', '\(userHandle.base64EncodedString())');
        """
        try makeDatabase(at: url, sql: sql)

        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        XCTAssertEqual(identities.count, 3)

        let password = identities.compactMap { $0 as? ASPasswordCredentialIdentity }.first
        XCTAssertEqual(password?.serviceIdentifier.identifier, "pw.example.com")
        XCTAssertEqual(password?.user, "pw-user")
        XCTAssertEqual(password?.recordIdentifier, recPassword)

        if #available(iOS 18.0, macOS 15.0, *) {
            let otc = identities.compactMap { $0 as? ASOneTimeCodeCredentialIdentity }.first
            XCTAssertEqual(otc?.serviceIdentifier.identifier, "otc.example.com")
            XCTAssertEqual(otc?.label, "otc-label")
            XCTAssertEqual(otc?.recordIdentifier, recOTC)
        }

        let passkey = identities.compactMap { $0 as? ASPasskeyCredentialIdentity }.first
        XCTAssertEqual(passkey?.relyingPartyIdentifier, "passkey.example.com")
        XCTAssertEqual(passkey?.userName, "pk-user")
        XCTAssertEqual(passkey?.credentialID, credentialID)
        XCTAssertEqual(passkey?.userHandle, userHandle)
        XCTAssertEqual(passkey?.recordIdentifier, recPasskey)
    }

    func testSkipsUnknownIdentityTypeCode() async throws {
        let url = scratchDatabaseURL()
        let recPassword = record(UUID(), UUID())
        let sql = Self.productionSchema + """
        INSERT INTO credential_identities (identity_type, service_id, service_id_type, external_record_id, user)
        VALUES
          (1, 'ok.example.com', 0, '\(recPassword)', 'ok-user'),
          (99, 'unknown.example.com', 0, '\(record(UUID(), UUID()))', 'unknown-user');
        """
        try makeDatabase(at: url, sql: sql)

        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        // Only the password survives; the unknown type is skipped, not crashed.
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual((identities.first as? ASPasswordCredentialIdentity)?.recordIdentifier, recPassword)
    }

    func testSkipsPasskeyMissingPublicColumns() async throws {
        let url = scratchDatabaseURL()
        let sql = Self.productionSchema + """
        INSERT INTO credential_identities (identity_type, service_id, service_id_type, external_record_id, user, credential_id, user_handle)
        VALUES (2, 'passkey.example.com', 0, '\(record(UUID(), UUID()))', 'pk-user', NULL, NULL);
        """
        try makeDatabase(at: url, sql: sql)

        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        XCTAssertTrue(identities.isEmpty)
    }

    func testReconstructsURLServiceIdentifierType() async throws {
        let url = scratchDatabaseURL()
        let sql = Self.productionSchema + """
        INSERT INTO credential_identities (identity_type, service_id, service_id_type, external_record_id, user)
        VALUES (1, 'https://url.example.com/login', 1, '\(record(UUID(), UUID()))', 'url-user');
        """
        try makeDatabase(at: url, sql: sql)

        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        let password = identities.compactMap { $0 as? ASPasswordCredentialIdentity }.first
        XCTAssertEqual(password?.serviceIdentifier.type, .URL)
        XCTAssertEqual(password?.serviceIdentifier.identifier, "https://url.example.com/login")
    }

    func testReaderReturnsEmptyForAbsentFile() async {
        let url = scratchDatabaseURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        XCTAssertTrue(identities.isEmpty)
    }

    func testReaderReturnsEmptyForEmptyTable() async throws {
        let url = scratchDatabaseURL()
        try makeDatabase(at: url, sql: Self.productionSchema)
        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        XCTAssertTrue(identities.isEmpty)
    }

    func testReaderToleratesReorderedAndExtraColumns() async throws {
        let url = scratchDatabaseURL()
        let rec = record(UUID(), UUID())
        let sql = """
        CREATE TABLE credential_identities (
          extra_leading TEXT,
          user TEXT,
          service_id TEXT,
          extra_middle INTEGER,
          external_record_id TEXT,
          service_id_type INTEGER,
          identity_type INTEGER,
          credential_id TEXT,
          user_handle TEXT,
          extra_trailing TEXT
        );
        INSERT INTO credential_identities (extra_leading, user, service_id, extra_middle, external_record_id, service_id_type, identity_type, extra_trailing)
        VALUES ('x', 'reordered-user', 'reordered.example.com', 7, '\(rec)', 0, 1, 'y');
        """
        try makeDatabase(at: url, sql: sql)

        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        XCTAssertEqual(identities.count, 1)
        let password = identities.first as? ASPasswordCredentialIdentity
        XCTAssertEqual(password?.serviceIdentifier.identifier, "reordered.example.com")
        XCTAssertEqual(password?.user, "reordered-user")
        XCTAssertEqual(password?.recordIdentifier, rec)
    }

    func testReaderReturnsEmptyWhenExpectedColumnMissing() async throws {
        let url = scratchDatabaseURL()
        // No `user` column — the SELECT cannot prepare; the reader must not
        // crash, it returns empty.
        let sql = """
        CREATE TABLE credential_identities (
          identity_type INTEGER,
          service_id TEXT,
          external_record_id TEXT
        );
        INSERT INTO credential_identities (identity_type, service_id, external_record_id)
        VALUES (1, 'x.example.com', '\(record(UUID(), UUID()))');
        """
        try makeDatabase(at: url, sql: sql)
        let identities = await AutoFillIdentitiesDatabaseReader(databaseURL: url).reconstructedIdentities()
        XCTAssertTrue(identities.isEmpty)
    }

    // MARK: - Selection: CredentialIdentityFallback.resolve

    func testResolveApiWinsWhenNonEmpty() {
        let api = [passwordIdentity("api.example.com", record(UUID(), UUID()))]
        let result = CredentialIdentityFallback.resolve(apiIdentities: api) {
            [passwordIdentity("fallback.example.com", record(UUID(), UUID()))]
        }
        XCTAssertEqual(result.source, .api)
        XCTAssertEqual(result.identities?.count, 1)
        XCTAssertEqual(
            (result.identities?.first as? ASPasswordCredentialIdentity)?.serviceIdentifier.identifier,
            "api.example.com"
        )
    }

    func testResolvePassesThroughNilApi() {
        let result = CredentialIdentityFallback.resolve(apiIdentities: nil) {
            [passwordIdentity("fallback.example.com", record(UUID(), UUID()))]
        }
        XCTAssertEqual(result.source, .api)
        XCTAssertNil(result.identities)
    }

    func testResolveUsesFallbackWhenApiEmpty() {
        let fallback = [
            passwordIdentity("fb-a.example.com", record(UUID(), UUID())),
            passwordIdentity("fb-b.example.com", record(UUID(), UUID())),
        ]
        let result = CredentialIdentityFallback.resolve(apiIdentities: []) { fallback }
        XCTAssertEqual(result.source, .fallbackDB)
        XCTAssertEqual(result.identities?.count, 2)
    }

    func testResolveApiWhenBothEmpty() {
        let result = CredentialIdentityFallback.resolve(apiIdentities: []) { [] }
        XCTAssertEqual(result.source, .api)
        XCTAssertEqual(result.identities?.count, 0)
    }

    // MARK: - Inspector surfaces the seam's source signal

    func testInspectorSurfacesApiSource() async {
        let store = FakeCredentialIdentityStore()
        let dbA = UUID()
        store.stored = [passwordIdentity("api-only.example.com", record(dbA, UUID()))]
        store.reportedSource = .api

        let snapshot = await AutoFillStoreInspectorViewModel.buildSnapshot(store: store) { _ in nil }

        XCTAssertEqual(snapshot.source, .api)
        XCTAssertEqual(snapshot.totalCount, 1)
        XCTAssertTrue(snapshot.enumerationAvailable)
        XCTAssertEqual(snapshot.databaseBuckets.first?.rows.first?.serviceIdentifier, "api-only.example.com")
    }

    func testInspectorSurfacesFallbackSource() async {
        let store = FakeCredentialIdentityStore()
        let dbA = UUID()
        let dbB = UUID()
        store.stored = [
            passwordIdentity("fb-a.example.com", record(dbA, UUID())),
            passwordIdentity("fb-b.example.com", record(dbB, UUID())),
        ]
        store.reportedSource = .fallbackDB

        let snapshot = await AutoFillStoreInspectorViewModel.buildSnapshot(store: store) { _ in nil }

        XCTAssertEqual(snapshot.source, .fallbackDB)
        XCTAssertEqual(snapshot.totalCount, 2)
        // Enumeration-state stays API-truth (the fake returned a non-nil list).
        XCTAssertTrue(snapshot.enumerationAvailable)
        XCTAssertEqual(snapshot.databaseBuckets.count, 2)
    }

    func testInspectorEnumerationUnavailableStaysApiTruth() async {
        let store = FakeCredentialIdentityStore()
        store.enumerationUnavailable = true
        store.reportedSource = .api

        let snapshot = await AutoFillStoreInspectorViewModel.buildSnapshot(store: store) { _ in nil }

        XCTAssertEqual(snapshot.source, .api)
        XCTAssertFalse(snapshot.enumerationAvailable)
        XCTAssertEqual(snapshot.totalCount, 0)
    }

    // MARK: - Builders

    private func passwordIdentity(_ domain: String, _ recordIdentifier: String) -> ASPasswordCredentialIdentity {
        ASPasswordCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
            user: "user",
            recordIdentifier: recordIdentifier
        )
    }
}
#endif
