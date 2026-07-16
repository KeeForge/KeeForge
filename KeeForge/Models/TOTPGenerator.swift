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

        let timeInterval = UInt64(date.timeIntervalSince1970)
        let counter = timeInterval / UInt64(config.period)

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

        let modulus = UInt32(pow(10.0, Double(config.digits)))
        let code = truncated % modulus
        return String(format: "%0\(config.digits)d", code)
    }

    /// Seconds remaining in current TOTP period
    static func secondsRemaining(period: Int, date: Date = Date()) -> Int {
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
}
