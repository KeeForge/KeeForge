import XCTest
@testable import KDBXKit

final class GzipTests: XCTestCase {
    private let limit = KDBXContainer.maxDecompressedPayloadSize

    /// Produced by `gzip` outside this codebase.
    func testDecompressesKnownGzipVector() throws {
        let compressed = Data(base64Encoded: "H4sIAAAAAAAC//NOTQ1LLM0pUUgvzavKLFAoS00uyS9SKEiszMlPTOHKycxLNQIAX50mACQAAAA=")!
        let text = String(decoding: try Gzip.decompress(compressed, maxOutputSize: limit), as: UTF8.self)
        XCTAssertEqual(text, "KeeVault gunzip vector payload\nline2")
    }

    /// Python's `zlib.compress` and a raw deflate stream (`wbits=-15`).
    func testFallsBackToZlibAndRawDeflate() throws {
        let expected = Data("KDBXKit compression vector\n".utf8)
        let zlib = Data(base64Encoded: "eJzzdnGK8M4sUUjOzy0oSi0uzszPUyhLTS7JL+ICAIeBCeE=")!
        let raw = Data(base64Encoded: "83ZxivDOLFFIzs8tKEotLs7Mz1MoS00uyS/iAgA=")!
        XCTAssertEqual(try Gzip.decompress(zlib, maxOutputSize: limit), expected)
        XCTAssertEqual(try Gzip.decompress(raw, maxOutputSize: limit), expected)
    }

    func testCompressWritesGzipThatRoundTrips() throws {
        let input = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 % 7) })
        let compressed = try Gzip.compress(input)
        XCTAssertEqual(Array(compressed.prefix(2)), [0x1F, 0x8B])
        XCTAssertLessThan(compressed.count, input.count)
        XCTAssertEqual(try Gzip.decompress(compressed, maxOutputSize: limit), input)
    }

    func testCompressSpansSeveralOutputBuffers() throws {
        var generator = SystemRandomNumberGenerator()
        let input = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        XCTAssertEqual(try Gzip.decompress(try Gzip.compress(input), maxOutputSize: limit), input)
    }

    func testCompressAcceptsASlice() throws {
        let input = Data("slice content".utf8).asSlice
        XCTAssertEqual(try Gzip.decompress(try Gzip.compress(input), maxOutputSize: limit), Data("slice content".utf8))
    }

    func testRejectsOutputAboveTheLimit() throws {
        let compressed = try Gzip.compress(Data(count: 200_000))
        XCTAssertEqual(try Gzip.decompress(compressed, maxOutputSize: 200_000).count, 200_000)
        assertThrows(KDBXContainer.ParseError.decompressedPayloadTooLarge) {
            try Gzip.decompress(compressed, maxOutputSize: 199_999)
        }
    }

    func testRejectsTruncatedStream() throws {
        let compressed = try Gzip.compress(Data(repeating: 0x41, count: 10_000))
        assertThrows(KDBXCrypto.CryptoError.decompressionFailed) {
            try Gzip.decompress(compressed.prefix(compressed.count - 10), maxOutputSize: self.limit)
        }
    }

    func testRejectsGarbage() {
        assertThrows(KDBXCrypto.CryptoError.decompressionFailed) {
            try Gzip.decompress(Data([0x1F, 0x8B, 0x08, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]), maxOutputSize: self.limit)
        }
        assertThrows(KDBXCrypto.CryptoError.decompressionFailed) {
            try Gzip.decompress(Data("<?xml version".utf8), maxOutputSize: self.limit)
        }
    }

    /// An empty result counts as a failure: a KDBX payload is never empty.
    func testEmptyOutputIsAFailure() throws {
        assertThrows(KDBXCrypto.CryptoError.decompressionFailed) {
            try Gzip.decompress(try Gzip.compress(Data()), maxOutputSize: self.limit)
        }
    }
}
