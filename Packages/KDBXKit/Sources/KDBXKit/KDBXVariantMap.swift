import Foundation

/// KeePass's typed key-value dictionary, as stored in the KDBX 4 outer header
/// (the KDF parameters).
///
/// Every entry round-trips exactly: a value of a type this version does not
/// know, or a string that is not valid UTF-8, is kept as `.unknown` with its
/// original type byte and bytes.
public struct KDBXVariantMap: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case uint32(UInt32)
        case uint64(UInt64)
        case bool(Bool)
        case int32(Int32)
        case int64(Int64)
        case string(String)
        case bytes(Data)
        case unknown(type: UInt8, data: Data)
    }

    public var entries: [String: Value]

    public init(_ entries: [String: Value] = [:]) {
        self.entries = entries
    }

    public subscript(key: String) -> Value? {
        get { entries[key] }
        set { entries[key] = newValue }
    }

    /// The value for `key` if it is stored as a `UInt32`.
    public func uint32(_ key: String) -> UInt32? {
        guard case .uint32(let value) = entries[key] else { return nil }
        return value
    }

    /// The value for `key` if it is stored as a `UInt64`.
    public func uint64(_ key: String) -> UInt64? {
        guard case .uint64(let value) = entries[key] else { return nil }
        return value
    }

    /// The value for `key` if it is stored as a byte array.
    public func bytes(_ key: String) -> Data? {
        guard case .bytes(let value) = entries[key] else { return nil }
        return value
    }
}

extension KDBXVariantMap: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Value)...) {
        self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Serialization

extension KDBXVariantMap {
    private static let version: UInt16 = 0x0100
    private static let criticalVersionMask: UInt16 = 0xFF00

    private enum TypeCode {
        static let end: UInt8 = 0x00
        static let uint32: UInt8 = 0x04
        static let uint64: UInt8 = 0x05
        static let bool: UInt8 = 0x08
        static let int32: UInt8 = 0x0C
        static let int64: UInt8 = 0x0D
        static let string: UInt8 = 0x18
        static let bytes: UInt8 = 0x42
    }

    /// Parses a serialized map. Rejects a newer major version, as KeePass does,
    /// and fixed-width values of the wrong length.
    init(serialized data: Data) throws {
        var reader = DataReader(data: data)
        let version = try reader.readUInt16()
        guard version & Self.criticalVersionMask <= Self.version & Self.criticalVersionMask else {
            throw KDBXContainer.ParseError.malformedVariantMap
        }

        var entries: [String: Value] = [:]
        while reader.hasMore {
            let type = try reader.readUInt8()
            if type == TypeCode.end { break }

            let keyLength = Int(try reader.readUInt32())
            guard let key = String(data: try reader.readBytes(keyLength), encoding: .utf8) else {
                throw KDBXContainer.ParseError.malformedVariantMap
            }
            let valueLength = Int(try reader.readUInt32())
            let valueData = try reader.readBytes(valueLength)
            entries[key] = try Self.decode(type: type, data: valueData)
        }
        self.entries = entries
    }

    private static func decode(type: UInt8, data: Data) throws -> Value {
        func fixedWidth<T: FixedWidthInteger>(_: T.Type) throws -> T {
            guard data.count == MemoryLayout<T>.size else { throw KDBXContainer.ParseError.malformedVariantMap }
            return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }

        switch type {
        case TypeCode.uint32:
            return .uint32(try fixedWidth(UInt32.self))
        case TypeCode.uint64:
            return .uint64(try fixedWidth(UInt64.self))
        case TypeCode.bool:
            guard let first = data.first else { throw KDBXContainer.ParseError.malformedVariantMap }
            return .bool(first != 0)
        case TypeCode.int32:
            return .int32(try fixedWidth(Int32.self))
        case TypeCode.int64:
            return .int64(try fixedWidth(Int64.self))
        case TypeCode.string:
            guard let string = String(data: data, encoding: .utf8) else {
                return .unknown(type: type, data: data)
            }
            return .string(string)
        case TypeCode.bytes:
            return .bytes(data)
        default:
            return .unknown(type: type, data: data)
        }
    }

    /// Serializes with keys in byte order, so equal maps produce equal bytes.
    func serialized() -> Data {
        var data = Data()
        data.appendLittleEndian(Self.version)

        for (key, value) in entries.sorted(by: { Data($0.key.utf8).lexicographicallyPrecedes(Data($1.key.utf8)) }) {
            let (type, valueData) = Self.encode(value)
            let keyData = Data(key.utf8)
            data.append(type)
            data.appendLittleEndian(UInt32(keyData.count))
            data.append(keyData)
            data.appendLittleEndian(UInt32(valueData.count))
            data.append(valueData)
        }

        data.append(TypeCode.end)
        return data
    }

    private static func encode(_ value: Value) -> (UInt8, Data) {
        switch value {
        case .uint32(let value): (TypeCode.uint32, Data(littleEndian: value))
        case .uint64(let value): (TypeCode.uint64, Data(littleEndian: value))
        case .bool(let value): (TypeCode.bool, Data([value ? 1 : 0]))
        case .int32(let value): (TypeCode.int32, Data(littleEndian: value))
        case .int64(let value): (TypeCode.int64, Data(littleEndian: value))
        case .string(let value): (TypeCode.string, Data(value.utf8))
        case .bytes(let value): (TypeCode.bytes, value)
        case .unknown(let type, let data): (type, data)
        }
    }
}
