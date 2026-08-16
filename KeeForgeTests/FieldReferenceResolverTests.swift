import CryptoKit
import XCTest
@testable import KeeForge

final class FieldReferenceResolverTests: XCTestCase {
    private let sessionKey = SymmetricKey(size: .bits256)
    private let targetID = UUID(uuidString: "46C9B1FF-BD4A-BC4B-BB26-0BA1AB0A2E9F")!

    private func makeTarget() throws -> KPEntry {
        KPEntry(
            id: targetID,
            title: "Mail Server",
            username: "mailbox@example.com",
            password: try EncryptedValue.encrypt("s3cret!", using: sessionKey),
            url: "https://mail.example.com",
            notes: "IMAP on 993",
            customFields: ["Server": "imap.example.com", "Port": "993"]
        )
    }

    private func makeResolver(_ extra: [KPEntry] = []) throws -> FieldReferenceResolver {
        let decoy = KPEntry(title: "Decoy", username: "someone-else", url: "https://decoy.example.com")
        let target = try makeTarget()
        return FieldReferenceResolver(entries: [decoy, target] + extra, sessionKey: sessionKey)
    }

    func testEveryWantedCodeResolvesAgainstUUIDLookup() throws {
        let resolver = try makeResolver()
        let ref = "@I:46C9B1FFBD4ABC4BBB260BA1AB0A2E9F}"
        XCTAssertEqual(resolver.resolve("{REF:T" + ref), "Mail Server")
        XCTAssertEqual(resolver.resolve("{REF:U" + ref), "mailbox@example.com")
        XCTAssertEqual(resolver.resolve("{REF:P" + ref), "s3cret!")
        XCTAssertEqual(resolver.resolve("{REF:A" + ref), "https://mail.example.com")
        XCTAssertEqual(resolver.resolve("{REF:N" + ref), "IMAP on 993")
        XCTAssertEqual(resolver.resolve("{REF:I" + ref), "46C9B1FFBD4ABC4BBB260BA1AB0A2E9F")
    }

    func testCodesAndUUIDAreCaseInsensitive() throws {
        let resolver = try makeResolver()
        XCTAssertEqual(resolver.resolve("{ref:u@i:46c9b1ffbd4abc4bbb260ba1ab0a2e9f}"), "mailbox@example.com")
    }

    func testSubstringSearchesAreCaseInsensitiveAndTakeFirstHitInOrder() throws {
        let resolver = try makeResolver()
        XCTAssertEqual(resolver.resolve("{REF:U@T:mail server}"), "mailbox@example.com")
        XCTAssertEqual(resolver.resolve("{REF:T@U:MAILBOX}"), "Mail Server")
        XCTAssertEqual(resolver.resolve("{REF:U@A:mail.example}"), "mailbox@example.com")
        XCTAssertEqual(resolver.resolve("{REF:U@N:imap}"), "mailbox@example.com")
        XCTAssertEqual(resolver.resolve("{REF:U@O:IMAP.EXAMPLE}"), "mailbox@example.com")
        XCTAssertEqual(resolver.resolve("{REF:T@P:s3cret}"), "Mail Server")
        XCTAssertEqual(resolver.resolve("{REF:T@A:example.com}"), "Decoy", "First match in tree order wins")
    }

    func testMultipleReferencesAndSurroundingTextSurvive() throws {
        let resolver = try makeResolver()
        XCTAssertEqual(
            resolver.resolve("user={REF:U@T:Mail Server} host={REF:A@T:Mail Server}!"),
            "user=mailbox@example.com host=https://mail.example.com!"
        )
    }

    func testValuesWithoutReferencesAreReturnedUnchanged() throws {
        let resolver = try makeResolver()
        XCTAssertEqual(resolver.resolve("plain {not a ref} text"), "plain {not a ref} text")
        XCTAssertEqual(resolver.resolve(""), "")
    }

    func testUnresolvableAndMalformedReferencesStayLiteral() throws {
        let resolver = try makeResolver()
        for literal in [
            "{REF:U@T:No Such Entry}",
            "{REF:U@I:not-a-uuid}",
            "{REF:X@T:Mail Server}",
            "{REF:U@Z:Mail Server}",
            "{REF:O@T:Mail Server}",
            "{REF:U@T:}",
            "{REF:UT:Mail Server}",
            "{REF:U@T Mail Server}",
            "{REF:U@T:Mail Server",
            "{REF:}",
        ] {
            XCTAssertEqual(resolver.resolve(literal), literal, literal)
        }
        XCTAssertEqual(
            resolver.resolve("{REF:U@T:Nope} and {REF:U@T:Mail Server}"),
            "{REF:U@T:Nope} and mailbox@example.com"
        )
    }

    func testPasswordReferenceStaysLiteralWithoutSessionKey() throws {
        let resolver = FieldReferenceResolver(entries: [try makeTarget()], sessionKey: nil)
        XCTAssertEqual(resolver.resolve("{REF:P@T:Mail Server}"), "{REF:P@T:Mail Server}")
        XCTAssertEqual(resolver.resolve("{REF:U@T:Mail Server}"), "mailbox@example.com")
    }

    func testPasswordReferenceStaysLiteralWhenDecryptionFails() throws {
        let resolver = FieldReferenceResolver(entries: [try makeTarget()], sessionKey: SymmetricKey(size: .bits256))
        XCTAssertEqual(resolver.resolve("{REF:P@T:Mail Server}"), "{REF:P@T:Mail Server}")
    }

    func testChainedReferencesResolveRecursively() throws {
        let hop = KPEntry(title: "Hop", username: "{REF:U@T:Mail Server}")
        let resolver = try makeResolver([hop])
        XCTAssertEqual(resolver.resolve("{REF:U@T:Hop}"), "mailbox@example.com")
    }

    func testCycleTerminates() {
        let a = KPEntry(title: "A", username: "{REF:U@T:B}")
        let b = KPEntry(title: "B", username: "{REF:U@T:A}")
        let resolver = FieldReferenceResolver(entries: [a, b], sessionKey: nil)
        let resolved = resolver.resolve("{REF:U@T:A}")
        XCTAssertTrue(resolved.hasPrefix("{REF:U@T:"), "A cycle must end in a literal reference, got \(resolved)")
    }

    func testStaticConvenienceWalksTheWholeTree() throws {
        let child = KPGroup(name: "Child", entries: [try makeTarget()])
        let root = KPGroup(name: "Root", groups: [child])
        XCTAssertEqual(
            FieldReferenceResolver.resolve("{REF:P@T:Mail Server}", in: root, sessionKey: sessionKey),
            "s3cret!"
        )
        XCTAssertEqual(FieldReferenceResolver.resolve("plain", in: nil, sessionKey: nil), "plain")
    }

    func testUUIDHexRoundTrip() {
        XCTAssertEqual(targetID.kdbxHexString, "46C9B1FFBD4ABC4BBB260BA1AB0A2E9F")
        XCTAssertEqual(UUID(kdbxHexString: "46C9B1FFBD4ABC4BBB260BA1AB0A2E9F"), targetID)
        XCTAssertEqual(UUID(kdbxHexString: "46c9b1ffbd4abc4bbb260ba1ab0a2e9f"), targetID)
        XCTAssertNil(UUID(kdbxHexString: "46C9B1FFBD4ABC4BBB260BA1AB0A2E"))
        XCTAssertNil(UUID(kdbxHexString: "ZZC9B1FFBD4ABC4BBB260BA1AB0A2E9F"))
        let random = UUID()
        XCTAssertEqual(UUID(kdbxHexString: random.kdbxHexString), random)
    }
}
