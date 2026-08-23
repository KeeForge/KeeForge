import CryptoKit
import Foundation
import XCTest
@testable import KeeForge

/// The catalog of bundled KDBX fixtures: every database any unit-test suite
/// opens is described exactly once here, together with the single way to open
/// one (see the loading extension below). Add a descriptor rather than an
/// inline literal or a per-suite loader.
struct KDBXTestFixture {
    let name: String
    let subdirectory: String?
    let password: String
    let keyFileName: String?
    let keyFileExtension: String?

    static let test = KDBXTestFixture(
        name: "test",
        subdirectory: nil,
        password: "testpassword123",
        keyFileName: nil,
        keyFileExtension: nil
    )
    static let demo = KDBXTestFixture(
        name: "demo",
        subdirectory: nil,
        password: "demo",
        keyFileName: nil,
        keyFileExtension: nil
    )
    static let demoKeyfile = KDBXTestFixture(
        name: "demo-keyfile",
        subdirectory: nil,
        password: "demo",
        keyFileName: "demo-keyfile",
        keyFileExtension: "key"
    )
    /// The only KDBX 3.1 fixture; KeeForge reads that format but never writes
    /// it, so it never reaches the writer.
    static let legacyKDBX31 = KDBXTestFixture(
        name: "legacy-kdbx31",
        subdirectory: "compatibility",
        password: "testpassword123",
        keyFileName: nil,
        keyFileExtension: nil
    )
    /// KDBX4 fixture carrying three inner-header fields KeeForge does not
    /// recognize (0x7F with an ASCII marker, a zero-length 0x10, and a 0x21
    /// spliced between the two binary-pool entries), authored by a standalone
    /// decrypt/re-encrypt script because no library round-trips unknown
    /// inner-header items. See
    /// `TestFixtures/generators/unknown_inner_header.py`.
    static let unknownInnerHeader = KDBXTestFixture(
        name: "unknown-inner-header",
        subdirectory: "compatibility",
        password: "unknown-inner-header",
        keyFileName: nil,
        keyFileExtension: nil
    )
    /// Foreign-authored (pykeepass) KDBX 4.1 fixture that carries, in one file,
    /// everything the narrow per-feature fixtures used to own: a three-item
    /// binary pool (including a dedup pair two entries share and a non-ASCII
    /// filename), group `<Tags>` in all three states — content (`Projects`,
    /// nested `Client Work`), an empty element (`Empty Tags Group`), no element
    /// at all (`Plain Group`) — a group `<Notes>` sitting next to one of them,
    /// entry tags, a `Meta/CustomIcons` image, a protected custom field that
    /// also lives in history, a TOTP entry, and a populated `Recycle Bin` with
    /// `Meta/RecycleBinUUID` set. It also carries the whole opaque-XML corpus:
    /// a `PublicCustomData` (id 0x0C) outer-header field KeeForge does not
    /// model, a `Round Trip` entry whose `<AutoType>` and `<CustomData>` sit in
    /// deliberately awkward positions and whose attachment is referenced from
    /// its history version too, and a schema-invalid second `Meta/CustomData`
    /// sibling. See `TestFixtures/generators/kitchen_sink.py` and
    /// `TestFixtures/README.md`.
    ///
    /// It lives at the `TestFixtures/` root rather than in `compatibility/`,
    /// because the UI suites bundle it too.
    static let kitchenSink = KDBXTestFixture(
        name: "kitchen-sink",
        subdirectory: nil,
        password: "testpassword123",
        keyFileName: nil,
        keyFileExtension: nil
    )
    /// Foreign-authored (pykeepass) KDBX4 fixture with the ChaCha20 outer
    /// cipher. Every other bundled fixture is AES-256-CBC authored by pykeepass
    /// or KeeForge itself, so this and `foreignTwofish` are the only fixtures
    /// that prove KeeForge's ChaCha20/Twofish outer-cipher READ paths against a
    /// database KeeForge did not write. See
    /// `TestFixtures/generators/foreign_ciphers.py`.
    static let foreignChaCha20 = KDBXTestFixture(
        name: "foreign-chacha20",
        subdirectory: "compatibility",
        password: "foreign-chacha20",
        keyFileName: nil,
        keyFileExtension: nil
    )
    /// Foreign-authored (pykeepass) KDBX4 fixture with the Twofish outer
    /// cipher. See `foreignChaCha20`.
    static let foreignTwofish = KDBXTestFixture(
        name: "foreign-twofish",
        subdirectory: "compatibility",
        password: "foreign-twofish",
        keyFileName: nil,
        keyFileExtension: nil
    )
    /// Foreign-authored (pykeepass) KDBX4 fixture whose Argon2 KDF uses a high
    /// iteration count with low memory (1500 x 1 MiB, above the retired fixed
    /// 1000-iteration cap), the acceptance case for the `KDFExecutionPolicy`
    /// work-budget model (issue #74). Deliberately expensive to open. See
    /// `TestFixtures/generators/argon2_high_iterations.py`.
    static let argon2HighIterations = KDBXTestFixture(
        name: "argon2-high-iterations",
        subdirectory: "compatibility",
        password: "argon2-high-iterations",
        keyFileName: nil,
        keyFileExtension: nil
    )
}

/// The single loading path for bundled fixtures: resolve, read, derive the
/// composite key, parse. Suites must not keep private copies of these steps.
extension KDBXTestFixture {
    /// On-disk name of the key file, e.g. `demo-keyfile.key`.
    var keyFileFileName: String? {
        guard let keyFileName, let keyFileExtension else { return nil }
        return "\(keyFileName).\(keyFileExtension)"
    }

    func url(in bundle: Bundle) throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: name, subdirectory: subdirectory, bundle: bundle)
    }

    func keyFileURL(in bundle: Bundle) throws -> URL? {
        guard let keyFileName, let keyFileExtension else { return nil }
        return try TestDatabaseSupport.fixtureURL(named: keyFileName, extension: keyFileExtension, bundle: bundle)
    }

    func data(in bundle: Bundle) throws -> Data {
        try Data(contentsOf: url(in: bundle))
    }

    func keyFileData(in bundle: Bundle) throws -> Data? {
        guard let keyFileURL = try keyFileURL(in: bundle) else { return nil }
        return try Data(contentsOf: keyFileURL)
    }

    func compositeKey(in bundle: Bundle) throws -> SymmetricKey {
        try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData(in: bundle))
    }

    func parse(
        in bundle: Bundle,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: KDBXParser.Header, compositeKey: SymmetricKey) {
        let key = try compositeKey(in: bundle)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: try data(in: bundle),
            compositeKey: key,
            sessionKey: sessionKey
        )
        return (parsed.rootGroup, parsed.meta, parsed.header, key)
    }
}

/// Canonical "did the tree survive a save/reload" comparators.
///
/// `KDBXRoundTripTests` (parse → `KDBXXMLSerializer` → parse) and
/// `KDBXWriterTests` (parse file → `KDBXWriter.write` → parse file) used to keep
/// private copies of these, which drifted: the writer copy silently stopped
/// checking `searchingEnabled`, `expires`, and `expiryTime`. Both layers must
/// preserve the same fields, so there is exactly one set of comparators here —
/// add new field checks in this file so every round-trip layer gains them at
/// once.
///
/// `sessionKey` is the key the tree under test was parsed with; both sides of a
/// comparison must share it, since protected values are re-encrypted per
/// session.
enum KDBXTreeAssertions {
    /// Protected `<Value>` payloads are re-encrypted with a fresh inner stream
    /// key on every write, so opaque XML that contains them can only be
    /// compared with the ciphertext stripped out.
    private static let protectedValueRegex = try? NSRegularExpression(
        pattern: #"<Value(?=[^>]*Protected="True")([^>]*)>.*?</Value>"#,
        options: [.dotMatchesLineSeparators]
    )

    static func assertTreesEqual(
        _ lhs: (rootGroup: KPGroup, meta: KPMeta),
        _ rhs: (rootGroup: KPGroup, meta: KPMeta),
        sessionKey: SymmetricKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(lhs.meta.recycleBinUUID, rhs.meta.recycleBinUUID, file: file, line: line)
        XCTAssertEqual(lhs.meta.maintenanceHistoryDays, rhs.meta.maintenanceHistoryDays, file: file, line: line)
        XCTAssertEqual(lhs.meta.historyMaxItems, rhs.meta.historyMaxItems, file: file, line: line)
        XCTAssertEqual(lhs.meta.historyMaxSize, rhs.meta.historyMaxSize, file: file, line: line)
        XCTAssertEqual(
            normalizedOpaqueXML(lhs.meta.unknownXML),
            normalizedOpaqueXML(rhs.meta.unknownXML),
            file: file,
            line: line
        )
        try assertGroupsEqual(lhs.rootGroup, rhs.rootGroup, sessionKey: sessionKey, file: file, line: line)
    }

    static func assertGroupsEqual(
        _ lhs: KPGroup,
        _ rhs: KPGroup,
        sessionKey: SymmetricKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(lhs.id, rhs.id, file: file, line: line)
        XCTAssertEqual(lhs.name, rhs.name, file: file, line: line)
        XCTAssertEqual(lhs.iconID, rhs.iconID, file: file, line: line)
        XCTAssertEqual(lhs.tags, rhs.tags, file: file, line: line)
        XCTAssertEqual(lhs.hasTagsElement, rhs.hasTagsElement, file: file, line: line)
        XCTAssertEqual(lhs.notes, rhs.notes, file: file, line: line)
        XCTAssertEqual(lhs.hasNotesElement, rhs.hasNotesElement, file: file, line: line)
        XCTAssertEqual(lhs.isExpanded, rhs.isExpanded, file: file, line: line)
        XCTAssertEqual(lhs.searchingEnabled, rhs.searchingEnabled, file: file, line: line)
        XCTAssertEqual(lhs.creationTime, rhs.creationTime, file: file, line: line)
        XCTAssertEqual(lhs.lastModificationTime, rhs.lastModificationTime, file: file, line: line)
        XCTAssertEqual(lhs.locationChanged, rhs.locationChanged, file: file, line: line)
        XCTAssertEqual(lhs.recycleBinUUID, rhs.recycleBinUUID, file: file, line: line)
        XCTAssertEqual(normalizedOpaqueXML(lhs.unknownXML), normalizedOpaqueXML(rhs.unknownXML), file: file, line: line)
        XCTAssertEqual(lhs.entries.count, rhs.entries.count, file: file, line: line)
        XCTAssertEqual(lhs.groups.count, rhs.groups.count, file: file, line: line)

        for (lhsEntry, rhsEntry) in zip(lhs.entries, rhs.entries) {
            try assertEntriesEqual(lhsEntry, rhsEntry, sessionKey: sessionKey, file: file, line: line)
        }

        for (lhsGroup, rhsGroup) in zip(lhs.groups, rhs.groups) {
            try assertGroupsEqual(lhsGroup, rhsGroup, sessionKey: sessionKey, file: file, line: line)
        }
    }

    static func assertEntriesEqual(
        _ lhs: KPEntry,
        _ rhs: KPEntry,
        sessionKey: SymmetricKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(lhs.id, rhs.id, file: file, line: line)
        XCTAssertEqual(lhs.title, rhs.title, file: file, line: line)
        XCTAssertEqual(lhs.username, rhs.username, file: file, line: line)
        XCTAssertEqual(
            try lhs.password.decrypt(using: sessionKey),
            try rhs.password.decrypt(using: sessionKey),
            file: file,
            line: line
        )
        XCTAssertEqual(lhs.url, rhs.url, file: file, line: line)
        XCTAssertEqual(lhs.notes, rhs.notes, file: file, line: line)
        XCTAssertEqual(lhs.iconID, rhs.iconID, file: file, line: line)
        XCTAssertEqual(lhs.tags, rhs.tags, file: file, line: line)
        XCTAssertEqual(lhs.hasTagsElement, rhs.hasTagsElement, file: file, line: line)
        XCTAssertEqual(lhs.customFields, rhs.customFields, file: file, line: line)
        XCTAssertEqual(lhs.creationTime, rhs.creationTime, file: file, line: line)
        XCTAssertEqual(lhs.lastModificationTime, rhs.lastModificationTime, file: file, line: line)
        XCTAssertEqual(lhs.expires, rhs.expires, file: file, line: line)
        XCTAssertEqual(lhs.expiryTime, rhs.expiryTime, file: file, line: line)
        XCTAssertEqual(lhs.locationChanged, rhs.locationChanged, file: file, line: line)
        XCTAssertEqual(normalizedOpaqueXML(lhs.unknownXML), normalizedOpaqueXML(rhs.unknownXML), file: file, line: line)
        XCTAssertEqual(lhs.attachments, rhs.attachments, file: file, line: line)
        XCTAssertEqual(lhs.history.count, rhs.history.count, file: file, line: line)
        for (lhsHistoryEntry, rhsHistoryEntry) in zip(lhs.history, rhs.history) {
            try assertEntriesEqual(lhsHistoryEntry, rhsHistoryEntry, sessionKey: sessionKey, file: file, line: line)
        }
        try assertTOTPConfigsEqual(lhs.totpConfig, rhs.totpConfig, sessionKey: sessionKey, file: file, line: line)
    }

    static func assertTOTPConfigsEqual(
        _ lhs: TOTPConfig?,
        _ rhs: TOTPConfig?,
        sessionKey: SymmetricKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        switch (lhs, rhs) {
        case (nil, nil):
            return
        case let (lhs?, rhs?):
            XCTAssertEqual(lhs.period, rhs.period, file: file, line: line)
            XCTAssertEqual(lhs.digits, rhs.digits, file: file, line: line)
            XCTAssertEqual(lhs.algorithm.rawValue, rhs.algorithm.rawValue, file: file, line: line)
            XCTAssertEqual(
                try lhs.secret.decrypt(using: sessionKey),
                try rhs.secret.decrypt(using: sessionKey),
                file: file,
                line: line
            )
        default:
            XCTFail("TOTP config mismatch", file: file, line: line)
        }
    }

    /// Strips the ciphertext out of protected `<Value>` elements so opaque XML
    /// captured before and after a save can be compared structurally.
    static func normalizedOpaqueXML(_ unknownXML: OpaqueXMLNodes) -> OpaqueXMLNodes {
        OpaqueXMLNodes(nodes: unknownXML.nodes.map { node in
            OpaqueXMLNodes.Node(
                path: node.path,
                insertionIndex: node.insertionIndex,
                xml: normalizedProtectedValues(in: node.xml)
            )
        })
    }

    private static func normalizedProtectedValues(in xml: String) -> String {
        guard let protectedValueRegex else { return xml }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return protectedValueRegex.stringByReplacingMatches(
            in: xml,
            options: [],
            range: nsRange,
            withTemplate: "<Value$1></Value>"
        )
    }
}
