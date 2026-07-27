import CryptoKit
import Foundation
import XCTest
@testable import KeeForge

/// Known-answer tests for the hand-rolled inner-stream ChaCha20 in `KDBXCrypto`.
///
/// The existing suite exercises ChaCha20 only through round-trip and synthetic
/// fixtures, which cannot detect a subtly-wrong keystream (encrypt/decrypt cancel
/// out even when the state setup or quarter-rounds are off). These vectors pin the
/// output to the ChaCha20 reference in RFC 8439, independent of this codebase.
final class ChaCha20Tests: XCTestCase {

    /// RFC 8439, Appendix A.1, Test Vector #1: all-zero key and nonce, block
    /// counter 0 (which is where `KDBXCrypto` starts its counter). ChaCha20 is
    /// XOR-based, so encrypting 64 zero bytes yields the raw keystream block.
    func test_chacha20_matchesRFC8439_appendixA1_vector1() throws {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 12)
        let zeros = Data(repeating: 0, count: 64)

        let expectedKeystream = Data([
            0x76, 0xb8, 0xe0, 0xad, 0xa0, 0xf1, 0x3d, 0x90,
            0x40, 0x5d, 0x6a, 0xe5, 0x53, 0x86, 0xbd, 0x28,
            0xbd, 0xd2, 0x19, 0xb8, 0xa0, 0x8d, 0xed, 0x1a,
            0xa8, 0x36, 0xef, 0xcc, 0x8b, 0x77, 0x0d, 0xc7,
            0xda, 0x41, 0x59, 0x7c, 0x51, 0x57, 0x48, 0x8d,
            0x77, 0x24, 0xe0, 0x3f, 0xb8, 0xd8, 0x4a, 0x37,
            0x6a, 0x43, 0xb8, 0xf4, 0x15, 0x18, 0xa1, 0x1c,
            0xc3, 0x87, 0xb6, 0x69, 0xb2, 0xee, 0x65, 0x86,
        ])

        let keystream = try KDBXCrypto.encryptChaCha20(data: zeros, key: key, nonce: nonce)
        XCTAssertEqual(keystream, expectedKeystream)
    }

    /// The decrypt entry point must reproduce the same keystream (it is XOR-based),
    /// so decrypting the reference keystream recovers the original zero bytes.
    func test_chacha20_decryptRecoversPlaintext_forRFC8439Vector1() throws {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 12)
        let zeros = Data(repeating: 0, count: 64)

        let keystream = try KDBXCrypto.encryptChaCha20(data: zeros, key: key, nonce: nonce)
        let recovered = try KDBXCrypto.decryptChaCha20(data: keystream, key: key, nonce: nonce)
        XCTAssertEqual(recovered, zeros)
    }

    /// A multi-block payload must advance the block counter correctly, so the
    /// first 64 bytes still match the Test Vector #1 keystream when a longer
    /// buffer is encrypted in one call.
    func test_chacha20_firstBlockMatches_whenEncryptingMultipleBlocks() throws {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 12)
        let zeros = Data(repeating: 0, count: 160) // 2.5 blocks

        let keystream = try KDBXCrypto.encryptChaCha20(data: zeros, key: key, nonce: nonce)

        let expectedFirstBlock = Data([
            0x76, 0xb8, 0xe0, 0xad, 0xa0, 0xf1, 0x3d, 0x90,
            0x40, 0x5d, 0x6a, 0xe5, 0x53, 0x86, 0xbd, 0x28,
            0xbd, 0xd2, 0x19, 0xb8, 0xa0, 0x8d, 0xed, 0x1a,
            0xa8, 0x36, 0xef, 0xcc, 0x8b, 0x77, 0x0d, 0xc7,
            0xda, 0x41, 0x59, 0x7c, 0x51, 0x57, 0x48, 0x8d,
            0x77, 0x24, 0xe0, 0x3f, 0xb8, 0xd8, 0x4a, 0x37,
            0x6a, 0x43, 0xb8, 0xf4, 0x15, 0x18, 0xa1, 0x1c,
            0xc3, 0x87, 0xb6, 0x69, 0xb2, 0xee, 0x65, 0x86,
        ])

        XCTAssertEqual(Data(keystream.prefix(64)), expectedFirstBlock)
        XCTAssertEqual(keystream.count, 160)
    }

    // MARK: - Shared keystream primitive

    /// RFC 8439, Appendix A.1, Test Vectors #1 and #2 concatenated: same all-zero
    /// key and nonce, block counters 0 and 1. `ChaCha20Keystream` starts at
    /// counter 0 and must advance exactly once per 64-byte block, so 128 zero
    /// bytes have to reproduce both reference blocks back to back.
    func test_chacha20Keystream_matchesRFC8439AppendixA1_vectors1And2() throws {
        var keystream = try XCTUnwrap(
            KDBXCrypto.ChaCha20Keystream(key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 12))
        )

        let expected = try XCTUnwrap(Data(hex:
            "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7" +
            "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586" +
            "9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed" +
            "29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f"
        ))

        XCTAssertEqual(keystream.xor(Data(repeating: 0, count: 128)), expected)
    }

    /// The keystream is continuous across calls, so feeding it in arbitrary
    /// chunks must equal one single-shot call over the concatenation.
    func test_chacha20Keystream_isContinuousAcrossCalls() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let nonce = Data((0..<12).map { UInt8(0xA0 + $0) })
        let plaintext = Data((0..<300).map { UInt8($0 % 251) })

        var chunked = try XCTUnwrap(KDBXCrypto.ChaCha20Keystream(key: key, nonce: nonce))
        var incremental = Data()
        var start = 0
        for length in [63, 1, 64, 65, 107] {
            incremental += chunked.xor(plaintext.subdata(in: start..<(start + length)))
            start += length
        }

        XCTAssertEqual(start, plaintext.count)
        XCTAssertEqual(incremental, KDBXCrypto.chacha20Stream(key: key, nonce: nonce, data: plaintext))
    }

    /// An empty protected value must not consume keystream — the parser and the
    /// serializer both skip empty values, so a stream that advanced here would
    /// desynchronize read from write.
    func test_chacha20Keystream_emptyInputDoesNotConsumeKeystream() throws {
        let key = Data(repeating: 0x5A, count: 32)
        let nonce = Data(repeating: 0x17, count: 12)

        var withEmpties = try XCTUnwrap(KDBXCrypto.ChaCha20Keystream(key: key, nonce: nonce))
        XCTAssertEqual(withEmpties.xor(Data()), Data())
        let first = withEmpties.xor(Data(repeating: 0, count: 32))
        XCTAssertEqual(withEmpties.xor(Data()), Data())
        let second = withEmpties.xor(Data(repeating: 0, count: 32))

        var reference = try XCTUnwrap(KDBXCrypto.ChaCha20Keystream(key: key, nonce: nonce))
        XCTAssertEqual(first + second, reference.xor(Data(repeating: 0, count: 64)))
    }

    func test_chacha20Keystream_rejectsWrongSizedKeyOrNonce() {
        XCTAssertNil(KDBXCrypto.ChaCha20Keystream(key: Data(repeating: 0, count: 31), nonce: Data(repeating: 0, count: 12)))
        XCTAssertNil(KDBXCrypto.ChaCha20Keystream(key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 8)))
    }

    // MARK: - KDBX4 protected stream

    /// Known-answer vectors for the shared primitive driven through the KDBX4
    /// protected-stream convention: ChaCha20 key = SHA-512(inner stream key)
    /// bytes 0..<32, nonce = bytes 32..<44, one keystream spanning every
    /// protected value in document order.
    ///
    /// Ciphertexts were produced independently of this codebase with Python's
    /// `cryptography` ChaCha20 (validated against RFC 8439 Appendix A.1 first).
    func test_innerStreamChaCha20_matchesKnownAnswerVectors_acrossBlockBoundaries() throws {
        var keystream = try XCTUnwrap(Self.makeInnerStreamKeystream())

        for value in Self.protectedValues {
            let expected = try XCTUnwrap(Data(hex: value.chachaCiphertextHex))
            XCTAssertEqual(
                keystream.xor(Data(value.plaintext.utf8)),
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
            innerStreamKey: Self.innerStreamKey,
            innerStreamID: KDBXParser.innerStreamChaCha20,
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
            innerStreamKey: Self.innerStreamKey,
            innerStreamID: KDBXParser.innerStreamChaCha20,
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

    private static func makeInnerStreamKeystream() -> KDBXCrypto.ChaCha20Keystream? {
        let keyHash = KDBXCrypto.sha512(innerStreamKey)
        return KDBXCrypto.ChaCha20Keystream(key: Data(keyHash.prefix(32)), nonce: Data(keyHash[32..<44]))
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
