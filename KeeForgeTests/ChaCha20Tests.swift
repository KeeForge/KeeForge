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
}
