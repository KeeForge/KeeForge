import Foundation

/// Represents a single KeePass entry (password record)
struct KPEntry: Identifiable, Sendable {
    var id: UUID
    var title: String
    var username: String
    var password: EncryptedValue
    var url: String
    var notes: String
    var iconID: Int
    var tags: [String]
    /// Whether the source XML had a `<Tags>` element, even if empty. Writers
    /// use this to preserve an empty `<Tags></Tags>` that would otherwise be
    /// indistinguishable from "no tags at all".
    var hasTagsElement: Bool
    var customFields: [String: String]
    /// Raw TOTP config: either otpauth:// URI or key/settings
    var totpConfig: TOTPConfig?
    /// Original `otp` key value (an `otpauth://` URI) if the source used the
    /// KeeWeb/legacy format. When present, the writer emits the original URI
    /// verbatim instead of decomposing into `TimeOtp-*` fields, which would
    /// drop the issuer/label and any custom query parameters.
    var otpURL: String?
    var creationTime: Date?
    var lastModificationTime: Date?
    var unknownXML: OpaqueXMLNodes
    var protectedStringKeys: Set<String>

    /// Whether the entry has a non-empty password (without decrypting).
    var hasPassword: Bool { password.hasValue }

    init(
        id: UUID = UUID(),
        title: String = "",
        username: String = "",
        password: EncryptedValue = .empty,
        url: String = "",
        notes: String = "",
        iconID: Int = 0,
        tags: [String] = [],
        hasTagsElement: Bool = false,
        customFields: [String: String] = [:],
        totpConfig: TOTPConfig? = nil,
        otpURL: String? = nil,
        creationTime: Date? = nil,
        lastModificationTime: Date? = nil,
        unknownXML: OpaqueXMLNodes = .empty,
        protectedStringKeys: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.iconID = iconID
        self.tags = tags
        self.hasTagsElement = hasTagsElement
        self.customFields = customFields
        self.totpConfig = totpConfig
        self.otpURL = otpURL
        self.creationTime = creationTime
        self.lastModificationTime = lastModificationTime
        self.unknownXML = unknownXML
        self.protectedStringKeys = protectedStringKeys
    }

    /// Additional URLs from KeePass2Android KP2A_URL_* custom fields, sorted by key
    var additionalURLs: [String] {
        customFields.filter { $0.key.hasPrefix("KP2A_URL_") }
            .sorted { $0.key < $1.key }
            .map(\.value)
            .filter { !$0.isEmpty }
    }

    /// Passkey credential parsed from KPEX_PASSKEY_* custom fields, if present.
    var passkeyCredential: PasskeyCredential? {
        PasskeyCredential(customFields: customFields)
    }

    /// Whether this entry has a TOTP configuration.
    var hasTOTP: Bool { totpConfig != nil }

    /// Whether this entry contains a passkey credential.
    var hasPasskey: Bool { passkeyCredential != nil }

    /// Custom fields excluding internal KPEX passkey fields (for display purposes).
    var displayCustomFields: [String: String] {
        customFields.filter { !PasskeyCredential.allFieldKeys.contains($0.key) }
    }

    /// System icon name based on KeePass icon ID
    var systemIconName: String {
        switch iconID {
        case 0: "key.fill"
        case 1: "globe"
        case 62: "creditcard.fill"
        case 68: "at"
        default: "key.fill"
        }
    }
}

/// TOTP configuration extracted from KeePass entry
struct TOTPConfig: Sendable {
    let secret: EncryptedValue
    let period: Int
    let digits: Int
    let algorithm: TOTPAlgorithm

    init(secret: EncryptedValue, period: Int = 30, digits: Int = 6, algorithm: TOTPAlgorithm = .sha1) {
        self.secret = secret
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
    }
}

enum TOTPAlgorithm: String, Codable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}
