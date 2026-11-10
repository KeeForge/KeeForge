import CryptoKit
import Foundation

/// A secret with the timing a TOTP code is generated under.
///
/// Values are clamped rather than rejected, so a code is always defined: the
/// period to at least 1 second, the digits to 1...9 (10^9 still fits the
/// 31-bit truncated value's modulus).
public struct TOTPParameters: Sendable {
    public let secret: SymmetricKey
    public let period: Int
    public let digits: Int
    public let algorithm: TOTPAlgorithm

    /// Nil for an empty secret. The bytes are copied into `secret`, so the
    /// caller can wipe its buffer afterwards.
    public init?(secret: some ContiguousBytes, period: Int = 30, digits: Int = 6, algorithm: TOTPAlgorithm = .sha1) {
        let key = SymmetricKey(data: secret)
        guard key.bitCount > 0 else { return nil }
        self.secret = key
        self.period = max(1, period)
        self.digits = min(max(digits, 1), 9)
        self.algorithm = algorithm
    }
}

/// Time-based one-time codes (RFC 6238).
public enum TOTP {
    /// The zero-padded code for the time step containing `date`. Dates before
    /// 1970 count as step 0.
    public static func code(for parameters: TOTPParameters, at date: Date) -> String {
        let seconds = UInt64(max(0, date.timeIntervalSince1970))
        return HOTP.code(
            key: parameters.secret,
            counter: seconds / UInt64(parameters.period),
            digits: parameters.digits,
            algorithm: parameters.algorithm
        )
    }

    /// Seconds until the time step containing `date` ends, from `period`
    /// (a full step at a boundary) down to 1. A period below 1 counts as 1.
    public static func secondsRemaining(period: Int, at date: Date) -> Int {
        let period = max(1, period)
        return period - Int(date.timeIntervalSince1970) % period
    }
}

/// Counter-based one-time codes (RFC 4226), the core TOTP runs on.
enum HOTP {
    private static let powersOfTen: [UInt32] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]

    /// `digits` must be in 1...9; `TOTPParameters` guarantees it.
    static func code(key: SymmetricKey, counter: UInt64, digits: Int, algorithm: TOTPAlgorithm) -> String {
        let value = truncatedValue(key: key, counter: counter, algorithm: algorithm) % powersOfTen[digits]
        let text = String(value)
        return String(repeating: "0", count: digits - text.count) + text
    }

    /// RFC 4226 section 5.3 dynamic truncation: 31 bits at the offset the
    /// last byte's low nibble names.
    static func truncatedValue(key: SymmetricKey, counter: UInt64, algorithm: TOTPAlgorithm) -> UInt32 {
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        switch algorithm {
        case .sha1: return truncate(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: return truncate(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: return truncate(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
    }

    private static func truncate(_ mac: some MessageAuthenticationCode) -> UInt32 {
        mac.withUnsafeBytes { bytes in
            let offset = Int(bytes[bytes.count - 1] & 0x0F)
            return (UInt32(bytes[offset]) & 0x7F) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }
}
