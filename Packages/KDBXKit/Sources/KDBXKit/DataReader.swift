import Foundation

/// Little-endian cursor over the binary header and block structures. `data`
/// must be zero-based (not a slice).
struct DataReader {
    let data: Data
    var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var hasMore: Bool { offset < data.count }

    mutating func readUInt8() throws -> UInt8 {
        try readBytes(1)[0]
    }

    mutating func readUInt16() throws -> UInt16 {
        try readInteger()
    }

    mutating func readUInt32() throws -> UInt32 {
        try readInteger()
    }

    mutating func readInt32() throws -> Int32 {
        try readInteger()
    }

    /// A header field value read as a little-endian integer. Longer fields are
    /// accepted and read from their first bytes, as KeePass does.
    mutating func readInteger<T: FixedWidthInteger>(fieldSize: Int) throws -> T {
        let bytes = try readBytes(fieldSize)
        guard bytes.count >= MemoryLayout<T>.size else { throw KDBXContainer.ParseError.truncatedFile }
        return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw KDBXContainer.ParseError.truncatedFile
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func skip(_ count: Int) throws {
        _ = try readBytes(count)
    }

    private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let bytes = try readBytes(MemoryLayout<T>.size)
        return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }
}

extension Data {
    init<T: FixedWidthInteger>(littleEndian value: T) {
        var littleEndian = value.littleEndian
        self = Swift.withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        append(Data(littleEndian: value))
    }
}
