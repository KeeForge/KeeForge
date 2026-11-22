#if os(macOS)
import CryptoKit
import KDBXXML
import XCTest
@testable import KeeForge

/// The bridge's conformance fixtures (`TestFixtures/browser-bridge/`, format in
/// its README) through the real `matches` path: real sessions, eligibility,
/// ordering, the 50 cap and display-field cuts. The SiteMatching package runs
/// `site-matching.json` on its own; the extension runs `origins.json`.
@MainActor
final class BrowserBridgeFixtureTests: XCTestCase {
    private var slots: [Slot] = []
    private var activeCount = 0
    private let key = SymmetricKey(size: .bits256)

    override func tearDown() async throws {
        for slot in slots { slot.session.lockRequest(force: true) }
        slots = []
        try await super.tearDown()
    }

    func testOriginFixture() async throws {
        let fixture: OriginFixture = try Self.load("origins")
        XCTAssertEqual(fixture.version, 1, "Unrecognised fixture version")
        XCTAssertGreaterThan(fixture.cases.count, 50, "Fixture cases missing")
        let handler = makeHandler()
        for testCase in fixture.cases {
            let label = "\(testCase.origin.prefix(60).debugDescription) (\(testCase.note))"
            XCTAssertEqual(BrowserBridgeRequestHandler.validOrigin(testCase.origin), testCase.valid, label)
            let reply = await handler.response(to: .init(id: 1, operation: .matches(origin: testCase.origin))).result
            XCTAssertEqual(reply, testCase.valid ? .failure(.locked) : .failure(.badOrigin), label)
        }
    }

    func testSiteMatchingFixture() async throws {
        let fixture: SiteFixture = try Self.load("site-matching")
        XCTAssertEqual(fixture.version, 1, "Unrecognised fixture version")
        XCTAssertGreaterThan(fixture.cases.count, 30, "Fixture cases missing")
        for testCase in fixture.cases {
            let entries = testCase.entries.map { entry in
                let fields = Dictionary(uniqueKeysWithValues: entry.urls.dropFirst().enumerated().map { (String(format: "KP2A_URL_%03d", $0.offset + 1), $0.element) })
                return FixtureEntry(id: entry.id, url: entry.urls.first ?? "", fields: fields)
            }
            let database = FixtureDatabase(id: "site", entries: entries)
            let expected = testCase.expected.map { ExpectedRow(entry: $0.entry, db: "site", exact: $0.exact) }
            try await check(testCase.name, origin: testCase.origin, databases: [database], expected: .init(rows: expected, locked: 0))
        }
    }

    func testBridgeMatchesFixture() async throws {
        let fixture: BridgeFixture = try Self.load("bridge-matches")
        XCTAssertEqual(fixture.version, 1, "Unrecognised fixture version")
        XCTAssertGreaterThan(fixture.cases.count, 15, "Fixture cases missing")
        for testCase in fixture.cases {
            try await check(testCase.name, origin: testCase.origin, databases: testCase.databases, expected: testCase.expected)
        }
    }

    // MARK: - Running a case

    private func check(_ name: String, origin: String, databases: [FixtureDatabase], expected: ExpectedReply) async throws {
        XCTAssertEqual(Set(databases.map(\.id)).count, databases.count, "\(name): duplicate database ids")
        try await open(databases)
        let reply = await makeHandler().response(to: .init(id: 1, operation: .matches(origin: origin))).result
        if let error = expected.error {
            XCTAssertEqual(reply, .failure(try XCTUnwrap(BrowserBridgeRequestError(rawValue: error), name)), name)
            return
        }
        guard case .matches(let rows, let locked) = reply else { return XCTFail("\(name): expected matches, got \(reply)") }
        XCTAssertEqual(locked, expected.locked, "\(name): locked count")
        let labels = Dictionary(databases.flatMap(\.allEntries).map { (Self.uuid($0.id), $0.id) }, uniquingKeysWith: { first, _ in first })
        let dbLabels = Dictionary(uniqueKeysWithValues: zip(slots.prefix(databases.count).map(\.session.databaseReference.id), databases.map(\.id)))
        let actual = rows.map { "\(dbLabels[$0.db] ?? "?")/\(labels[$0.entry] ?? "?"):\($0.exact ? "exact" : "possible")" }
        let wanted = (expected.rows ?? []).map { "\($0.db)/\($0.entry):\($0.exact ? "exact" : "possible")" }
        XCTAssertEqual(actual, wanted, name)
        guard actual == wanted else { return }
        for (row, want) in zip(rows, expected.rows ?? []) {
            // Scalars, not String equality: Swift compares canonically equivalent strings as equal.
            if let title = want.title { XCTAssertEqual(Array(row.title.unicodeScalars), Array(title.unicodeScalars), "\(name): \(want.entry) title") }
            if let username = want.username { XCTAssertEqual(Array(row.username.unicodeScalars), Array(username.unicodeScalars), "\(name): \(want.entry) username") }
            if let hasTotp = want.hasTotp { XCTAssertEqual(row.hasTotp, hasTotp, "\(name): \(want.entry) hasTotp") }
        }
    }

    private func makeHandler() -> BrowserBridgeRequestHandler {
        var instant = ContinuousClock.now
        // A second apart, under the matches rate limit.
        return BrowserBridgeRequestHandler(sessionsProvider: { [weak self] in
            guard let self else { return [] }
            return slots.prefix(activeCount).map(\.session)
        }, appVersion: "test", authenticateDeviceOwner: { _, _ in false }, now: { instant += .seconds(1); return instant })
    }

    /// Sessions are reused across cases: each reload hands the session the case's tree.
    private func open(_ databases: [FixtureDatabase]) async throws {
        while slots.count < databases.count { slots.append(try await makeSlot()) }
        activeCount = databases.count
        for (slot, database) in zip(slots, databases) {
            slot.box.database = database
            if slot.session.state != .unlocked { await slot.session.unlock(password: "testpassword123") }
            try await slot.session.reloadDiscardingDraft()
            XCTAssertEqual(slot.session.state, .unlocked)
            XCTAssertEqual(slot.session.databaseReference.autoFillEnabled, database.autofill ?? true)
            if database.locked == true { slot.session.lockRequest(force: true) }
        }
    }

    private func makeSlot() async throws -> Slot {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let box = DatabaseBox()
        let key = key
        let session = DatabaseViewModel(
            databaseReference: try TestDatabaseSupport.makeReference(for: url),
            reloadOperation: { reference, _ in
                let database = box.database
                var reference = reference
                reference.autoFillEnabled = database.autofill ?? true
                let root = try Self.root(of: database, key: key)
                return .init(reference: reference, rootGroup: root, meta: KPMeta(recycleBin: root.recycleBinUUID.map { .group($0) }),
                             formatVersion: .kdbx4(minor: 1), sessionKey: key,
                             openTimeSHA512: Data("fixture".utf8), binaryPool: BinaryPool(rawFields: []))
            },
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            expressUnlockKeySaveOperation: { _, _ in },
            storedKeyPresenceCheck: { _ in false },
            storedKeyStoreOperation: { _, _ in },
            storedKeyDeleteOperation: { _ in },
            deviceOwnerAuthAvailabilityCheck: { false },
            quickUnlockAvailabilityCheck: { false },
            secretAccess: SecretAccessGate(isAuthenticationAvailable: { false })
        )
        return Slot(session: session, box: box)
    }

    // MARK: - Building the tree

    private nonisolated static func root(of database: FixtureDatabase, key: SymmetricKey) throws -> KPGroup {
        func entry(_ entry: FixtureEntry) throws -> KPEntry {
            var password = EncryptedValue.empty
            if entry.password ?? true { password = try .encrypt("password-\(entry.id)", using: key) }
            var totp: TOTPConfig?
            if entry.totp == true { totp = TOTPConfig(secret: try .encrypt("JBSWY3DPEHPK3PXP", using: key)) }
            var expiryTime: Date?
            switch entry.expiry {
            case nil: break
            case "past": expiryTime = .distantPast
            case "future": expiryTime = .distantFuture
            case let value?: throw FixtureError.unknown("expiry", value)
            }
            return KPEntry(
                id: uuid(entry.id), title: entry.title ?? "", username: entry.username ?? "", password: password,
                url: entry.url ?? "", notes: entry.notes ?? "",
                customFields: entry.fields ?? [:], customFieldOrder: (entry.fields ?? [:]).keys.sorted(),
                totpConfig: totp, expires: expiryTime != nil, expiryTime: expiryTime,
                protectedStringKeys: Set(entry.protected ?? [])
            )
        }
        var recycleBin: UUID?
        func groups(_ fixtures: [FixtureGroup]) throws -> [KPGroup] {
            try fixtures.map { child in
                let built = KPGroup(name: "Group", entries: try (child.entries ?? []).map(entry), groups: try groups(child.groups ?? []),
                                    searchingEnabled: try searchingEnabled(child.searching))
                if child.recycleBin == true { recycleBin = built.id }
                return built
            }
        }
        return KPGroup(name: "Root", entries: try database.entries.map(entry), groups: try groups(database.groups ?? []),
                       searchingEnabled: try searchingEnabled(database.searching), recycleBinUUID: recycleBin)
    }

    private nonisolated static func searchingEnabled(_ value: String?) throws -> KDBXDocument.InheritableBool? {
        switch value {
        case nil: nil
        case "enabled": .enabled
        case "disabled": .disabled
        case let value?: throw FixtureError.unknown("searching", value)
        }
    }

    /// The same label gives the same entry id, in any database of a case.
    private nonisolated static func uuid(_ label: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(label.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func load<Fixture: Decodable>(_ name: String) throws -> Fixture {
        let data = try TestDatabaseSupport.fixtureData(named: name, extension: "json", subdirectory: "browser-bridge", bundle: Bundle(for: Self.self))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    // MARK: - Fixture format

    private struct Slot {
        let session: DatabaseViewModel
        let box: DatabaseBox
    }

    private final class DatabaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = FixtureDatabase(id: "", entries: [])
        var database: FixtureDatabase {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private enum FixtureError: Error {
        case unknown(String, String)
    }

    private struct OriginFixture: Decodable {
        struct Case: Decodable {
            let origin: String
            let valid: Bool
            let note: String
        }
        let version: Int
        let cases: [Case]
    }

    private struct SiteFixture: Decodable {
        struct Entry: Decodable {
            let id: String
            let urls: [String]
        }
        struct Row: Decodable {
            let entry: String
            let exact: Bool
        }
        struct Case: Decodable {
            let name: String
            let origin: String
            let entries: [Entry]
            let expected: [Row]
        }
        let version: Int
        let cases: [Case]
    }

    private struct BridgeFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let origin: String
            let databases: [FixtureDatabase]
            let expected: ExpectedReply
        }
        let version: Int
        let cases: [Case]
    }

    private struct FixtureEntry: Decodable, Sendable {
        var id: String
        var title: String?
        var username: String?
        var url: String?
        var notes: String?
        var fields: [String: String]?
        var protected: [String]?
        var password: Bool?
        var totp: Bool?
        var expiry: String?

        init(id: String, url: String, fields: [String: String]) {
            self.id = id
            self.url = url
            self.fields = fields
        }
    }

    private struct FixtureGroup: Decodable, Sendable {
        let searching: String?
        let recycleBin: Bool?
        let entries: [FixtureEntry]?
        let groups: [FixtureGroup]?

        var allEntries: [FixtureEntry] { (entries ?? []) + (groups ?? []).flatMap(\.allEntries) }
    }

    private struct FixtureDatabase: Decodable, Sendable {
        var id: String
        var autofill: Bool?
        var locked: Bool?
        var searching: String?
        var entries: [FixtureEntry]
        var groups: [FixtureGroup]?

        init(id: String, entries: [FixtureEntry]) {
            self.id = id
            self.entries = entries
        }

        var allEntries: [FixtureEntry] { entries + (groups ?? []).flatMap(\.allEntries) }
    }

    private struct ExpectedRow: Decodable {
        let entry: String
        let db: String
        let exact: Bool
        var title: String?
        var username: String?
        var hasTotp: Bool?

        init(entry: String, db: String, exact: Bool) {
            self.entry = entry
            self.db = db
            self.exact = exact
        }
    }

    private struct ExpectedReply: Decodable {
        var error: String?
        var rows: [ExpectedRow]?
        var locked: Int?

        init(rows: [ExpectedRow], locked: Int) {
            self.rows = rows
            self.locked = locked
        }
    }
}
#endif
