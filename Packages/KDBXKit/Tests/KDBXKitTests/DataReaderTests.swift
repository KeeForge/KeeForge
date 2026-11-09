import XCTest
@testable import KDBXKit

final class DataReaderTests: XCTestCase {
    func testReadsLittleEndianIntegersInSequence() throws {
        var reader = DataReader(data: Data([
            0xAB,
            0x34, 0x12,
            0x78, 0x56, 0x34, 0x12,
            0xFE, 0xFF, 0xFF, 0xFF,
        ]))
        XCTAssertTrue(reader.hasMore)
        XCTAssertEqual(try reader.readUInt8(), 0xAB)
        XCTAssertEqual(try reader.readUInt16(), 0x1234)
        XCTAssertEqual(try reader.readUInt32(), 0x1234_5678)
        XCTAssertEqual(try reader.readInt32(), -2)
        XCTAssertFalse(reader.hasMore)
        XCTAssertEqual(reader.offset, 11)
    }

    func testReadBytesAndSkipAdvance() throws {
        var reader = DataReader(data: Data([1, 2, 3, 4, 5]))
        try reader.skip(1)
        XCTAssertEqual(try reader.readBytes(3), Data([2, 3, 4]))
        XCTAssertEqual(try reader.readBytes(0), Data())
        XCTAssertEqual(reader.offset, 4)
    }

    func testReadsPastTheEndThrowTruncatedWithoutAdvancing() {
        var reader = DataReader(data: Data([1, 2, 3]))
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try reader.readUInt32() }
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try reader.readBytes(4) }
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try reader.skip(4) }
        XCTAssertEqual(reader.offset, 0)
    }

    func testNegativeCountThrowsTruncated() {
        var reader = DataReader(data: Data([1, 2, 3]))
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try reader.readBytes(-1) }
    }

    func testHugeCountDoesNotOverflow() {
        var reader = DataReader(data: Data([1, 2, 3]))
        try? reader.skip(1)
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try reader.readBytes(.max) }
    }

    func testFieldSizedIntegerReadsTheFirstBytesOfALongerField() throws {
        var reader = DataReader(data: Data([0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x09]))
        let value: UInt32 = try reader.readInteger(fieldSize: 6)
        XCTAssertEqual(value, 1)
        XCTAssertEqual(try reader.readUInt8(), 0x09)
    }

    func testFieldSizedIntegerRejectsAShorterField() {
        var reader = DataReader(data: Data([0x01, 0x00, 0x00]))
        assertThrows(KDBXContainer.ParseError.truncatedFile) {
            let _: UInt32 = try reader.readInteger(fieldSize: 3)
        }
    }

    func testLittleEndianDataRoundTrips() {
        XCTAssertEqual(Data(littleEndian: UInt16(0x0102)), Data([0x02, 0x01]))
        XCTAssertEqual(Data(littleEndian: Int32(-1)), Data([0xFF, 0xFF, 0xFF, 0xFF]))
        var data = Data([0xAA])
        data.appendLittleEndian(UInt64(0x0102_0304_0506_0708))
        XCTAssertEqual(data, Data([0xAA, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]))
    }
}
