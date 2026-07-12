import Foundation
import XCTest
@_spi(Testing) import KeeForgeTwofish

final class TwofishTests: XCTestCase {
    private let kdbxKey = Data((0..<32).map(UInt8.init))
    private let iv = Data((16..<32).map(UInt8.init))

    func test_officialSingleBlockKnownAnswerVectors_encryptAndDecrypt() throws {
        // Twofish book, Appendix B.2, zero-key/zero-plaintext known-answer vectors.
        let vectors: [(keyBytes: Int, ciphertext: String)] = [
            (16, "9f589f5cf6122c32b6bfec2f2ae8c35a"),
            (24, "efa71f788965bd4453f860178fc19101"),
            (32, "57ff739d4dc92c1bd7fc01700cc8216f"),
        ]

        for vector in vectors {
            let key = Data(repeating: 0, count: vector.keyBytes)
            let plaintext = Data(repeating: 0, count: 16)
            let expectedCiphertext = try XCTUnwrap(Data(hex: vector.ciphertext))

            let ciphertext = try TwofishBlock.encrypt(plaintext, key: key)
            XCTAssertEqual(ciphertext, expectedCiphertext, "key bytes: \(vector.keyBytes)")
            XCTAssertEqual(
                try TwofishBlock.decrypt(ciphertext, key: key),
                plaintext,
                "key bytes: \(vector.keyBytes)"
            )
        }
    }

    func test_cbcPKCS7_matchesIndependentImplementationVector() throws {
        // Generated with pykeepass 4.1.1's pure-Python Bjorn Edstrom/Gladman
        // implementation, independent of Ferguson v0.3. Key=00...1f, IV=10...1f.
        let plaintext = Data("KeeForge Twofish CBC interoperability vector.".utf8)
        let expected = try XCTUnwrap(Data(hex:
            "763c1bc25be8e99a7b1ce6ec5f8c2ef3" +
            "24060582d1d7302c9b5591443c6482db" +
            "2bc65b525463e5ce0c91d2e0bfe74238"
        ))

        let ciphertext = try TwofishCBC.encrypt(plaintext, key: kdbxKey, iv: iv)
        XCTAssertEqual(ciphertext, expected)
        XCTAssertEqual(try TwofishCBC.decrypt(expected, key: kdbxKey, iv: iv), plaintext)
    }

    func test_pkcs7RoundTripsBoundaryLengths() throws {
        for length in [0, 1, 15, 16, 17, 31, 32, 64] {
            let plaintext = Data((0..<length).map { UInt8($0 & 0xff) })
            let ciphertext = try TwofishCBC.encrypt(plaintext, key: kdbxKey, iv: iv)

            XCTAssertEqual(ciphertext.count, ((length / 16) + 1) * 16)
            XCTAssertEqual(try TwofishCBC.decrypt(ciphertext, key: kdbxKey, iv: iv), plaintext)
        }
    }

    func test_exactBlockPlaintext_addsCompletePaddingBlock() throws {
        let plaintext = Data(repeating: 0xa5, count: 16)
        let ciphertext = try TwofishCBC.encrypt(plaintext, key: kdbxKey, iv: iv)

        XCTAssertEqual(ciphertext.count, 32)
        XCTAssertEqual(try TwofishCBC.decrypt(ciphertext, key: kdbxKey, iv: iv), plaintext)
    }

    func test_rejectsInvalidKDBXKeyLengths() throws {
        for length in [0, 16, 24, 31, 33] {
            XCTAssertThrowsError(
                try TwofishCBC.encrypt(Data(), key: Data(repeating: 0, count: length), iv: iv)
            ) { error in
                XCTAssertEqual(error as? TwofishError, .invalidKeyLength(actual: length))
            }
        }
    }

    func test_rejectsInvalidIVLengths() throws {
        for length in [0, 15, 17] {
            XCTAssertThrowsError(
                try TwofishCBC.encrypt(
                    Data(),
                    key: kdbxKey,
                    iv: Data(repeating: 0, count: length)
                )
            ) { error in
                XCTAssertEqual(error as? TwofishError, .invalidIVLength(actual: length))
            }
        }
    }

    func test_rejectsEmptyAndNonAlignedCiphertext() throws {
        for length in [0, 1, 15, 17, 31] {
            XCTAssertThrowsError(
                try TwofishCBC.decrypt(
                    Data(repeating: 0, count: length),
                    key: kdbxKey,
                    iv: iv
                )
            ) { error in
                XCTAssertEqual(
                    error as? TwofishError,
                    .invalidCiphertextLength(actual: length)
                )
            }
        }
    }

    func test_rejectsZeroPaddingByte() throws {
        let rawBlock = [UInt8](repeating: 0x41, count: 15) + [0]
        try assertInvalidPadding(rawBlock)
    }

    func test_rejectsPaddingByteGreaterThanBlockSize() throws {
        let rawBlock = [UInt8](repeating: 0x41, count: 15) + [17]
        try assertInvalidPadding(rawBlock)
    }

    func test_rejectsInconsistentPaddingBytes() throws {
        let rawBlock = [UInt8](repeating: 0x41, count: 14) + [3, 2]
        try assertInvalidPadding(rawBlock)
    }

    func test_concurrentOperations_areDeterministicAndIsolated() async throws {
        struct ConcurrentResult: Sendable {
            let index: Int
            let plaintext: Data
            let ciphertext: Data
            let secondCiphertext: Data
            let decrypted: Data
        }

        let results = try await withThrowingTaskGroup(
            of: ConcurrentResult.self,
            returning: [ConcurrentResult].self
        ) { group in
            for index in 0..<100 {
                group.addTask {
                    let key = Data((0..<32).map { UInt8(($0 + index) & 0xff) })
                    let operationIV = Data((0..<16).map { UInt8(($0 * 3 + index) & 0xff) })
                    let plaintext = Data((0..<(index + 1)).map { UInt8(($0 * 7 + index) & 0xff) })
                    let ciphertext = try TwofishCBC.encrypt(
                        plaintext,
                        key: key,
                        iv: operationIV
                    )
                    let secondCiphertext = try TwofishCBC.encrypt(
                        plaintext,
                        key: key,
                        iv: operationIV
                    )
                    let decrypted = try TwofishCBC.decrypt(
                        ciphertext,
                        key: key,
                        iv: operationIV
                    )
                    return ConcurrentResult(
                        index: index,
                        plaintext: plaintext,
                        ciphertext: ciphertext,
                        secondCiphertext: secondCiphertext,
                        decrypted: decrypted
                    )
                }
            }

            var collected: [ConcurrentResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, 100)
        XCTAssertEqual(Set(results.map(\.index)).count, 100)
        for result in results {
            XCTAssertEqual(result.ciphertext, result.secondCiphertext)
            XCTAssertEqual(result.decrypted, result.plaintext)
        }
    }

    private func assertInvalidPadding(
        _ rawPlaintextBlock: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(rawPlaintextBlock.count, 16, file: file, line: line)
        let xoredWithIV = Data(zip(rawPlaintextBlock, iv).map { plaintext, ivByte in
            plaintext ^ ivByte
        })
        let ciphertext = try TwofishBlock.encrypt(xoredWithIV, key: kdbxKey)

        XCTAssertThrowsError(
            try TwofishCBC.decrypt(ciphertext, key: kdbxKey, iv: iv),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? TwofishError, .invalidPadding, file: file, line: line)
        }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }
}
