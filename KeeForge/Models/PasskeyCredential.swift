import Foundation

/// Represents a passkey (FIDO2/WebAuthn) credential stored in a KDBX entry,
/// following the KeePassXC custom field naming convention.
struct PasskeyCredential: Sendable {
    /// Base64URL-encoded credential ID
    let credentialID: String
    /// ECDSA P-256 private key in PEM format
    let privateKeyPEM: String
    /// Relying party identifier (e.g. "google.com")
    let relyingParty: String
    /// Username associated with the passkey
    let username: String
    /// Base64URL-encoded user handle from the server
    let userHandle: String

    /// Raw credential ID bytes, decoded from Base64URL.
    var credentialIDData: Data? {
        base64URLDecode(credentialID)
    }

    /// Raw user handle bytes, decoded from Base64URL.
    var userHandleData: Data? {
        base64URLDecode(userHandle)
    }
}

// MARK: - KPEX field keys

extension PasskeyCredential {
    static let credentialIDKey = "KPEX_PASSKEY_CREDENTIAL_ID"
    static let privateKeyPEMKey = "KPEX_PASSKEY_PRIVATE_KEY_PEM"
    static let relyingPartyKey = "KPEX_PASSKEY_RELYING_PARTY"
    static let usernameKey = "KPEX_PASSKEY_USERNAME"
    static let userHandleKey = "KPEX_PASSKEY_USER_HANDLE"

    /// Legacy field name used by Strongbox / older KeePassXC as the credential ID.
    static let legacyCredentialIDKey = "KPEX_PASSKEY_GENERATED_USER_ID"
    /// Legacy KPXC-prefixed username field written by older KeePassXC builds.
    static let legacyUsernameKey = "KPXC_PASSKEY_USERNAME"

    /// All passkey field keys (current and legacy), used to filter them from
    /// the generic custom fields display.
    static let allFieldKeys: Set<String> = [
        credentialIDKey, privateKeyPEMKey, relyingPartyKey, usernameKey, userHandleKey,
        legacyCredentialIDKey, legacyUsernameKey,
    ]

    /// Attempt to parse a passkey credential from an entry's custom fields.
    /// Returns nil if any required field is missing or empty.
    ///
    /// For compatibility with passkeys written by Strongbox and older KeePassXC
    /// builds, the credential ID and username fall back to legacy field names when
    /// the current KPEX keys are absent.
    init?(customFields: [String: String]) {
        guard let credentialID = Self.nonEmptyValue(in: customFields,
                                                    keys: Self.credentialIDKey, Self.legacyCredentialIDKey),
              let privateKeyPEM = customFields[Self.privateKeyPEMKey], !privateKeyPEM.isEmpty,
              let relyingParty = customFields[Self.relyingPartyKey], !relyingParty.isEmpty,
              let username = Self.nonEmptyValue(in: customFields,
                                                keys: Self.usernameKey, Self.legacyUsernameKey),
              let userHandle = customFields[Self.userHandleKey], !userHandle.isEmpty
        else {
            return nil
        }

        self.credentialID = credentialID
        self.privateKeyPEM = privateKeyPEM
        self.relyingParty = relyingParty
        self.username = username
        self.userHandle = userHandle
    }

    /// Return the first non-empty value found for the given keys, in order.
    private static func nonEmptyValue(in customFields: [String: String], keys: String...) -> String? {
        for key in keys {
            if let value = customFields[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - Base64URL

/// Decode a Base64URL-encoded string (RFC 4648 §5) to Data.
func base64URLDecode(_ string: String) -> Data? {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    // Pad to multiple of 4
    let remainder = base64.count % 4
    if remainder != 0 {
        base64.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: base64)
}

/// Encode Data as a Base64URL string (no padding).
func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
