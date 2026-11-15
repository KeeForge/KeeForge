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

    /// Full clearance, as a caller past the device-owner gate resolves.
    private struct Cleared {
        let resolver: FieldReferenceResolver
        func resolve(_ value: String) -> String? { resolver.resolve(value, clearance: .protectedValues).value }
    }

    private func makeResolver(_ extra: [KPEntry] = []) throws -> Cleared {
        let decoy = KPEntry(title: "Decoy", username: "someone-else", url: "https://decoy.example.com")
        let target = try makeTarget()
        return Cleared(resolver: FieldReferenceResolver(entries: [decoy, target] + extra, sessionKey: sessionKey))
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
        let resolver = Cleared(resolver: FieldReferenceResolver(entries: [try makeTarget()], sessionKey: nil))
        XCTAssertEqual(resolver.resolve("{REF:P@T:Mail Server}"), "{REF:P@T:Mail Server}")
        XCTAssertEqual(resolver.resolve("{REF:U@T:Mail Server}"), "mailbox@example.com")
    }

    func testPasswordReferenceStaysLiteralWhenDecryptionFails() throws {
        let resolver = Cleared(resolver: FieldReferenceResolver(entries: [try makeTarget()],
                                                                sessionKey: SymmetricKey(size: .bits256)))
        XCTAssertEqual(resolver.resolve("{REF:P@T:Mail Server}"), "{REF:P@T:Mail Server}")
    }

    func testChainedReferencesResolveRecursively() throws {
        let hop = KPEntry(title: "Hop", username: "{REF:U@T:Mail Server}")
        let resolver = try makeResolver([hop])
        XCTAssertEqual(resolver.resolve("{REF:U@T:Hop}"), "mailbox@example.com")
    }

    func testCycleTerminates() throws {
        let a = KPEntry(title: "A", username: "{REF:U@T:B}")
        let b = KPEntry(title: "B", username: "{REF:U@T:A}")
        let resolver = FieldReferenceResolver(entries: [a, b], sessionKey: nil)
        let resolved = try XCTUnwrap(resolver.resolve("{REF:U@T:A}").value)
        XCTAssertTrue(resolved.hasPrefix("{REF:U@T:"), "A cycle must end in a literal reference, got \(resolved)")
    }

    func testStaticConvenienceWalksTheWholeTree() throws {
        let child = KPGroup(name: "Child", entries: [try makeTarget()])
        let root = KPGroup(name: "Root", groups: [child])
        XCTAssertEqual(
            FieldReferenceResolver.resolve("{REF:P@T:Mail Server}", in: root, sessionKey: sessionKey,
                                           clearance: .protectedValues),
            .resolved("s3cret!")
        )
        XCTAssertEqual(FieldReferenceResolver.resolve("{REF:P@T:Mail Server}", in: root, sessionKey: sessionKey),
                       .needsProtectedValue, "The default clearance is the safe one")
        XCTAssertEqual(FieldReferenceResolver.resolve("plain", in: nil, sessionKey: nil), .resolved("plain"))
    }

    // MARK: - Clearance

    func testWithoutClearanceProtectedTargetsAreFlaggedAndNothingProtectedIsRead() throws {
        var target = try makeTarget()
        target.customFields["PIN"] = "4321"
        target.protectedStringKeys = ["PIN"]
        let ref = "@I:46C9B1FFBD4ABC4BBB260BA1AB0A2E9F}"
        let undecryptable = KPEntry(title: "Sealed", password: EncryptedValue(sealedData: Data([0]), hasValue: true))
        let resolver = FieldReferenceResolver(entries: [undecryptable, target], sessionKey: sessionKey)

        for flagged in [
            "{REF:P" + ref,
            "prefix {REF:U" + ref + " {REF:P" + ref,
            "{REF:T@P:s3cret}",
            "{REF:T@P:Sealed}",
            "{REF:T@O:4321}",
        ] {
            XCTAssertEqual(resolver.resolve(flagged), .needsProtectedValue, flagged)
        }
        XCTAssertEqual(resolver.resolve("{REF:U" + ref), .resolved("mailbox@example.com"))
        XCTAssertEqual(resolver.resolve("{REF:N" + ref), .resolved("IMAP on 993"))
        XCTAssertEqual(resolver.resolve("{REF:T@O:imap.example}"), .resolved("Mail Server"),
                       "An unprotected custom field still matches")
        XCTAssertEqual(resolver.resolve("{REF:T@O:4321}", clearance: .protectedValues), .resolved("Mail Server"))
        XCTAssertEqual(resolver.resolve("{REF:P" + ref, clearance: .protectedValues), .resolved("s3cret!"))
    }

    func testNestedReferencesThroughAProtectedValueAreFlagged() throws {
        let target = try makeTarget()
        let hop = KPEntry(title: "Hop", username: "{REF:P@T:Mail Server}")
        let second = KPEntry(title: "Second", notes: "{REF:U@T:Hop}")
        let resolver = FieldReferenceResolver(entries: [target, hop, second], sessionKey: sessionKey)
        XCTAssertEqual(resolver.resolve("{REF:U@T:Hop}"), .needsProtectedValue)
        XCTAssertEqual(resolver.resolve("{REF:N@T:Second}"), .needsProtectedValue)
        XCTAssertEqual(resolver.resolve("{REF:N@T:Second}", clearance: .protectedValues), .resolved("s3cret!"))
    }

    func testProtectedStandardFieldsAndAnEmptyPassword() throws {
        var target = try makeTarget()
        target.protectedStringKeys = ["Notes", "UserName"]
        let empty = KPEntry(title: "Empty")
        let resolver = FieldReferenceResolver(entries: [target, empty], sessionKey: sessionKey)
        XCTAssertEqual(resolver.resolve("{REF:N@T:Mail Server}"), .needsProtectedValue)
        XCTAssertEqual(resolver.resolve("{REF:T@U:mailbox}"), .needsProtectedValue, "Matching a protected username")
        XCTAssertEqual(resolver.resolve("{REF:A@T:Mail Server}"), .resolved("https://mail.example.com"))
        XCTAssertEqual(resolver.resolve("{REF:P@T:Empty}"), .resolved(""), "No password, nothing protected")
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
