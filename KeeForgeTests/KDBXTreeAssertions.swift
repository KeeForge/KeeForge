import CryptoKit
import Foundation
import XCTest
@testable import KeeForge

/// Bundled fixture descriptor shared by the XML round-trip and container-writer
/// suites. Both suites open the same databases; only the parse entry point
/// differs (`KDBXParser.parseWithMeta` vs `parseWithMetaAndHeader`).
struct KDBXTestFixture {
    let name: String
    let subdirectory: String?
    let password: String?
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
    /// KDBX4 fixture whose inner header carries three items with type IDs the
    /// format does not define; see
    /// `TestFixtures/generators/unknown_inner_header.py`.
    static let unknownInnerHeader = KDBXTestFixture(
        name: "unknown-inner-header",
        subdirectory: "compatibility",
        password: "unknown-inner-header",
        keyFileName: nil,
        keyFileExtension: nil
    )
    static let unknownElements = KDBXTestFixture(
        name: "unknown-elements",
        subdirectory: "round-trip",
        password: "test-round-trip",
        keyFileName: nil,
        keyFileExtension: nil
    )
    static let kdbx41PublicCustomData = KDBXTestFixture(
        name: "kdbx41-public-custom-data",
        subdirectory: "compatibility",
        password: "testpassword123",
        keyFileName: nil,
        keyFileExtension: nil
    )
    /// The rich union fixture: group `<Tags>` in all three states, a binary
    /// pool with a dedup pair, entry tags, a custom icon, a protected custom
    /// field with history, a TOTP entry, and a populated recycle bin. See
    /// `TestFixtures/generators/kitchen_sink.py`.
    static let kitchenSink = KDBXTestFixture(
        name: "kitchen-sink",
        subdirectory: nil,
        password: "testpassword123",
        keyFileName: nil,
        keyFileExtension: nil
    )
    static let foreignChaCha20 = KDBXTestFixture(
        name: "foreign-chacha20",
        subdirectory: "compatibility",
        password: "foreign-chacha20",
        keyFileName: nil,
        keyFileExtension: nil
    )
    static let foreignTwofish = KDBXTestFixture(
        name: "foreign-twofish",
        subdirectory: "compatibility",
        password: "foreign-twofish",
        keyFileName: nil,
        keyFileExtension: nil
    )
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
