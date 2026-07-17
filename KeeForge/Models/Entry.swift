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
    /// KeePass only considers `expiryTime` active when this flag is true.
    var expires: Bool
    var expiryTime: Date?
    var history: [KPEntry]
    var unknownXML: OpaqueXMLNodes
    var protectedStringKeys: Set<String>
    /// Attachment references (`<Binary><Key>name</Key><Value Ref="N"/></Binary>`)
    /// resolved lazily against the inner-header `BinaryPool`. Dangling refs are
    /// tolerated and preserved verbatim.
    var attachments: [KPAttachment]

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
        expires: Bool = false,
        expiryTime: Date? = nil,
        history: [KPEntry] = [],
        unknownXML: OpaqueXMLNodes = .empty,
        protectedStringKeys: Set<String> = [],
        attachments: [KPAttachment] = []
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
        self.expires = expires
        self.expiryTime = expiryTime
        self.history = history
        self.unknownXML = unknownXML
        self.protectedStringKeys = protectedStringKeys
        self.attachments = attachments
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

    /// The expiry time when expiration is enabled for this entry.
    var enabledExpiryTime: Date? {
        expires ? expiryTime : nil
    }

    /// Whether the entry's enabled expiry time has passed.
    func isExpired(at date: Date = .now) -> Bool {
        enabledExpiryTime.map { $0 <= date } == true
    }

    /// Whether this entry contains a passkey credential.
    var hasPasskey: Bool { passkeyCredential != nil }

    /// Custom fields excluding internal KPEX passkey fields (for display purposes).
    var displayCustomFields: [String: String] {
        customFields.filter {
            !PasskeyCredential.allFieldKeys.contains($0.key) && $0.key != totpConfig?.keeOTPSource?.fieldName
        }
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

    func cloneForHistory() -> KPEntry {
        var clone = self
        clone.history = []
        return clone
    }
}

/// TOTP configuration extracted from KeePass entry
struct TOTPConfig: Sendable {
    let secret: EncryptedValue
    /// Pre-decoded secret bytes for formats whose declared encoding is not Base32.
    let decodedSecret: EncryptedValue?
    let keeOTPSource: KeeOTPSource?
    let period: Int
    let digits: Int
    let algorithm: TOTPAlgorithm

    init(
        secret: EncryptedValue,
        decodedSecret: EncryptedValue? = nil,
        keeOTPSource: KeeOTPSource? = nil,
        period: Int = 30,
        digits: Int = 6,
        algorithm: TOTPAlgorithm = .sha1
    ) {
        self.secret = secret
        self.decodedSecret = decodedSecret
        self.keeOTPSource = keeOTPSource
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
    }
}

struct KeeOTPSource: Codable, Equatable, Sendable {
    let fieldName: String
    let rawQuery: String

    func rewriting(secret: String? = nil, period: Int, digits: Int, algorithm: TOTPAlgorithm) -> KeeOTPSource {
        let replacements: [String: String?] = [
            "key": secret,
            "encoding": secret == nil ? nil : "Base32",
            "step": String(period),
            "size": String(digits),
            "otphashmode": algorithm.rawValue,
        ]
        var pendingNames = Set(replacements.keys)
        var components = rawQuery.split(separator: "&", omittingEmptySubsequences: false).map { component -> String in
            let parts = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let decodedName = String(parts[0]).removingPercentEncoding else {
                return String(component)
            }
            let name = decodedName.lowercased()
            guard pendingNames.contains(name) else { return String(component) }
            pendingNames.remove(name)
            guard let replacement = replacements[name] ?? nil else { return String(component) }
            return "\(parts[0])=\(replacement)"
        }
        // KeeOtp2 omits default-valued parameters, so a rewritten value may
        // have no component to replace; append it under its canonical name.
        for name in ["key", "encoding", "step", "size", "otphashmode"] where pendingNames.contains(name) {
            guard let value = replacements[name] ?? nil else { continue }
            components.append("\(name == "otphashmode" ? "otpHashMode" : name)=\(value)")
        }
        return KeeOTPSource(fieldName: fieldName, rawQuery: components.joined(separator: "&"))
    }
}

enum TOTPAlgorithm: String, Codable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}
