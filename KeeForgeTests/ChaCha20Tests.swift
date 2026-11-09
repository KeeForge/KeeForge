import CryptoKit
import Foundation
import XCTest
import KDBXKit
@testable import KeeForge

/// Known-answer tests for KDBX 4 protected values. A round trip cannot detect a
/// wrong keystream, since encrypt and decrypt cancel out; these vectors pin the
/// serializer and parser to ciphertexts produced outside this codebase. The
/// ChaCha20 primitive itself is tested in `Packages/KDBXKit`.
final class ChaCha20Tests: XCTestCase {

    /// Known-answer vectors for the shared primitive driven through the KDBX4
    /// protected-stream convention: ChaCha20 key = SHA-512(inner stream key)
    /// bytes 0..<32, nonce = bytes 32..<44, one keystream spanning every
    /// protected value in document order.
    ///
    /// Ciphertexts were produced independently of this codebase with Python's
    /// `cryptography` ChaCha20 (validated against RFC 8439 Appendix A.1 first).
    func test_innerStreamChaCha20_matchesKnownAnswerVectors_acrossBlockBoundaries() throws {
        var keystream = try Self.makeInnerStreamKeystream()

        for value in Self.protectedValues {
            let expected = try XCTUnwrap(Data(hex: value.chachaCiphertextHex))
            XCTAssertEqual(
                keystream.apply(Data(value.plaintext.utf8)),
                expected,
                "protected value \(value.key) (\(value.plaintext.count) bytes)"
            )
        }
    }

    /// The serializer must consume the shared keystream in document order with
    /// no gaps, so its emitted base64 has to equal the same known-answer vectors.
    func test_serializerProtectedValues_matchKnownAnswerVectors() throws {
        let xml = try Self.serializeProtectedValueEntry(sessionKey: sessionKey)
        let emitted = Self.protectedBase64Values(in: xml)

        // The always-protected, always-emitted `Password` field comes first and
        // is empty here, so it contributes no keystream.
        let expected = [""] + Self.protectedValues.map { value in
            (Data(hex: value.chachaCiphertextHex) ?? Data()).base64EncodedString()
        }
        XCTAssertEqual(emitted, expected)
    }

    /// Serializer-side encryption and parser-side decryption now share one
    /// implementation; this pins that they still agree end to end, including
    /// values that straddle 64-byte block boundaries.
    func test_serializerProtectedValues_decryptBackThroughParser() throws {
        let xml = try Self.serializeProtectedValueEntry(sessionKey: sessionKey)
        let parsed = try KDBXXMLParser(
            data: xml,
            innerStream: KDBXInnerStream(streamID: KDBXInnerStream.Algorithm.chaCha20.rawValue, key: Self.innerStreamKey),
            sessionKey: sessionKey
        ).parse()

        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first)
        for value in Self.protectedValues {
            XCTAssertEqual(entry.customFields[value.key], value.plaintext, "protected value \(value.key)")
        }
        XCTAssertTrue(entry.protectedStringKeys.isSuperset(of: Self.protectedValues.map(\.key)))
    }

    /// Stream-offset accumulation over many protected values: a per-value counter
    /// reset or a dropped offset shows up as garbage from the first mismatch on.
    func test_manyProtectedValues_roundTripThroughSerializerAndParser() throws {
        let fields = (0..<120).map { index in
            (key: String(format: "Field%03d", index), value: "secret-\(index)-" + String(repeating: "x", count: index))
        }
        var entry = KPEntry(title: "Many", password: .empty)
        entry.customFields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        entry.protectedStringKeys = Set(fields.map(\.key))

        var serializer = KDBXXMLSerializer(
            rootGroup: KPGroup(id: UUID(), name: "Root", entries: [entry]),
            meta: KPMeta(),
            innerStreamKey: Self.innerStreamKey,
            sessionKey: sessionKey
        )
        let parsed = try KDBXXMLParser(
            data: try serializer.serialize(),
            innerStream: KDBXInnerStream(streamID: KDBXInnerStream.Algorithm.chaCha20.rawValue, key: Self.innerStreamKey),
            sessionKey: sessionKey
        ).parse()

        let reparsed = try XCTUnwrap(parsed.rootGroup.allEntries.first)
        for field in fields {
            XCTAssertEqual(reparsed.customFields[field.key], field.value, "field \(field.key)")
        }
    }

    // MARK: - Fixtures


    private let sessionKey = SymmetricKey(size: .bits256)

    /// Arbitrary 64-byte inner stream key (0x00…0x3F) the pinned vectors were
    /// generated against.
    private static let innerStreamKey = Data((0..<64).map { UInt8($0) })

    private struct ProtectedValueVector {
        let key: String
        let plaintext: String
        let chachaCiphertextHex: String
    }

    /// Lengths straddling the 64-byte block boundary (63/1/64/65) plus a
    /// multi-block run, consumed in this order as one continuous keystream. The
    /// keys sort in this order, which is the order the serializer emits them in.
    private static let protectedValues: [ProtectedValueVector] = [
        ProtectedValueVector(
            key: "A",
            plaintext: String(repeating: "a", count: 63),
            chachaCiphertextHex:
                "ed89dd006ba13e9382bce9d5fb7565a3e52e75e156631517d95c399401fbbe0" +
                "4999be6b9d494491e0d9cdcd7fbbfc3982385cd94c8ccffe76742261b12c32d"
        ),
        ProtectedValueVector(key: "B", plaintext: "b", chachaCiphertextHex: "2c"),
        ProtectedValueVector(
            key: "C",
            plaintext: String(repeating: "c", count: 64),
            chachaCiphertextHex:
                "59517b9f6065d3f6c48466bc0fd35c9f3a4e4f8580cad90f391bcbdfe8f3e912" +
                "b1f0f73a95235d06f8c723884cc92533801bdd558bfbb855094e0c4b363e1582"
        ),
        ProtectedValueVector(
            key: "D",
            plaintext: String(repeating: "d", count: 65),
            chachaCiphertextHex:
                "0cbf562ce13840b9b0ef1983bf87856d966c9769f7ca89b9f837e30740d417b4" +
                "00d4750f6e8a786d9ea8effd54cb69183277328a2c6a7793f114296a71deee3b" +
                "52"
        ),
        ProtectedValueVector(
            key: "E",
            plaintext: String(repeating: "e", count: 200),
            chachaCiphertextHex:
                "216d0d93741cd781a6b6348b30a873ba00ea5f761736c8ffe0685cfc30ae23b8" +
                "f8248dca974f2edfab49fe33003b4b8ffdaace1cc06d3bddb9ecd0dd504b54cd" +
                "a5add87d0bd8fc9b000ad0599f0e91bf3c9b574ee749cce2efb1dbded229f5e5" +
                "9994bf22680ab6b3223ff8e326394563061175ae156cb61e57fdc586dd995b99" +
                "1cfcfffbc010582a1ed24c82d651e898b3476e05ea6306091f93275ddd31fcc0" +
                "c355c3fa464ab66ea78425615bccb53e3c6caf8d0816fa456b7d67a6573ebb74" +
                "c09f9b6707d283da"
        ),
    ]

    private static func makeInnerStreamKeystream() throws -> KDBXInnerStream {
        try KDBXInnerStream(algorithm: .chaCha20, key: innerStreamKey)
    }

    private static func serializeProtectedValueEntry(sessionKey: SymmetricKey) throws -> Data {
        var entry = KPEntry(title: "Protected", password: .empty)
        entry.customFields = Dictionary(uniqueKeysWithValues: protectedValues.map { ($0.key, $0.plaintext) })
        entry.protectedStringKeys = Set(protectedValues.map(\.key))

        var serializer = KDBXXMLSerializer(
            rootGroup: KPGroup(id: UUID(), name: "Root", entries: [entry]),
            meta: KPMeta(),
            innerStreamKey: innerStreamKey,
            sessionKey: sessionKey
        )
        return try serializer.serialize()
    }

    private static func protectedBase64Values(in xml: Data) -> [String] {
        let text = String(decoding: xml, as: UTF8.self)
        return text
            .components(separatedBy: "<Value Protected=\"True\">")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</Value>").first }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }
}
