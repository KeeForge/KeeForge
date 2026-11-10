import CryptoKit
import Foundation
import KDBXKit
import OneTimeCodes

/// The package's algorithm under the name the model and its parser use.
typealias TOTPAlgorithm = OneTimeCodes.TOTPAlgorithm

/// The app's entry point to `OneTimeCodes` for a sealed `TOTPConfig`: it
/// decrypts the secret under the session key, and owns the placeholder shown
/// when a secret does not resolve.
enum TOTPGenerator {
    /// Shown in place of a code when the secret is missing or does not decode.
    static let placeholderCode = "------"

    static func generateCode(config: TOTPConfig, sessionKey: SymmetricKey, date: Date = Date()) -> String {
        code(for: parameters(for: config, sessionKey: sessionKey), at: date)
    }

    static func code(for parameters: TOTPParameters?, at date: Date = Date()) -> String {
        parameters.map { TOTP.code(for: $0, at: date) } ?? placeholderCode
    }

    /// The config's secret and timing, decrypted. `decodedSecret` wins over the
    /// Base32 `secret` when present. Nil when the secret is empty or does not
    /// decrypt or decode.
    static func parameters(for config: TOTPConfig, sessionKey: SymmetricKey) -> TOTPParameters? {
        // Bound straight to the `var`, so the wipe reaches the only copy.
        guard var secret = secretBytes(of: config, sessionKey: sessionKey) else { return nil }
        defer { SecureWipe.wipe(&secret) }
        return TOTPParameters(
            secret: secret,
            period: config.period,
            digits: config.digits,
            algorithm: config.algorithm
        )
    }

    private static func secretBytes(of config: TOTPConfig, sessionKey: SymmetricKey) -> Data? {
        if let decodedSecret = config.decodedSecret {
            return try? decodedSecret.decryptData(using: sessionKey)
        }
        return (try? config.secret.decrypt(using: sessionKey)).flatMap(Base32.decode)
    }

    /// Kept for `KDBXParser`, which does not import the package.
    static func base32Decode(_ input: String) -> Data? {
        Base32.decode(input)
    }
}
