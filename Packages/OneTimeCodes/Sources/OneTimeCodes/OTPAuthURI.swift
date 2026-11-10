import Foundation

public enum OTPAuthURIError: Error, Equatable, Sendable {
    case notAnOTPAuthURI
    case unsupportedType
    case missingOrInvalidSecret
    case invalidParameter
}

/// A parsed `otpauth://totp/...` enrollment URI. `rawURI` keeps the trimmed
/// input for storage in the KeePassXC-compatible `otp` field — byte-verbatim
/// except the scheme and host, which are lowercased (QR alphanumeric mode
/// encodes uppercase, and KeePass-family readers compare the prefix
/// case-sensitively) — while the typed fields describe the code.
///
/// Strict: only `totp`, no Steam encoder, a Base32 secret that decodes to at
/// least one byte, digits 1...9, and a positive period. Unknown parameters are
/// ignored.
public struct OTPAuthURI: Sendable, Equatable {
    /// Whether an incoming URL claims the `otpauth` scheme — the routing
    /// check, deliberately separate from full parsing so the app can route
    /// first and report parse problems second.
    public static func isOTPAuthURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "otpauth"
    }

    public let rawURI: String
    /// Canonical unpadded uppercase RFC 4648 Base32.
    public let secret: String
    public let issuer: String?
    public let accountName: String?
    public let period: Int
    public let digits: Int
    public let algorithm: TOTPAlgorithm

    public init(string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "otpauth" else {
            throw OTPAuthURIError.notAnOTPAuthURI
        }
        guard components.host?.lowercased() == "totp" else {
            throw OTPAuthURIError.unsupportedType
        }

        // First occurrence wins on duplicate names;
        // `Dictionary(uniqueKeysWithValues:)` would trap.
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard params[name] == nil, let value = item.value else { continue }
            params[name] = value
        }

        if params["encoder"]?.lowercased() == "steam" {
            throw OTPAuthURIError.unsupportedType
        }

        guard let rawSecret = params["secret"],
              let decoded = Base32.decode(rawSecret),
              !decoded.isEmpty else {
            throw OTPAuthURIError.missingOrInvalidSecret
        }

        let algorithm: TOTPAlgorithm
        if let value = params["algorithm"] {
            guard let parsed = TOTPAlgorithm(rawValue: value.uppercased()) else {
                throw OTPAuthURIError.invalidParameter
            }
            algorithm = parsed
        } else {
            algorithm = .sha1
        }

        let digits: Int
        if let value = params["digits"] {
            guard let parsed = Int(value), (1...9).contains(parsed) else {
                throw OTPAuthURIError.invalidParameter
            }
            digits = parsed
        } else {
            digits = 6
        }

        let period: Int
        if let value = params["period"] {
            guard let parsed = Int(value), parsed > 0 else {
                throw OTPAuthURIError.invalidParameter
            }
            period = parsed
        } else {
            period = 30
        }

        // URLComponents.path is already percent-decoded.
        let label = components.path.hasPrefix("/")
            ? String(components.path.dropFirst())
            : components.path
        let labelIssuer: String?
        let labelAccount: String
        if let colon = label.firstIndex(of: ":") {
            labelIssuer = String(label[..<colon])
            labelAccount = String(label[label.index(after: colon)...])
        } else {
            labelIssuer = nil
            labelAccount = label
        }

        func nonEmptyTrimmed(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }

        self.rawURI = Self.lowercasingSchemeAndHost(trimmed)
        self.secret = Base32.encode(decoded)
        self.issuer = nonEmptyTrimmed(params["issuer"]) ?? nonEmptyTrimmed(labelIssuer)
        self.accountName = nonEmptyTrimmed(labelAccount)
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
    }

    /// Lowercases only the scheme and authority of `uri`; the label, query,
    /// and everything after stay byte-verbatim. The caller has parsed a scheme
    /// and a host, so `://` directly follows the scheme.
    private static func lowercasingSchemeAndHost(_ uri: String) -> String {
        let scheme = uri.prefix { $0 != ":" }
        let rest = uri.dropFirst(scheme.count + 3)
        let authority = rest.prefix { !"/?#".contains($0) }
        return (scheme + "://" + authority).lowercased() + rest.dropFirst(authority.count)
    }
}
