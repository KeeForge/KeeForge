import CryptoKit
import Foundation
import KDBXKit
import KDBXXML

/// Opens a KDBX file into KeeForge's model: `KDBXContainer` decrypts it,
/// `KDBXDocument` reads the XML, and this maps the document onto groups,
/// entries, and metadata. The mapping is where KeeForge's reading of the
/// format lives: which strings are standard fields, TOTP and passkey fields,
/// and sealing secrets under the session key.
enum KDBXParser {
    struct Opened {
        let rootGroup: KPGroup
        let meta: KPMeta
        let header: KDBXContainer.Header
    }

    static func parse(
        data: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Opened {
        try open(KDBXContainer.read(data: data, compositeKey: compositeKey, kdfPolicy: kdfPolicy), sessionKey: sessionKey)
    }

    /// Parses a file with the KDF output supplied by `transformedKey`, which
    /// receives the header's KDF parameters. A KDBX 4 key that does not
    /// belong to the file fails the header HMAC (`CryptoError.hmacMismatch`).
    static func parse(
        data: Data,
        sessionKey: SymmetricKey,
        transformedKey provideTransformedKey: (_ kdfParameters: KDBXVariantMap) throws -> Data
    ) throws -> Opened {
        try open(KDBXContainer.read(data: data, transformedKey: provideTransformedKey), sessionKey: sessionKey)
    }

    private static func open(_ payload: KDBXContainer.Payload, sessionKey: SymmetricKey) throws -> Opened {
        let document = try KDBXDocument.read(
            xml: payload.xml,
            innerStreamID: payload.header.innerStreamID,
            innerStreamKey: payload.header.innerStreamKey
        )
        let model = model(from: document, sessionKey: sessionKey)
        return Opened(rootGroup: model.rootGroup, meta: model.meta, header: payload.header)
    }

    /// The model for a document. The root group is synthetic: it holds
    /// `<Root>`'s own children and fragments under the all-zero UUID.
    static func model(from document: KDBXDocument, sessionKey: SymmetricKey) -> (rootGroup: KPGroup, meta: KPMeta) {
        let source = document.meta
        let recycleBinUUID = source.recycleBinUUID.flatMap { $0 == nullUUID ? nil : $0 }
        let icons = source.customIcons
        let meta = KPMeta(
            recycleBinUUID: recycleBinUUID,
            hasRecycleBinUUIDElement: source.recycleBinUUID != nil,
            maintenanceHistoryDays: source.maintenanceHistoryDays,
            historyMaxItems: source.historyMaxItems,
            historyMaxSize: source.historyMaxSize,
            unknownXML: source.unknownXML,
            deletedObjects: document.root.deletedObjects.map { KPDeletedObject(uuid: $0.uuid, deletionTime: $0.deletionTime) },
            customIcons: icons.mapValues(\.data),
            customIconNames: icons.compactMapValues(\.name)
        )
        let root = KPGroup(
            id: nullUUID,
            name: "Root",
            entries: document.root.entries.map { entry($0, sessionKey: sessionKey) },
            groups: document.root.groups.map { group($0, sessionKey: sessionKey) },
            recycleBinUUID: recycleBinUUID,
            unknownXML: document.root.unknownXML
        )
        return (root, meta)
    }

    static let nullUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func group(_ source: KDBXDocument.Group, sessionKey: SymmetricKey) -> KPGroup {
        KPGroup(
            id: source.uuid,
            name: source.name,
            notes: source.notes ?? "",
            hasNotesElement: source.notes != nil,
            iconID: source.iconID,
            customIconUUID: source.customIconUUID,
            tags: source.tags ?? [],
            hasTagsElement: source.tags != nil,
            entries: source.entries.map { entry($0, sessionKey: sessionKey) },
            groups: source.groups.map { group($0, sessionKey: sessionKey) },
            isExpanded: source.isExpanded,
            searchingEnabled: source.enableSearching.map(KPInheritableBool.init),
            creationTime: source.times.creationTime,
            lastModificationTime: source.times.lastModificationTime,
            locationChanged: source.times.locationChanged,
            unknownXML: source.unknownXML
        )
    }

    private static func entry(_ source: KDBXDocument.Entry, sessionKey: SymmetricKey) -> KPEntry {
        var fields = EntryStrings()
        var protectedStringKeys: Set<String> = []
        for field in source.strings where !field.key.isEmpty {
            if field.isProtected {
                protectedStringKeys.insert(field.key)
            }
            fields.set(field.value, for: field.key)
        }
        let totpConfig = fields.buildTOTPConfig(sessionKey: sessionKey)
        // Only the field that backs the TOTP config is written from it; other
        // otp-named fields stay in customFields so they round-trip.
        let keeOTPFieldName = totpConfig?.keeOTPSource?.fieldName
        // The PEM is sealed so its plaintext does not outlive lock. Only the
        // canonical spelling carries a PEM; the legacy aliases rename other
        // fields (see PasskeyCredential).
        let passkeyPrivateKey = fields.customFields[PasskeyCredential.privateKeyPEMKey].map {
            (try? EncryptedValue.encrypt($0, using: sessionKey)) ?? .empty
        }
        return KPEntry(
            id: source.uuid,
            title: fields.title,
            username: fields.username,
            password: (try? EncryptedValue.encrypt(fields.password, using: sessionKey)) ?? .empty,
            url: fields.url,
            notes: fields.notes,
            iconID: source.iconID,
            customIconUUID: source.customIconUUID,
            tags: source.tags ?? [],
            hasTagsElement: source.tags != nil,
            customFields: fields.customFields.filter {
                !$0.key.hasPrefix("TimeOtp-") && $0.key != "TOTP Settings" && $0.key != "TOTP Seed"
                    && $0.key != keeOTPFieldName
                    && $0.key != PasskeyCredential.privateKeyPEMKey
            },
            customFieldOrder: fields.customFieldOrder,
            passkeyPrivateKey: passkeyPrivateKey,
            totpConfig: totpConfig,
            otpURL: fields.otpURL,
            creationTime: source.times.creationTime,
            lastModificationTime: source.times.lastModificationTime,
            expires: source.expires,
            expiryTime: source.expiryTime,
            locationChanged: source.times.locationChanged,
            history: source.history.map { entry($0, sessionKey: sessionKey) },
            unknownXML: source.unknownXML,
            protectedStringKeys: protectedStringKeys,
            attachments: source.binaries.map { KPAttachment(name: $0.key, ref: $0.ref, insertionIndex: $0.insertionIndex) }
        )
    }
}

extension KPInheritableBool {
    init(_ value: KDBXDocument.InheritableBool) {
        switch value {
        case .inherit: self = .inherit
        case .enabled: self = .enabled
        case .disabled: self = .disabled
        }
    }

    var documentValue: KDBXDocument.InheritableBool {
        switch self {
        case .inherit: .inherit
        case .enabled: .enabled
        case .disabled: .disabled
        }
    }
}

// MARK: - Entry strings

/// An entry's `<String>` fields as KeeForge reads them: the standard keys, then
/// custom fields in first-seen order (a repeated key keeps its first position
/// and its last value), and the TOTP formats they may hold.
private struct EntryStrings {
    var title = ""
    var username = ""
    var password = ""
    var url = ""
    var notes = ""
    var otpURL: String?
    var customFields: [String: String] = [:]
    var customFieldOrder: [String] = []

    mutating func set(_ value: String, for key: String) {
        switch key {
        case "Title": title = value
        case "UserName": username = value
        case "Password": password = value
        case "URL": url = value
        case "Notes": notes = value
        case "otp": otpURL = value
        default:
            if customFields[key] == nil {
                customFieldOrder.append(key)
            }
            customFields[key] = value
        }
    }

    func buildTOTPConfig(sessionKey: SymmetricKey) -> TOTPConfig? {
        // otpauth:// URI (KeePassXC standard)
        if let otpURL, otpURL.hasPrefix("otpauth://") {
            return parseTOTPFromURI(otpURL, sessionKey: sessionKey)
        }

        // KeePass 2.x TimeOtp fields
        if let field = KeePassTOTPSecretField.allCases.first(where: { customFields[$0.rawValue]?.isEmpty == false }),
           let secret = customFields[field.rawValue] {
            let encryptedSecret = (try? EncryptedValue.encrypt(secret, using: sessionKey)) ?? .empty
            let period = Self.sanitizedTOTPPeriod(Int(customFields["TimeOtp-Period"] ?? "30"))
            let digits = Self.sanitizedTOTPDigits(Int(customFields["TimeOtp-Length"] ?? "6"))
            let algo = customFields["TimeOtp-Algorithm"].flatMap(TOTPAlgorithm.init(keePassName:)) ?? .sha1
            return TOTPConfig(
                secret: encryptedSecret,
                decodedSecret: decodedKeePassSecret(secret, in: field, sessionKey: sessionKey),
                keePassSecretField: field,
                period: period,
                digits: digits,
                algorithm: algo
            )
        }

        // Legacy TOTP Seed / TOTP Settings
        if let seed = customFields["TOTP Seed"], !seed.isEmpty {
            let encryptedSeed = (try? EncryptedValue.encrypt(seed, using: sessionKey)) ?? .empty
            let settings = customFields["TOTP Settings"] ?? "30;6"
            let parts = settings.components(separatedBy: ";")
            let period = Self.sanitizedTOTPPeriod(Int(parts.first ?? "30"))
            let digits = Self.sanitizedTOTPDigits(Int(parts.count > 1 ? parts[1] : "6"))
            return TOTPConfig(secret: encryptedSeed, period: period, digits: digits)
        }

        let candidates = [("otp", otpURL), ("OTP", customFields["OTP"]), ("Otp", customFields["Otp"])]
        for (fieldName, value) in candidates where value?.hasPrefix("key=") == true {
            if let value, let config = parseKeeOTPTOTP(value, fieldName: fieldName, sessionKey: sessionKey) {
                return config
            }
        }
        return nil
    }

    private func parseKeeOTPTOTP(_ query: String, fieldName: String, sessionKey: SymmetricKey) -> TOTPConfig? {
        // URLComponents percent-decodes query values but, unlike form decoding,
        // keeps a literal "+" as "+" rather than converting it to a space.
        guard let components = URLComponents(string: "https://keeotp.invalid/?\(query)") else { return nil }
        let mappedNames = Set(["key", "encoding", "type", "step", "size", "otphashmode"])
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard !mappedNames.contains(name) || params[name] == nil,
                  let value = item.value else { return nil }
            if mappedNames.contains(name) { params[name] = value }
        }

        // KeeOtp2 omits parameters that hold their defaults (a plain TOTP
        // entry is just "key=SECRET", and "type" is only written for HOTP),
        // so only `key` is required; the rest are validated when present.
        guard let key = params["key"], !key.isEmpty else { return nil }
        if let type = params["type"], type.uppercased() != "TOTP" { return nil }
        let step: Int
        if let stepValue = params["step"] {
            guard let parsed = Int(stepValue), parsed > 0 else { return nil }
            step = parsed
        } else {
            step = 30
        }
        let size: Int
        if let sizeValue = params["size"] {
            guard let parsed = Int(sizeValue), [6, 8].contains(parsed) else { return nil }
            size = parsed
        } else {
            size = 6
        }
        let algorithm: TOTPAlgorithm
        if let hash = params["otphashmode"] {
            guard let parsed = TOTPAlgorithm(rawValue: hash.uppercased()) else { return nil }
            algorithm = parsed
        } else {
            algorithm = .sha1
        }
        guard let decoded = decodeKeeOTPSecret(key, encoding: params["encoding"] ?? "Base32"), !decoded.isEmpty,
              let encryptedKey = try? EncryptedValue.encrypt(key, using: sessionKey),
              let encryptedDecoded = try? EncryptedValue.encrypt(decoded, using: sessionKey) else { return nil }

        return TOTPConfig(
            secret: encryptedKey,
            decodedSecret: encryptedDecoded,
            keeOTPSource: KeeOTPSource(fieldName: fieldName, rawQuery: query),
            period: step,
            digits: size,
            algorithm: algorithm
        )
    }

    /// Base32 stays text and is decoded when a code is generated. The other
    /// encodings are decoded here; a value that does not decode keeps its
    /// field and generates no code.
    private func decodedKeePassSecret(
        _ secret: String,
        in field: KeePassTOTPSecretField,
        sessionKey: SymmetricKey
    ) -> EncryptedValue? {
        let encoding: String
        switch field {
        case .base32: return nil
        case .utf8: encoding = "utf8"
        case .hex: encoding = "hex"
        case .base64: encoding = "base64"
        }
        return decodeKeeOTPSecret(secret, encoding: encoding)
            .flatMap { try? EncryptedValue.encrypt($0, using: sessionKey) } ?? .empty
    }

    private func decodeKeeOTPSecret(_ key: String, encoding: String) -> Data? {
        switch encoding.lowercased() {
        case "base32":
            guard let normalized = normalizeStrictUnpaddedBase32(key) else { return nil }
            return TOTPGenerator.base32Decode(normalized).flatMap { $0.isEmpty ? nil : $0 }
        case "base64":
            guard let decoded = Data(base64Encoded: key), !decoded.isEmpty,
                  decoded.base64EncodedString() == key else { return nil }
            return decoded
        case "hex":
            guard key.count.isMultiple(of: 2), !key.isEmpty else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(key.count / 2)
            var index = key.startIndex
            while index < key.endIndex {
                let next = key.index(index, offsetBy: 2)
                guard let byte = UInt8(key[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return Data(bytes)
        case "utf8":
            return Data(key.utf8)
        default:
            return nil
        }
    }

    private func normalizeStrictUnpaddedBase32(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        var normalized: [UInt8] = []
        normalized.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 65...90, 50...55: normalized.append(byte)
            case 97...122: normalized.append(byte - 32)
            default: return nil
            }
        }

        let remainder = normalized.count % 8
        let unusedBits: Int
        switch remainder {
        case 0: return String(bytes: normalized, encoding: .ascii)
        case 2: unusedBits = 2
        case 4: unusedBits = 4
        case 5: unusedBits = 1
        case 7: unusedBits = 3
        default: return nil
        }
        guard let last = normalized.last else { return nil }
        let lastValue = last >= 65 ? Int(last - 65) : Int(last - 50 + 26)
        guard lastValue & ((1 << unusedBits) - 1) == 0 else { return nil }
        return String(bytes: normalized, encoding: .ascii)
    }

    private func parseTOTPFromURI(_ uri: String, sessionKey: SymmetricKey) -> TOTPConfig? {
        guard let components = URLComponents(string: uri) else { return nil }
        // First occurrence wins; `Dictionary(uniqueKeysWithValues:)` traps on
        // duplicate query names (e.g. "?secret=A&Secret=A"), which is
        // file-controlled input.
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard params[name] == nil, let value = item.value else { continue }
            params[name] = value
        }

        guard let secret = params["secret"] else { return nil }
        let encryptedSecret = (try? EncryptedValue.encrypt(secret, using: sessionKey)) ?? .empty
        let period = Self.sanitizedTOTPPeriod(Int(params["period"] ?? "30"))
        let digits = Self.sanitizedTOTPDigits(Int(params["digits"] ?? "6"))
        let algorithm = TOTPAlgorithm(rawValue: (params["algorithm"] ?? "SHA1").uppercased()) ?? .sha1

        return TOTPConfig(secret: encryptedSecret, period: period, digits: digits, algorithm: algorithm)
    }

    /// File-supplied TOTP timing values must never reach `TOTPGenerator` in a
    /// form that traps (zero/negative periods divide by zero; digit counts
    /// above 9 overflow the 10^digits modulus). Out-of-range values fall back
    /// to the RFC 6238 defaults, matching how unparsable values already behave.
    private static func sanitizedTOTPPeriod(_ value: Int?) -> Int {
        guard let value, value > 0 else { return 30 }
        return value
    }

    private static func sanitizedTOTPDigits(_ value: Int?) -> Int {
        guard let value, (1...9).contains(value) else { return 6 }
        return value
    }
}
