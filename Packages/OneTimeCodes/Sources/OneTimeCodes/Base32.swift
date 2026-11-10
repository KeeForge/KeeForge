import Foundation

/// RFC 4648 Base32 with the standard alphabet, as authenticator secrets use it.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// Decodes leniently, the way users paste secrets: either case, and spaces,
    /// tabs, line breaks, and `=` anywhere are skipped. Nil on any other
    /// character. Trailing bits that do not fill a byte are dropped.
    public static func decode(_ input: String) -> Data? {
        // Sized up front so appends never reallocate and leave a stray copy of a secret.
        var bytes = Data(capacity: input.utf8.count * 5 / 8 + 1)
        var accumulator: UInt32 = 0
        var bitCount = 0

        for scalar in input.unicodeScalars {
            let value: UInt32
            switch scalar.value {
            case 65...90: value = scalar.value - 65 // A-Z
            case 97...122: value = scalar.value - 97 // a-z
            case 50...55: value = scalar.value - 24 // 2-7
            case 32, 9, 10, 13, 61: continue // whitespace and "="
            default: return nil
            }

            accumulator = (accumulator << 5) | value
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((accumulator >> UInt32(bitCount)) & 0xFF))
                accumulator &= (1 << UInt32(bitCount)) - 1
            }
        }
        return bytes
    }

    /// Unpadded uppercase Base32.
    public static func encode(_ bytes: some ContiguousBytes) -> String {
        bytes.withUnsafeBytes { buffer in
            var result: [UInt8] = []
            result.reserveCapacity((buffer.count * 8 + 4) / 5)
            var accumulator = 0
            var bitCount = 0
            for byte in buffer {
                accumulator = (accumulator << 8) | Int(byte)
                bitCount += 8
                while bitCount >= 5 {
                    bitCount -= 5
                    result.append(alphabet[(accumulator >> bitCount) & 31])
                    accumulator &= (1 << bitCount) - 1
                }
            }
            if bitCount > 0 {
                result.append(alphabet[(accumulator << (5 - bitCount)) & 31])
            }
            return String(decoding: result, as: UTF8.self)
        }
    }

    /// `value` uppercased, when that is already canonical unpadded Base32: a
    /// non-empty secret that survives decode and encode unchanged, so no
    /// padding, whitespace, or set trailing bits. Nil otherwise.
    public static func canonicalSecret(_ value: String) -> String? {
        let normalized = value.uppercased()
        guard !normalized.isEmpty,
              normalized.utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) }),
              let decoded = decode(normalized), !decoded.isEmpty,
              encode(decoded) == normalized else { return nil }
        return normalized
    }
}
