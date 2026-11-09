import CryptoKit
import XCTest
@testable import KDBXKit

final class SecureWipeTests: XCTestCase {
    func testWipesDataInPlace() {
        var data = Data(repeating: 0xAB, count: 64)
        SecureWipe.wipe(&data)
        XCTAssertEqual(data, Data(count: 64))
    }

    func testWipesArraysOfAnyElement() {
        var bytes: [UInt8] = [1, 2, 3]
        var words: [UInt32] = [0xFFFF_FFFF, 7]
        SecureWipe.wipe(&bytes)
        SecureWipe.wipe(&words)
        XCTAssertEqual(bytes, [0, 0, 0])
        XCTAssertEqual(words, [0, 0])
    }

    func testWipesARawBuffer() {
        var bytes: [UInt8] = [9, 9, 9, 9]
        bytes.withUnsafeMutableBytes { buffer in
            SecureWipe.wipe(UnsafeMutableRawBufferPointer(rebasing: buffer[1..<3]))
        }
        XCTAssertEqual(bytes, [9, 0, 0, 9])
    }

    func testEmptyBuffersAreANoOp() {
        var data = Data()
        var array: [UInt8] = []
        SecureWipe.wipe(&data)
        SecureWipe.wipe(&array)
        SecureWipe.wipe(UnsafeMutableRawBufferPointer(start: nil, count: 0))
        XCTAssertTrue(data.isEmpty)
        XCTAssertTrue(array.isEmpty)
    }

    func testWipingDataCopiesTheBytes() {
        var source: [UInt8] = [1, 2, 3, 4]
        let copy = SecureWipe.wipingData(copying: source)
        source[0] = 0xFF
        XCTAssertEqual(copy, Data([1, 2, 3, 4]))
        XCTAssertEqual(SecureWipe.wipingData(copying: Data("secret".utf8)).count, 6)
    }

    func testWipingDataOfNothingIsEmpty() {
        XCTAssertEqual(SecureWipe.wipingData(copying: [UInt8]()), Data())
    }

    /// The custom deallocator runs, and copies made from the value are independent.
    func testWipingDataSurvivesCopiesAndRelease() {
        var derived = Data()
        do {
            let wiping = SecureWipe.wipingData(copying: Data(repeating: 0x5C, count: 32))
            derived = Data(wiping.prefix(4))
            var mutated = wiping
            mutated[0] = 0
            XCTAssertEqual(wiping.first, 0x5C)
        }
        XCTAssertEqual(derived, Data(repeating: 0x5C, count: 4))
    }

    /// A `Data` over a caller-owned allocation shows the wipe reached the
    /// original bytes, not a copy-on-write duplicate.
    func testWipeHitsTheOriginalBufferOfUniquelyOwnedData() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 1)
        defer { buffer.deallocate() }
        buffer.copyBytes(from: [UInt8](repeating: 0x7E, count: 32))
        var data = Data(bytesNoCopy: buffer.baseAddress!, count: 32, deallocator: .none)
        SecureWipe.wipe(&data)
        XCTAssertTrue(buffer.allSatisfy { $0 == 0 })
    }

    /// The caveat in `SecureWipe`'s contract: a second reference forces a
    /// copy, so the original bytes survive.
    func testWipeOfSharedDataZeroesACopyNotTheOriginal() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 1)
        defer { buffer.deallocate() }
        buffer.copyBytes(from: [UInt8](repeating: 0x7E, count: 32))
        var data = Data(bytesNoCopy: buffer.baseAddress!, count: 32, deallocator: .none)
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
        XCTAssertEqual(data, key.bytes)
        XCTAssertEqual(bridged.length, 32)
        XCTAssertEqual(data.withUnsafeBytes { $0.baseAddress }, UnsafeRawPointer(bridged.bytes))
    }
}
