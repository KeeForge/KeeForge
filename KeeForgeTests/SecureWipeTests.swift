import CryptoKit
import XCTest
@testable import KeeForge

final class SecureWipeTests: XCTestCase {
    func testWipeZeroesUniquelyOwnedData() {
        var data = Data((1...64).map { UInt8($0) })
        XCTAssertTrue(data.contains { $0 != 0 })

        SecureWipe.wipe(&data)

        XCTAssertEqual(data.count, 64)
        XCTAssertTrue(data.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
    }

    func testWipeZeroesUniquelyOwnedByteArray() {
        var bytes = [UInt8](repeating: 0xAB, count: 32)

        SecureWipe.wipe(&bytes)

        XCTAssertEqual(bytes.count, 32)
        XCTAssertTrue(bytes.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
    }

    func testWipeZeroesRawBuffer() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 48, alignment: 1)
        defer { buffer.deallocate() }
        buffer.copyBytes(from: [UInt8](repeating: 0x5C, count: 48))

        SecureWipe.wipe(buffer)

        XCTAssertTrue(buffer.allSatisfy { $0 == 0 })
    }

    func testWipeHitsTheOriginalBufferOfUniquelyOwnedData() {
        // A Data over a caller-owned allocation lets the test inspect the raw bytes
        // after the wipe, proving no copy-on-write duplicate was zeroed instead.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 1)
        defer { buffer.deallocate() }
        buffer.copyBytes(from: [UInt8](repeating: 0x7E, count: 32))
        var data = Data(bytesNoCopy: buffer.baseAddress.unsafelyUnwrapped, count: 32, deallocator: .none)

        SecureWipe.wipe(&data)

        XCTAssertTrue(buffer.allSatisfy { $0 == 0 })
    }

    func testWipeOfSharedDataZeroesACopyNotTheOriginal() {
        // Documents the caveat SecureWipe relies on: a second reference forces
        // copy-on-write, so the original bytes survive.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 1)
        defer { buffer.deallocate() }
        buffer.copyBytes(from: [UInt8](repeating: 0x7E, count: 32))
        var data = Data(bytesNoCopy: buffer.baseAddress.unsafelyUnwrapped, count: 32, deallocator: .none)
        let shared = data

        SecureWipe.wipe(&data)

        XCTAssertTrue(data.allSatisfy { $0 == 0 })
        XCTAssertTrue(shared.allSatisfy { $0 == 0x7E })
        XCTAssertTrue(buffer.allSatisfy { $0 == 0x7E })
    }

    func testWipingDataCarriesTheKeyBytesAndBridgesWithoutCopying() {
        let key = SymmetricKey(size: .bits256)

        let data = SecureWipe.wipingData(copying: key)
        let bridged = data as NSData

        XCTAssertEqual(data, key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(bridged.length, 32)
        XCTAssertEqual(data.withUnsafeBytes { $0.baseAddress }, UnsafeRawPointer(bridged.bytes))
        XCTAssertTrue(SecureWipe.wipingData(copying: Data()).isEmpty)
    }

    func testWipeToleratesEmptyBuffers() {
        var data = Data()
        var bytes: [UInt8] = []

        SecureWipe.wipe(&data)
        SecureWipe.wipe(&bytes)
        SecureWipe.wipe(UnsafeMutableRawBufferPointer(start: nil, count: 0))

        XCTAssertTrue(data.isEmpty)
        XCTAssertTrue(bytes.isEmpty)
    }

    func testCompositeKeyIsIndependentOfWipedIntermediates() throws {
        // The composite key must survive the wipe of the buffers it was derived from.
        let key = try KDBXCrypto.compositeKey(password: "correct horse", keyFileData: nil)
        var expected = Data(SHA256.hash(data: Data("correct horse".utf8)))
        expected = Data(SHA256.hash(data: expected))

        XCTAssertEqual(key, SymmetricKey(data: expected))
        XCTAssertEqual(key, KDBXCrypto.compositeKey(password: "correct horse"))
    }
}
