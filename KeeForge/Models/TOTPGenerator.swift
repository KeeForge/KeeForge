import Foundation
import CryptoKit

/// Generates TOTP codes per RFC 6238
enum TOTPGenerator {
    struct ResolvedSecret: Sendable {
        let data: Data
        let key: SymmetricKey
    }

    /// Generate a TOTP code for the given config at the current time
    static func generateCode(config: TOTPConfig, sessionKey: SymmetricKey, date: Date = Date()) -> String {
        generateCode(config: config, resolvedSecret: resolveSecret(config: config, sessionKey: sessionKey), date: date)
    }

    static func resolveSecret(config: TOTPConfig, sessionKey: SymmetricKey) -> ResolvedSecret? {
        let secretData: Data?
        if let decodedSecret = config.decodedSecret {
            secretData = try? decodedSecret.decryptData(using: sessionKey)
        } else if let secretString = try? config.secret.decrypt(using: sessionKey) {
            secretData = base32Decode(secretString)
        } else {
            secretData = nil
        }
        guard let secretData, !secretData.isEmpty else { return nil }
        return ResolvedSecret(data: secretData, key: SymmetricKey(data: secretData))
    }

    static func generateCode(config: TOTPConfig, resolvedSecret: ResolvedSecret?, date: Date = Date()) -> String {
        guard let resolvedSecret else { return "------" }

        // Parsers sanitize file-supplied values, but configs can also arrive
        // from edit drafts: clamp so a rogue period can never divide by zero
        // (or trap converting a negative to UInt64) and a rogue digit count
        // can never overflow the 10^digits modulus below.
        let period = UInt64(max(1, config.period))
        let digits = min(max(config.digits, 1), 9)

        let timeInterval = UInt64(date.timeIntervalSince1970)
        let counter = timeInterval / period

        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: 8)

        let hmac: Data
        switch config.algorithm {
        case .sha1:
            var h = HMAC<Insecure.SHA1>.init(key: resolvedSecret.key)
            h.update(data: counterData)
            hmac = Data(h.finalize())
        case .sha256:
            hmac = Data(HMAC<SHA256>.authenticationCode(for: counterData, using: resolvedSecret.key))
        case .sha512:
            hmac = Data(HMAC<SHA512>.authenticationCode(for: counterData, using: resolvedSecret.key))
        }

        let offset = Int(hmac[hmac.count - 1] & 0x0F)
        let truncated = hmac.withUnsafeBytes { ptr -> UInt32 in
            let slice = ptr.baseAddress!.advanced(by: offset)
            return slice.loadUnaligned(as: UInt32.self).bigEndian & 0x7FFF_FFFF
        }

        let modulus = UInt32(pow(10.0, Double(digits)))
        let code = truncated % modulus
        return String(format: "%0\(digits)d", code)
    }

    /// Seconds remaining in current TOTP period
    static func secondsRemaining(period: Int, date: Date = Date()) -> Int {
        let period = max(1, period)
        let elapsed = Int(date.timeIntervalSince1970) % period
        return period - elapsed
    }

    // MARK: - Base32 Decoding

    static func base32Decode(_ input: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.count * 5 / 8)

        var accumulator: UInt32 = 0
        var bitCount = 0

        for scalar in input.unicodeScalars {
            let value: UInt32
            switch scalar.value {
            case 65...90: // A-Z
                value = scalar.value - 65
            case 97...122: // a-z
                value = scalar.value - 97
            case 50...55: // 2-7
                value = scalar.value - 24
            case 32, 9, 10, 13, 61: // whitespace and "="
                continue
            default:
                return nil
            }

            accumulator = (accumulator << 5) | value
            bitCount += 5

            while bitCount >= 8 {
                bitCount -= 8
                let byte = UInt8((accumulator >> UInt32(bitCount)) & 0xFF)
                bytes.append(byte)
                accumulator &= (1 << UInt32(bitCount)) - 1
            }
        }

        return Data(bytes)
    }

    // MARK: - Base32 Encoding

    /// Unpadded uppercase RFC 4648 Base32.
    static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var result: [UInt8] = []
        var accumulator = 0
        var bitCount = 0
        for byte in data {
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

    /// Uppercases `value` and returns it only when it is already canonical
    /// unpadded Base32 (round-trips through decode/encode unchanged).
    static func canonicalBase32Secret(_ value: String) -> String? {
        let normalized = value.uppercased()
        guard !normalized.isEmpty,
              normalized.utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) }),
              let decoded = base32Decode(normalized), !decoded.isEmpty,
              base32Encode(decoded) == normalized else { return nil }
        return normalized
    }
}
