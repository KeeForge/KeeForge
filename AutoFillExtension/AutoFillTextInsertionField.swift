import CryptoKit
import Foundation

/// A value the system text-insertion menu may hand to the focused field.
/// Deliberately closed: never a TOTP secret, `otpauth:` URI, passkey, note or
/// custom field.
enum AutoFillTextInsertionField: CaseIterable, Hashable, Sendable {
    case username
    case password
    case verificationCode

    var title: String {
        switch self {
        case .username: String(localized: "Username")
        case .password: String(localized: "Password")
        case .verificationCode: String(localized: "Verification Code")
        }
    }

    /// The fields worth offering for `entry`, in display order. Reads presence
    /// flags only; nothing is decrypted until the user picks one.
    static func availableFields(for entry: KPEntry) -> [Self] {
        allCases.filter { $0.isAvailable(for: entry) }
    }

    func isAvailable(for entry: KPEntry) -> Bool {
        switch self {
        case .username: !entry.username.isEmpty
        case .password: entry.password.hasValue
        case .verificationCode: entry.hasTOTP
        }
    }

    /// The plaintext to insert, or nil when there is nothing usable. The code
    /// is generated here, at selection, so a code shown earlier never goes out
    /// stale. `{REF:…}` resolves with `.protectedValues` because this runs only
    /// after AutoFill's own unlock, as a password fill does.
    func text(for entry: KPEntry, allEntries: [KPEntry], sessionKey: SymmetricKey, date: Date = Date()) -> String? {
        guard isAvailable(for: entry) else { return nil }
        let resolver = FieldReferenceResolver(entries: allEntries, sessionKey: sessionKey)
        let value: String?
        switch self {
        case .username:
            value = resolver.resolve(entry.username, clearance: .protectedValues).value
        case .password:
            guard let password = try? entry.password.decrypt(using: sessionKey) else { return nil }
            value = resolver.resolve(password, clearance: .protectedValues).value
        case .verificationCode:
            guard let config = entry.totpConfig else { return nil }
            let code = TOTPGenerator.generateCode(config: config, sessionKey: sessionKey, date: date)
            value = code == TOTPGenerator.placeholderCode ? nil : code
        }
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
