import Foundation

enum OTPAuthURIError: Error, Equatable {
    case notAnOTPAuthURI
    case unsupportedType
    case missingOrInvalidSecret
    case invalidParameter
}

/// A parsed `otpauth://totp/...` enrollment URI. `rawURI` keeps the trimmed
/// input for storage in the KeePassXC-compatible `otp` field — byte-verbatim
/// except the scheme and host, which are lowercased (QR alphanumeric mode
/// encodes uppercase, and KeePass-family readers compare the prefix
/// case-sensitively) — while the typed fields drive the editor's TOTP form.
struct OTPAuthURI: Sendable, Equatable {
    /// Whether an incoming URL claims the `otpauth` scheme — the routing
    /// check, deliberately separate from full parsing so the app can route
    /// first and report parse problems second.
    static func isOTPAuthURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "otpauth"
    }

    let rawURI: String
    /// Canonical unpadded uppercase RFC 4648 Base32.
    let secret: String
    let issuer: String?
    let accountName: String?
    let period: Int
    let digits: Int
    let algorithm: TOTPAlgorithm

    init(string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "otpauth" else {
            throw OTPAuthURIError.notAnOTPAuthURI
        }
        guard components.host?.lowercased() == "totp" else {
            throw OTPAuthURIError.unsupportedType
        }

        // First occurrence wins on duplicate names, matching the parser's
        // otpauth handling; `Dictionary(uniqueKeysWithValues:)` would trap.
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
              let decoded = TOTPGenerator.base32Decode(rawSecret),
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
        self.secret = TOTPGenerator.base32Encode(decoded)
        self.issuer = nonEmptyTrimmed(params["issuer"]) ?? nonEmptyTrimmed(labelIssuer)
        self.accountName = nonEmptyTrimmed(labelAccount)
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
    }

    /// Lowercases only the scheme and host of `uri`; the label, query, and
    /// everything after the host stay byte-verbatim. The caller has already
    /// validated the scheme and host, so `://` is guaranteed present.
    private static func lowercasingSchemeAndHost(_ uri: String) -> String {
        guard let separator = uri.range(of: "://") else { return uri }
        let afterSeparator = uri[separator.upperBound...]
        let hostEnd = afterSeparator.firstIndex(where: { "/?#".contains($0) }) ?? afterSeparator.endIndex
        let prefix = uri[..<hostEnd].lowercased()
        return prefix + uri[hostEnd...]
    }
}
