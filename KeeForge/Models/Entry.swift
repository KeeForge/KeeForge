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
    /// UUID referencing `Meta/CustomIcons`, when the entry uses a custom icon.
    /// Read-only display copy: the source `<CustomIconUUID>` element stays in
    /// `unknownXML` so the writer round-trips it verbatim.
    var customIconUUID: UUID?
    var tags: [String]
    /// Whether the source XML had a `<Tags>` element, even if empty. Writers
    /// use this to preserve an empty `<Tags></Tags>` that would otherwise be
    /// indistinguishable from "no tags at all".
    var hasTagsElement: Bool
    var customFields: [String: String]
    /// Passkey private key PEM (`KPEX_PASSKEY_PRIVATE_KEY_PEM`), diverted out
    /// of `customFields` at parse time and sealed with the per-session key so
    /// the plaintext PEM does not survive lock. The serializer re-emits it as
    /// a String field at its original (sorted) position among custom fields.
    var passkeyPrivateKey: EncryptedValue?
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
    /// KDBX `<Times>/<LocationChanged>`: when this entry last changed parent
    /// group. `nil` means the source had no such element, and the writer must
    /// not invent one. Set on every reparent (recycling is a move) so a merge
    /// can tell which side moved an object more recently.
    var locationChanged: Date?
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
        customIconUUID: UUID? = nil,
        tags: [String] = [],
        hasTagsElement: Bool = false,
        customFields: [String: String] = [:],
        passkeyPrivateKey: EncryptedValue? = nil,
        totpConfig: TOTPConfig? = nil,
        otpURL: String? = nil,
        creationTime: Date? = nil,
        lastModificationTime: Date? = nil,
        expires: Bool = false,
        expiryTime: Date? = nil,
        locationChanged: Date? = nil,
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
        self.customIconUUID = customIconUUID
        self.tags = tags
        self.hasTagsElement = hasTagsElement
        self.customFields = customFields
        self.passkeyPrivateKey = passkeyPrivateKey
        self.totpConfig = totpConfig
        self.otpURL = otpURL
        self.creationTime = creationTime
        self.lastModificationTime = lastModificationTime
        self.expires = expires
        self.expiryTime = expiryTime
        self.locationChanged = locationChanged
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

    /// Passkey credential parsed from KPEX_PASSKEY_* custom fields plus the
    /// diverted, session-key-sealed private key, if present.
    var passkeyCredential: PasskeyCredential? {
        PasskeyCredential(customFields: customFields, privateKey: passkeyPrivateKey)
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
        Self.systemIconName(for: iconID)
    }

    /// SF Symbol approximations for the KDBX standard icon set (PwIcon 0–68).
    /// Indices follow the KeePass 2.x `PwIcons` enum; unmapped IDs fall back
    /// to the caller-provided default.
    static let standardIconNames: [Int: String] = [
        0: "key.fill",                              // Key
        1: "globe",                                 // World
        2: "exclamationmark.triangle.fill",         // Warning
        3: "server.rack",                           // NetworkServer
        4: "pin.fill",                              // MarkedDirectory
        5: "bubble.left.and.bubble.right.fill",     // UserCommunication
        6: "gearshape.2.fill",                      // Parts
        7: "note.text",                             // Notepad
        8: "powerplug.fill",                        // WorldSocket
        9: "person.text.rectangle.fill",            // Identity
        10: "doc.text.fill",                        // PaperReady
        11: "camera.fill",                          // Digicam
        12: "antenna.radiowaves.left.and.right",    // IRCommunication
        13: "key.horizontal.fill",                  // MultiKeys
        14: "bolt.fill",                            // Energy
        15: "scanner.fill",                         // Scanner
        16: "globe.americas.fill",                  // WorldStar
        17: "opticaldisc.fill",                     // CDRom
        18: "display",                              // Monitor
        19: "envelope.fill",                        // EMail
        20: "gearshape.fill",                       // Configuration
        21: "list.clipboard.fill",                  // ClipboardReady
        22: "doc.badge.plus",                       // PaperNew
        23: "desktopcomputer",                      // Screen
        24: "bolt.circle.fill",                     // EnergyCareful
        25: "tray.full.fill",                       // EMailBox
        26: "internaldrive.fill",                   // Disk
        27: "externaldrive.fill",                   // Drive
        28: "play.rectangle.fill",                  // PaperQ
        29: "lock.fill",                            // TerminalEncrypted
        30: "terminal.fill",                        // Console
        31: "printer.fill",                         // Printer
        32: "square.grid.3x3.fill",                 // ProgramIcons
        33: "play.circle.fill",                     // Run
        34: "slider.horizontal.3",                  // Settings
        35: "network",                              // WorldComputer
        36: "archivebox.fill",                      // Archive
        37: "building.columns.fill",                // Homebanking
        38: "pc",                                   // DriveWindows
        39: "clock.fill",                           // Clock
        40: "mail.and.text.magnifyingglass",        // EMailSearch
        41: "flag.fill",                            // PaperFlag
        42: "memorychip.fill",                      // Memory
        43: "trash.fill",                           // TrashBin
        44: "square.and.pencil",                    // Note
        45: "xmark.circle.fill",                    // Expired
        46: "info.circle.fill",                     // Info
        47: "shippingbox.fill",                     // Package
        48: "folder.fill",                          // Folder
        49: "folder.fill",                          // FolderOpen
        50: "folder.fill.badge.gearshape",          // FolderPackage
        51: "lock.open.fill",                       // LockOpen
        52: "lock.doc.fill",                        // PaperLocked
        53: "checkmark.circle.fill",                // Checked
        54: "pencil",                               // Pen
        55: "photo.fill",                           // Thumbnail
        56: "book.fill",                            // Book
        57: "list.bullet",                          // List
        58: "person.badge.key.fill",                // UserKey
        59: "hammer.fill",                          // Tool
        60: "house.fill",                           // Home
        61: "star.fill",                            // Star
        62: "laptopcomputer",                       // Tux
        63: "signature",                            // Feather
        // Deliberately not `apple.logo`: SF Symbols' license excludes the
        // symbols depicting Apple's own trademarks and logos.
        64: "laptopcomputer",                       // Apple
        65: "text.book.closed.fill",                // Wiki
        66: "banknote.fill",                        // Money
        67: "rosette",                              // Certificate
        68: "iphone",                               // BlackBerry
    ]

    static func systemIconName(for iconID: Int, fallback: String = "key.fill") -> String {
        standardIconNames[iconID] ?? fallback
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
