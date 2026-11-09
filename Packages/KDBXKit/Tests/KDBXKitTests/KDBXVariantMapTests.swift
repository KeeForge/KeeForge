import XCTest
@testable import KDBXKit

final class KDBXVariantMapTests: XCTestCase {
    private func entry(_ type: UInt8, _ key: String, _ value: Data) -> Data {
        var data = Data([type])
        data.appendLittleEndian(UInt32(key.utf8.count))
        data.append(Data(key.utf8))
        data.appendLittleEndian(UInt32(value.count))
        data.append(value)
        return data
    }

    private func map(version: UInt16 = 0x0100, _ entries: Data..., terminated: Bool = true) -> Data {
        var data = Data(littleEndian: version)
        entries.forEach { data.append($0) }
        if terminated { data.append(0) }
        return data
    }

    // MARK: - Accessors

    func testSubscriptAndTypedAccessors() {
        var map: KDBXVariantMap = ["a": .uint32(1), "b": .uint64(2), "c": .bytes(Data([3]))]
        XCTAssertEqual(map["a"], .uint32(1))
        XCTAssertEqual(map.uint32("a"), 1)
        XCTAssertEqual(map.uint64("b"), 2)
        XCTAssertEqual(map.bytes("c"), Data([3]))

        XCTAssertNil(map.uint32("b"), "wrong type")
        XCTAssertNil(map.uint64("a"), "wrong type")
        XCTAssertNil(map.bytes("a"), "wrong type")
        XCTAssertNil(map.uint32("missing"))

        map["a"] = .bool(true)
        XCTAssertEqual(map.entries["a"], .bool(true))
        map["a"] = nil
        XCTAssertNil(map["a"])
        XCTAssertEqual(KDBXVariantMap().entries, [:])
        XCTAssertEqual(KDBXVariantMap(["x": .int32(1)]).entries, ["x": .int32(1)])
    }

    func testDictionaryLiteralKeepsTheLastDuplicate() {
        let map: KDBXVariantMap = ["k": .uint32(1), "k": .uint32(2)]
        XCTAssertEqual(map.uint32("k"), 2)
    }

    // MARK: - Parsing

    func testParsesEveryKnownType() throws {
        let data = map(
            entry(0x04, "u32", Data([0x01, 0x00, 0x00, 0x00])),
            entry(0x05, "u64", Data([0x02, 0, 0, 0, 0, 0, 0, 0x80])),
            entry(0x08, "bool0", Data([0x00])),
            entry(0x08, "bool1", Data([0x02])),
            entry(0x0C, "i32", Data([0xFF, 0xFF, 0xFF, 0xFF])),
            entry(0x0D, "i64", Data([0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),
            entry(0x18, "str", Data("héllo".utf8)),
            entry(0x42, "bytes", Data([9, 8, 7])),
            entry(0x77, "future", Data([1, 2]))
        )
        let parsed = try KDBXVariantMap(serialized: data)
        XCTAssertEqual(parsed.entries, [
            "u32": .uint32(1),
            "u64": .uint64(0x8000_0000_0000_0002),
            "bool0": .bool(false),
            "bool1": .bool(true),
            "i32": .int32(-1),
            "i64": .int64(-2),
            "str": .string("héllo"),
            "bytes": .bytes(Data([9, 8, 7])),
            "future": .unknown(type: 0x77, data: Data([1, 2])),
        ])
    }

    func testKeepsANonUTF8StringAsUnknown() throws {
        let parsed = try KDBXVariantMap(serialized: map(entry(0x18, "s", Data([0xFF, 0xFE]))))
        XCTAssertEqual(parsed["s"], .unknown(type: 0x18, data: Data([0xFF, 0xFE])))
        XCTAssertEqual(try KDBXVariantMap(serialized: parsed.serialized()), parsed)
        XCTAssertEqual(parsed.serialized(), map(entry(0x18, "s", Data([0xFF, 0xFE]))))
    }

    func testAcceptsAMissingTerminatorAndANewerMinorVersion() throws {
        let parsed = try KDBXVariantMap(serialized: map(version: 0x01FF, entry(0x04, "a", Data(count: 4)), terminated: false))
        XCTAssertEqual(parsed.entries, ["a": .uint32(0)])
        XCTAssertEqual(try KDBXVariantMap(serialized: map(version: 0x0000)).entries, [:])
    }

    func testStopsAtTheTerminator() throws {
        var data = map(entry(0x04, "a", Data(count: 4)))
        data.append(Data([0xFF, 0xFF]))
        XCTAssertEqual(try KDBXVariantMap(serialized: data).entries, ["a": .uint32(0)])
    }

    func testRejectsANewerMajorVersion() {
        assertThrows(KDBXContainer.ParseError.malformedVariantMap) {
            try KDBXVariantMap(serialized: self.map(version: 0x0200))
        }
    }

    func testRejectsFixedWidthValuesOfTheWrongLength() {
        for (type, length) in [(UInt8(0x04), 3), (0x05, 4), (0x0C, 8), (0x0D, 7)] {
            assertThrows(KDBXContainer.ParseError.malformedVariantMap) {
                try KDBXVariantMap(serialized: self.map(self.entry(type, "k", Data(count: length))))
            }
        }
        assertThrows(KDBXContainer.ParseError.malformedVariantMap) {
            try KDBXVariantMap(serialized: self.map(self.entry(0x08, "k", Data())))
        }
    }

    func testRejectsANonUTF8Key() {
        var data = Data(littleEndian: UInt16(0x0100))
        data.append(0x04)
        data.appendLittleEndian(UInt32(2))
        data.append(Data([0xC3, 0x28]))
        data.appendLittleEndian(UInt32(4))
        data.append(Data(count: 4))
        assertThrows(KDBXContainer.ParseError.malformedVariantMap) { try KDBXVariantMap(serialized: data) }
    }

    func testTruncationAtEveryOffsetThrowsTruncated() {
        let first = entry(0x05, "key", Data(count: 8))
        let full = map(first, entry(0x42, "b", Data([1, 2, 3])))
        // A cut at an entry boundary is a valid unterminated map.
        let boundaries = [2, 2 + first.count, full.count - 1]
        for length in 0..<full.count where !boundaries.contains(length) {
            assertThrows(KDBXContainer.ParseError.truncatedFile) {
                try KDBXVariantMap(serialized: Data(full.prefix(length)))
            }
        }
    }

    // MARK: - Serializing

    /// KeePass's layout: version 0x0100, entries, then a zero type byte.
    func testSerializesInKeyByteOrder() {
        let map: KDBXVariantMap = [
            "b": .uint32(1),
            "B": .uint64(2),
            "é": .bool(true),
            "a": .int32(-1),
            "c": .int64(-2),
            "d": .string("x"),
            "e": .bytes(Data([0xAB])),
            "f": .unknown(type: 0x99, data: Data([1])),
        ]
        let expected = self.map(
            entry(0x05, "B", Data(littleEndian: UInt64(2))),
            entry(0x0C, "a", Data(littleEndian: Int32(-1))),
            entry(0x04, "b", Data(littleEndian: UInt32(1))),
            entry(0x0D, "c", Data(littleEndian: Int64(-2))),
            entry(0x18, "d", Data("x".utf8)),
            entry(0x42, "e", Data([0xAB])),
            entry(0x99, "f", Data([1])),
            entry(0x08, "é", Data([1]))
        )
        XCTAssertEqual(map.serialized(), expected)
        XCTAssertEqual(try KDBXVariantMap(serialized: expected), map)
    }

    func testSerializesBoolFalseAsZero() {
        let map: KDBXVariantMap = ["f": .bool(false)]
        XCTAssertEqual(map.serialized(), self.map(entry(0x08, "f", Data([0]))))
    }

    func testEmptyMapSerializesToVersionAndTerminator() {
        XCTAssertEqual(KDBXVariantMap().serialized(), Data([0x00, 0x01, 0x00]))
    }
}
