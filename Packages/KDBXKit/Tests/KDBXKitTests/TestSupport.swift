import CryptoKit
import Foundation
import XCTest
@testable import KDBXKit

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    /// Argon2d outputs for the KDBX 4 fixtures (64 MiB, 14 iterations, 2 lanes),
    /// computed with the phc-winner-argon2 reference code built with -O2, so
    /// tests skip the minute-long debug-build KDF.
    static let testTransformedKey = Data(hex: "02d522a7931eca56af313e3db1654f3ba40023d5368d48427b44a8d04e437680")
    static let keyFileTransformedKey = Data(hex: "418e3d0eef135139beb5c4ea3d6a8555c251d3948e9067c269d51f197deef092")
    static let chaCha20TransformedKey = Data(hex: "05a32048f8f57b2bc6903261bd9ff5d8734307da6677c8a14b0ffee90fdf362c")
    static let twofishTransformedKey = Data(hex: "0a13c98b8d86d5ceca1c8a284e92d6cad971b2489d39643e5c88b37a13925f3b")
    static let unknownInnerHeaderTransformedKey = Data(hex: "ba5c36968674e67c6f12c90b557c1ac579e26d97faed5027c730091ca11adf84")
    /// AES-KDF, 1,000,000 rounds, computed with Python's `cryptography`.
    static let legacyTransformedKey = Data(hex: "e1bf15b4b0090f65aa29d4b492a5b21dc3de1e13a6cebb71f35b77cdd5f6c639")
    static let legacyPassword = "testpassword123"
}

extension Data {
    /// Test-only; traps on malformed input.
    init(hex: String) {
        let digits = Array(hex.filter { !$0.isWhitespace })
        precondition(digits.count.isMultiple(of: 2))
        self.init(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// The same bytes at a non-zero start index, as `Data` slices arrive.
    var asSlice: Data {
        let padded = Data([0xEE, 0xEE, 0xEE]) + self
        return padded[3...]
    }
}

extension SymmetricKey {
    var bytes: Data { withUnsafeBytes { Data($0) } }
}

func assertThrows<E: Error & Equatable>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> some Any
) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual(error as? E, expected, "got \(error)", file: file, line: line)
    }
}

enum TestKDF {
    static let permissivePolicy = KDFExecutionPolicy(
        maxPeakMemoryBytes: .max,
        maxTotalWorkBytes: .max,
        maxParallelism: .max
    )

    /// Argon2id at 1 MiB and 1 iteration: fast even in a debug build.
    static func cheapArgon2(salt: Data? = Data(repeating: 0x5A, count: 32)) -> KDBXVariantMap {
        KDBXKeyDerivation.argon2(.init(
            variant: .id,
            iterations: 1,
            memoryBytes: 1024 * 1024,
            parallelism: 1,
            salt: salt
        )).parameters
    }

    static func cheapAESKDF(seed: Data? = Data(repeating: 0x33, count: 32)) -> KDBXVariantMap {
        KDBXKeyDerivation.aesKDF(rounds: 1, seed: seed).parameters
    }
}

/// Builds KDBX files byte by byte, independently of `KDBXContainerWriter`,
/// so reader tests can produce every malformed and nonstandard shape.
enum KDBX4Builder {
    static let transformedKey = Data(repeating: 0x42, count: 32)
    static let masterSeed = Data(repeating: 0x11, count: 32)
    static let aesIV = Data(repeating: 0x22, count: 16)

    typealias Field = (id: UInt8, value: Data)

    static func standardOuterFields(
        cipher: KDBXOuterCipher = .aes256CBC,
        compression: UInt32 = 1,
        iv: Data? = nil
    ) -> [Field] {
        [
            (2, cipher.uuid),
            (3, Data(littleEndian: compression)),
            (4, masterSeed),
            (7, iv ?? (cipher == .chaCha20 ? Data(repeating: 0x22, count: 12) : aesIV)),
            (11, TestKDF.cheapAESKDF().serialized()),
        ]
    }

    static func versionPrefix(minor: UInt16 = 0, major: UInt16 = 4) -> Data {
        var data = Data()
        data.appendLittleEndian(KDBXContainer.signature1)
        data.appendLittleEndian(KDBXContainer.signature2)
        data.appendLittleEndian(minor)
        data.appendLittleEndian(major)
        return data
    }

    static func fields(_ fields: [Field], sizeWidth: Int = 4) -> Data {
        var data = Data()
        for field in fields {
            data.append(field.id)
            if sizeWidth == 4 {
                data.appendLittleEndian(UInt32(field.value.count))
            } else {
                data.appendLittleEndian(UInt16(field.value.count))
            }
            data.append(field.value)
        }
        return data
    }

    static func outerHeader(minor: UInt16 = 0, fields outer: [Field]? = nil) -> Data {
        versionPrefix(minor: minor) + fields((outer ?? standardOuterFields()) + [(0, Data([0x0D, 0x0A, 0x0D, 0x0A]))])
    }

    static func innerHeader(streamID: UInt32 = 3, key: Data = Data(repeating: 0x77, count: 64), extra: [Field] = [], terminated: Bool = true) -> Data {
        var list: [Field] = [(1, Data(littleEndian: streamID)), (2, key)] + extra
        if terminated { list.append((0, Data())) }
        return fields(list)
    }

    static func masterKeys(transformedKey: Data = transformedKey) -> (cipherKey: Data, hmacBase: Data) {
        let material = masterSeed + transformedKey
        return (
            Data(SHA256.hash(data: material)),
            Data(SHA512.hash(data: material + Data([0x01])))
        )
    }

    static func blockKey(index: UInt64, base: Data) -> Data {
        Data(SHA512.hash(data: Data(littleEndian: index) + base))
    }

    static func hmac(_ message: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func blocks(_ payload: Data, base: Data, blockSize: Int = 1 << 20) -> Data {
        var output = Data()
        var index: UInt64 = 0
        var offset = 0
        while true {
            let block = payload.subdata(in: offset..<min(payload.count, offset + blockSize))
            let message = Data(littleEndian: index) + Data(littleEndian: Int32(block.count)) + block
            output += hmac(message, key: blockKey(index: index, base: base))
            output.appendLittleEndian(Int32(block.count))
            output += block
            if block.isEmpty { return output }
            offset += block.count
            index += 1
        }
    }

    /// A complete file: header, its SHA-256 and HMAC, then `plaintextPayload`
    /// encrypted with `cipher` and framed into HMAC blocks.
    static func file(
        header: Data = outerHeader(),
        plaintextPayload: Data,
        cipher: KDBXOuterCipher = .aes256CBC,
        iv: Data = aesIV
    ) throws -> Data {
        let keys = masterKeys()
        let encrypted = try cipher.encrypt(data: plaintextPayload, key: keys.cipherKey, iv: iv)
        return header
            + Data(SHA256.hash(data: header))
            + hmac(header, key: blockKey(index: .max, base: keys.hmacBase))
            + blocks(encrypted, base: keys.hmacBase)
    }

    static let xml = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><KeePassFile><Meta/></KeePassFile>".utf8)

    static func read(_ data: Data, transformedKey: Data = transformedKey) throws -> KDBXContainer.Payload {
        try KDBXContainer.read(data: data) { _ in transformedKey }
    }
}

/// Builds KDBX 3.1 files: 2-byte field sizes, stream start bytes, and
/// SHA-256 hashed blocks.
enum KDBX3Builder {
    static let startBytes = Data((0..<32).map { UInt8($0) })

    static func header(
        cipher: Data = KDBXOuterCipher.aes256CBC.uuid,
        compression: UInt32 = 0,
        streamID: UInt32 = 2,
        startBytes: Data = startBytes,
        extra: [KDBX4Builder.Field] = []
    ) -> Data {
        let fields: [KDBX4Builder.Field] = [
            (2, cipher),
            (3, Data(littleEndian: compression)),
            (4, KDBX4Builder.masterSeed),
            (5, Data(repeating: 0x33, count: 32)),
            (6, Data(littleEndian: UInt64(1))),
            (7, KDBX4Builder.aesIV),
            (8, Data(repeating: 0x44, count: 32)),
            (9, startBytes),
            (10, Data(littleEndian: streamID)),
        ] + extra + [(0, Data([0x0D, 0x0A, 0x0D, 0x0A]))]
        return KDBX4Builder.versionPrefix(minor: 1, major: 3) + KDBX4Builder.fields(fields, sizeWidth: 2)
    }

    static func hashedBlock(index: UInt32, _ block: Data, hash: Data? = nil, size: Int32? = nil) -> Data {
        var data = Data(littleEndian: index)
        data += hash ?? (block.isEmpty ? Data(count: 32) : Data(SHA256.hash(data: block)))
        data.appendLittleEndian(size ?? Int32(block.count))
        data += block
        return data
    }

    static func blockStream(_ content: Data) -> Data {
        hashedBlock(index: 0, content) + hashedBlock(index: 1, Data())
    }

    static func file(
        header: Data = header(),
        decryptedPayload: Data,
        cipher: KDBXOuterCipher = .aes256CBC
    ) throws -> Data {
        let keys = KDBX4Builder.masterKeys()
        return header + (try cipher.encrypt(data: decryptedPayload, key: keys.cipherKey, iv: KDBX4Builder.aesIV))
    }
}

/// A decrypted KDBX payload: one KeePassFile document, whole.
func isKeePassXML(_ xml: Data) -> Bool {
    let text = String(decoding: xml, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.contains("<KeePassFile>") && text.hasSuffix("</KeePassFile>")
}
