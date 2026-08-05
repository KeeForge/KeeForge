import CryptoKit
import Foundation

struct KDBXXMLSerializer {
    enum SerializationError: Error {
        case invalidInnerStreamKey
    }

    private let rootGroup: KPGroup
    private let meta: KPMeta
    private let sessionKey: SymmetricKey
    private var innerStream: KDBXCrypto.ChaCha20Keystream?

    private static let xmlPrefix = Data([0xEF, 0xBB, 0xBF]) +
        Data("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n".utf8)

    init(rootGroup: KPGroup, meta: KPMeta, innerStreamKey: Data, sessionKey: SymmetricKey) {
        self.rootGroup = rootGroup
        self.meta = meta
        self.sessionKey = sessionKey

        let keyHash = KDBXCrypto.sha512(innerStreamKey)
        self.innerStream = KDBXCrypto.ChaCha20Keystream(
            key: Data(keyHash.prefix(32)),
            nonce: Data(keyHash[32..<44])
        )
    }

    mutating func serialize() throws -> Data {
        var xml = "<KeePassFile>"
        xml += try serializeMeta()
        xml += try serializeRoot()
        xml += "</KeePassFile>"

        var data = Self.xmlPrefix
        data.append(Data(xml.utf8))
        return data
    }

    private mutating func serializeMeta() throws -> String {
        var xml = "<Meta>"
        var knownChildCount = 0

        if meta.hasRecycleBinUUIDElement || meta.recycleBinUUID != nil {
            xml += try opaqueXML(from: meta.unknownXML, path: [], insertionIndex: knownChildCount)
            let recycleBinUUID = meta.recycleBinUUID
            xml += element("RecycleBinUUID", value: serializeUUID(recycleBinUUID))
            knownChildCount += 1
        }

        if let maintenanceHistoryDays = meta.maintenanceHistoryDays {
            xml += try opaqueXML(from: meta.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += element("MaintenanceHistoryDays", value: String(maintenanceHistoryDays))
            knownChildCount += 1
        }

        if let historyMaxItems = meta.historyMaxItems {
            xml += try opaqueXML(from: meta.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += element("HistoryMaxItems", value: String(historyMaxItems))
            knownChildCount += 1
        }

        if let historyMaxSize = meta.historyMaxSize {
            xml += try opaqueXML(from: meta.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += element("HistoryMaxSize", value: String(historyMaxSize))
            knownChildCount += 1
        }

        xml += try trailingOpaqueXML(from: meta.unknownXML, path: [], knownChildCount: knownChildCount)
        xml += "</Meta>"
        return xml
    }

    private mutating func serializeRoot() throws -> String {
        var xml = "<Root>"
        var knownChildCount = 0

        for entry in rootGroup.entries {
            xml += try opaqueXML(from: rootGroup.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try serializeEntry(entry)
            knownChildCount += 1
        }

        for group in rootGroup.groups {
            xml += try opaqueXML(from: rootGroup.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try serializeGroup(group)
            knownChildCount += 1
        }

        if !meta.deletedObjects.isEmpty {
            xml += try opaqueXML(from: rootGroup.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += serializeDeletedObjects(meta.deletedObjects)
            knownChildCount += 1
        }

        xml += try trailingOpaqueXML(from: rootGroup.unknownXML, path: [], knownChildCount: knownChildCount)
        xml += "</Root>"
        return xml
    }

    private mutating func serializeGroup(_ group: KPGroup) throws -> String {
        var xml = "<Group>"
        var knownChildCount = 0

        xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += element("UUID", value: serializeUUID(group.id))
        knownChildCount += 1

        xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += element("Name", value: escape(group.name))
        knownChildCount += 1

        // Immediately after `<Name>`, the position KeePass's `WriteGroup` uses,
        // so a KeePass-written file keeps its opaque siblings where the parser
        // recorded them. `<Notes>` is a KDBX 3.1 element too, so writing one
        // never forces a version bump — only `<Tags>` does.
        if group.hasNotesElement || !group.notes.isEmpty {
            xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += element("Notes", value: escape(group.notes))
            knownChildCount += 1
        }

        xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += element("IconID", value: String(group.iconID))
        knownChildCount += 1

        xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += element("IsExpanded", value: group.isExpanded ? "True" : "False")
        knownChildCount += 1

        if group.creationTime != nil || group.lastModificationTime != nil || hasOpaqueTimes(group.unknownXML) {
            xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try serializeTimes(
                creationTime: group.creationTime,
                lastModificationTime: group.lastModificationTime,
                unknownXML: group.unknownXML
            )
            knownChildCount += 1
        }

        // Child order here must match KeePass's, because the parser's recorded
        // opaque-XML insertion indices are relative to the same sequence. A
        // group whose source had no element writes none and leaves
        // `knownChildCount` put, mirroring the parser.
        if let searchingEnabled = group.searchingEnabled {
            xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += element("EnableSearching", value: searchingEnabled.xmlValue)
            knownChildCount += 1
        }

        // KDBX 4.1. The writer raises the header's minor version whenever any
        // group carries this element, so the two can never disagree.
        if group.hasTagsElement || !group.tags.isEmpty {
            xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += element("Tags", value: escape(group.tags.joined(separator: ",")))
            knownChildCount += 1
        }

        for entry in group.entries {
            xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try serializeEntry(entry)
            knownChildCount += 1
        }

        for subgroup in group.groups {
            xml += try opaqueXML(from: group.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try serializeGroup(subgroup)
            knownChildCount += 1
        }

        xml += try trailingOpaqueXML(from: group.unknownXML, path: [], knownChildCount: knownChildCount)
        xml += "</Group>"
        return xml
    }

    private mutating func serializeEntry(_ entry: KPEntry) throws -> String {
        var xml = "<Entry>"
        // Two counters, mirroring `EntryBuilder`: `knownChildCount` is the
        // opaque-XML position space and advances for every structural child
        // including `<Binary>`, while `attachmentAnchor` skips attachments and
        // is what `KPAttachment.insertionIndex` is expressed against, so
        // attachments at the same source position don't shift each other.
        var knownChildCount = 0
        var attachmentAnchor = 0
        var remainingAttachments = entry.attachments

        func attachmentsXML() throws -> String {
            var matched = ""
            var stillPending: [KPAttachment] = []
            for attachment in remainingAttachments {
                if attachment.insertionIndex == attachmentAnchor {
                    matched += serializeBinary(attachment)
                    knownChildCount += 1
                    // The bump above opened a new opaque-XML position; query it
                    // now or fragments recorded there are skipped by the next,
                    // later lookup.
                    matched += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
                } else {
                    stillPending.append(attachment)
                }
            }
            remainingAttachments = stillPending
            return matched
        }

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try attachmentsXML()
        xml += element("UUID", value: serializeUUID(entry.id))
        knownChildCount += 1
        attachmentAnchor += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try attachmentsXML()
        xml += element("IconID", value: String(entry.iconID))
        knownChildCount += 1
        attachmentAnchor += 1

        if entry.hasTagsElement || !entry.tags.isEmpty {
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try attachmentsXML()
            xml += element("Tags", value: escape(entry.tags.joined(separator: ",")))
            knownChildCount += 1
            attachmentAnchor += 1
        }

        if entry.creationTime != nil || entry.lastModificationTime != nil || hasOpaqueTimes(entry.unknownXML) {
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try attachmentsXML()
            xml += try serializeTimes(
                creationTime: entry.creationTime,
                lastModificationTime: entry.lastModificationTime,
                unknownXML: entry.unknownXML
            )
            knownChildCount += 1
            attachmentAnchor += 1
        }

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try attachmentsXML()
        xml += try serializeString(key: "Title", value: entry.title, isProtected: entry.protectedStringKeys.contains("Title"))
        knownChildCount += 1
        attachmentAnchor += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try attachmentsXML()
        xml += try serializeString(key: "UserName", value: entry.username, isProtected: entry.protectedStringKeys.contains("UserName"))
        knownChildCount += 1
        attachmentAnchor += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try attachmentsXML()
        xml += try serializeString(
            key: "Password",
            value: try entry.password.decrypt(using: sessionKey),
            isProtected: true
        )
        knownChildCount += 1
        attachmentAnchor += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try attachmentsXML()
        xml += try serializeString(key: "URL", value: entry.url, isProtected: entry.protectedStringKeys.contains("URL"))
        knownChildCount += 1
        attachmentAnchor += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try attachmentsXML()
        xml += try serializeString(key: "Notes", value: entry.notes, isProtected: entry.protectedStringKeys.contains("Notes"))
        knownChildCount += 1
        attachmentAnchor += 1

        let keeOTPSource = entry.totpConfig?.keeOTPSource
        if let source = keeOTPSource, source.fieldName == "otp" {
            // Keep the KeeOTP field spelling and raw query unless the editor
            // explicitly rewrote the source.
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try attachmentsXML()
            xml += try serializeString(
                key: "otp",
                value: source.rawQuery,
                isProtected: entry.protectedStringKeys.contains("otp")
            )
            knownChildCount += 1
            attachmentAnchor += 1
        } else if let otpURL = entry.otpURL {
            // Preserve the original otpauth:// URI so issuer/label and any
            // custom query parameters survive the round-trip. Splitting into
            // TimeOtp-* fields drops everything outside the canonical set.
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try attachmentsXML()
            xml += try serializeString(
                key: "otp",
                value: otpURL,
                isProtected: entry.protectedStringKeys.contains("otp")
            )
            knownChildCount += 1
            attachmentAnchor += 1
        }
        if let source = keeOTPSource, source.fieldName != "otp" {
            // A KeeOTP source in a custom-named field is managed here (it is
            // stripped from customFields at parse time) and coexists with any
            // unrelated value in the standard otp slot above.
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try attachmentsXML()
            xml += try serializeString(
                key: source.fieldName,
                value: source.rawQuery,
                isProtected: entry.protectedStringKeys.contains(source.fieldName)
            )
            knownChildCount += 1
            attachmentAnchor += 1
        }
        if keeOTPSource == nil, entry.otpURL == nil, let totpConfig = entry.totpConfig {
            let secret = try totpConfig.secret.decrypt(using: sessionKey)
            let totpFields = [
                ("TimeOtp-Secret-Base32", secret, true),
                ("TimeOtp-Period", String(totpConfig.period), false),
                ("TimeOtp-Length", String(totpConfig.digits), false),
                ("TimeOtp-Algorithm", totpConfig.algorithm.rawValue, false),
            ]

            for (key, value, isProtected) in totpFields {
                xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
                xml += try attachmentsXML()
                xml += try serializeString(key: key, value: value, isProtected: isProtected)
                knownChildCount += 1
                attachmentAnchor += 1
            }
        }

        // The diverted passkey private key (KPEX_PASSKEY_PRIVATE_KEY_PEM) is
        // stripped from customFields at parse time and held session-key
        // sealed on the entry. Re-emit it under its original key, merged back
        // into the sorted custom-field order, so serialize→parse→serialize
        // stays byte-identical. Entries built directly with the PEM still in
        // customFields (no diverted value) serialize through the plain
        // custom-field path below, producing the same bytes.
        var customFieldKeys = Array(entry.customFields.keys)
        let passkeyPEMKey = PasskeyCredential.privateKeyPEMKey
        let emitsDivertedPasskeyPEM = entry.passkeyPrivateKey != nil
            && entry.customFields[passkeyPEMKey] == nil
        if emitsDivertedPasskeyPEM {
            customFieldKeys.append(passkeyPEMKey)
        }

        for key in customFieldKeys.sorted() {
            let value: String
            if key == passkeyPEMKey, emitsDivertedPasskeyPEM, let sealedPEM = entry.passkeyPrivateKey {
                value = try sealedPEM.decrypt(using: sessionKey)
            } else {
                value = entry.customFields[key] ?? ""
            }
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try attachmentsXML()
            xml += try serializeString(
                key: key,
                value: value,
                isProtected: entry.protectedStringKeys.contains(key)
            )
            knownChildCount += 1
            attachmentAnchor += 1
        }

        if !entry.history.isEmpty || hasOpaqueHistory(entry.unknownXML) {
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try attachmentsXML()
            xml += try serializeHistory(entry.history, unknownXML: entry.unknownXML)
            knownChildCount += 1
            attachmentAnchor += 1
        }

        // Any attachments recorded at or beyond the final anchor position
        // (including newly-added attachments, which default to
        // insertionIndex 0 but only reach here once all indices below the
        // final count have already been drained) trail just before the
        // closing tag, mirroring trailingOpaqueXML.
        xml += remainingAttachments.map(serializeBinary).joined()
        xml += try trailingOpaqueXML(from: entry.unknownXML, path: [], knownChildCount: knownChildCount)
        xml += "</Entry>"
        return xml
    }

    private mutating func serializeHistory(
        _ historyEntries: [KPEntry],
        unknownXML: OpaqueXMLNodes
    ) throws -> String {
        var xml = "<History>"
        var knownChildCount = 0

        for historyEntry in historyEntries {
            xml += try opaqueXML(from: unknownXML, path: ["History"], insertionIndex: knownChildCount)
            xml += try serializeEntry(historyEntry)
            knownChildCount += 1
        }

        xml += try trailingOpaqueXML(from: unknownXML, path: ["History"], knownChildCount: knownChildCount)
        xml += "</History>"
        return xml
    }

    private mutating func serializeTimes(
        creationTime: Date?,
        lastModificationTime: Date?,
        unknownXML: OpaqueXMLNodes
    ) throws -> String {
        var xml = "<Times>"
        var knownChildCount = 0

        if let creationTime {
            xml += try opaqueXML(from: unknownXML, path: ["Times"], insertionIndex: knownChildCount)
            xml += element("CreationTime", value: serializeDate(creationTime))
            knownChildCount += 1
        }

        if let lastModificationTime {
            xml += try opaqueXML(from: unknownXML, path: ["Times"], insertionIndex: knownChildCount)
            xml += element("LastModificationTime", value: serializeDate(lastModificationTime))
            knownChildCount += 1
        }

        xml += try trailingOpaqueXML(from: unknownXML, path: ["Times"], knownChildCount: knownChildCount)
        xml += "</Times>"
        return xml
    }

    private func serializeDeletedObjects(_ objects: [KPDeletedObject]) -> String {
        var xml = "<DeletedObjects>"
        for obj in objects {
            xml += "<DeletedObject>"
            xml += element("UUID", value: serializeUUID(obj.uuid))
            xml += element("DeletionTime", value: serializeDate(obj.deletionTime))
            xml += "</DeletedObject>"
        }
        xml += "</DeletedObjects>"
        return xml
    }

    private mutating func serializeString(key: String, value: String, isProtected: Bool) throws -> String {
        let renderedValue: String
        let attributes: String

        if isProtected {
            renderedValue = try encryptProtectedValue(value)
            attributes = " Protected=\"True\""
        } else {
            renderedValue = escape(value)
            attributes = ""
        }

        return "<String><Key>\(escape(key))</Key><Value\(attributes)>\(renderedValue)</Value></String>"
    }

    private func serializeBinary(_ attachment: KPAttachment) -> String {
        "<Binary><Key>\(escape(attachment.name))</Key><Value Ref=\"\(attachment.ref)\"/></Binary>"
    }

    private mutating func encryptProtectedValue(_ plaintext: String) throws -> String {
        guard var keystream = innerStream else {
            throw SerializationError.invalidInnerStreamKey
        }

        let encrypted = keystream.xor(Data(plaintext.utf8))
        innerStream = keystream
        return encrypted.base64EncodedString()
    }

    private mutating func opaqueXML(from unknownXML: OpaqueXMLNodes, path: [String], insertionIndex: Int) throws -> String {
        try unknownXML
            .xmlFragments(path: path, insertionIndex: insertionIndex)
            .map { try rewriteProtectedValues(in: $0) }
            .joined()
    }

    private mutating func trailingOpaqueXML(
        from unknownXML: OpaqueXMLNodes,
        path: [String],
        knownChildCount: Int
    ) throws -> String {
        let maxInsertionIndex = unknownXML.maxInsertionIndex(path: path)
        guard maxInsertionIndex >= knownChildCount else { return "" }

        var xml = ""
        for index in knownChildCount...maxInsertionIndex {
            xml += try opaqueXML(from: unknownXML, path: path, insertionIndex: index)
        }
        return xml
    }

    private func hasOpaqueTimes(_ unknownXML: OpaqueXMLNodes) -> Bool {
        unknownXML.nodes.contains { $0.path == ["Times"] }
    }

    private func hasOpaqueHistory(_ unknownXML: OpaqueXMLNodes) -> Bool {
        unknownXML.nodes.contains { $0.path == ["History"] }
    }

    private mutating func rewriteProtectedValues(in xml: String) throws -> String {
        let pattern = #"<Value(?=[^>]*Protected="True")[^>]*>(.*?)</Value>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, options: [], range: nsRange)

        var rewritten = xml
        for match in matches.reversed() {
            guard
                match.numberOfRanges > 1,
                let valueRange = Range(match.range(at: 1), in: rewritten)
            else {
                continue
            }

            let escapedPlaintext = String(rewritten[valueRange])
            let plaintext = unescape(escapedPlaintext)
            let encrypted = try encryptProtectedValue(plaintext)
            rewritten.replaceSubrange(valueRange, with: encrypted)
        }

        return rewritten
    }

    private func element(_ name: String, value: String) -> String {
        "<\(name)>\(value)</\(name)>"
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func serializeUUID(_ uuid: UUID?) -> String {
        guard let uuid else {
            return Data(repeating: 0, count: 16).base64EncodedString()
        }
        return uuid.kdbxBase64String
    }

    /// Seconds from Foundation's reference date (2001-01-01 UTC) to the KeePass
    /// epoch (0001-01-01 UTC).  Must stay in sync with the constant in
    /// `KDBXXMLParser`.
    private static let kpEpochOffset: TimeInterval = -63_113_904_000

    private func serializeDate(_ date: Date) -> String {
        // KDBX4 binary format: little-endian Int64 seconds since
        // 0001-01-01 UTC, base64-encoded.
        let interval = date.timeIntervalSinceReferenceDate - Self.kpEpochOffset
        let seconds: Int64
        if interval.isNaN {
            seconds = 0
        } else if interval >= Double(Int64.max) {
            seconds = .max
        } else if interval <= Double(Int64.min) {
            seconds = .min
        } else {
            seconds = Int64(interval)
        }
        var leSeconds = seconds.littleEndian
        return withUnsafeBytes(of: &leSeconds) { Data($0) }.base64EncodedString()
    }
}
