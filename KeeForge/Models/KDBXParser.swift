import Foundation
import CryptoKit
import KDBXKit

/// Opens a KDBX file into KeeForge's model: `KDBXContainer` decrypts it, and
/// `KDBXXMLParser` reads the XML into groups, entries, and metadata.
enum KDBXParser {
    typealias Opened = (rootGroup: KPGroup, meta: KPMeta, header: KDBXContainer.Header)

    /// Parse and decrypt a KDBX file, returning the root group
    static func parse(data: Data, password: String, sessionKey: SymmetricKey, kdfPolicy: KDFExecutionPolicy) throws -> KPGroup {
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        return try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
    }

    static func parseWithMeta(
        data: Data,
        password: String,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        return try parseWithMeta(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        password: String,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Opened {
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        return try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
    }

    /// Parse and decrypt with password and/or key file data
    static func parse(data: Data, password: String?, keyFileData: Data?, sessionKey: SymmetricKey, kdfPolicy: KDFExecutionPolicy) throws -> KPGroup {
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        return try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
    }

    static func parseWithMeta(
        data: Data,
        password: String?,
        keyFileData: Data?,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        return try parseWithMeta(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        password: String?,
        keyFileData: Data?,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Opened {
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        return try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
    }

    static func parse(data: Data, compositeKey: SymmetricKey, sessionKey: SymmetricKey, kdfPolicy: KDFExecutionPolicy) throws -> KPGroup {
        try parseWithMeta(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy).rootGroup
    }

    static func parseWithMeta(
        data: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let parsed = try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
        return (parsed.rootGroup, parsed.meta)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Opened {
        let payload = try KDBXContainer.read(data: data, compositeKey: compositeKey, kdfPolicy: kdfPolicy)
        return try parse(payload, sessionKey: sessionKey)
    }

    /// Parses a file with the KDF output supplied by `transformedKey`, which
    /// receives the header's KDF parameters. A KDBX 4 key that does not
    /// belong to the file fails the header HMAC (`CryptoError.hmacMismatch`).
    static func parseWithMetaAndHeader(
        data: Data,
        sessionKey: SymmetricKey,
        transformedKey provideTransformedKey: (_ kdfParameters: KDBXVariantMap) throws -> Data
    ) throws -> Opened {
        let payload = try KDBXContainer.read(data: data, transformedKey: provideTransformedKey)
        return try parse(payload, sessionKey: sessionKey)
    }

    private static func parse(_ payload: KDBXContainer.Payload, sessionKey: SymmetricKey) throws -> Opened {
        let parsed = try parseXML(
            xmlData: payload.xml,
            innerStreamKey: payload.header.innerStreamKey,
            innerStreamID: payload.header.innerStreamID,
            sessionKey: sessionKey
        )
        return (parsed.rootGroup, parsed.meta, payload.header)
    }

    static func parseXML(
        xmlData: Data,
        innerStreamKey: Data,
        innerStreamID: UInt32,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let parser = try KDBXXMLParser(
            data: xmlData,
            innerStream: KDBXInnerStream(streamID: innerStreamID, key: innerStreamKey),
            sessionKey: sessionKey
        )
        return try parser.parse()
    }
}


// MARK: - XML Parser

/// The decrypted payload is not well-formed XML.
struct KDBXXMLParseError: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "Failed to parse database XML") }
}

final class KDBXXMLParser: NSObject, XMLParserDelegate {
    private struct GroupBuilder {
        var id = UUID()
        var name = ""
        var notes = ""
        var hasNotesElement = false
        var iconID = 48
        var customIconUUID: UUID?
        var tags: [String] = []
        var hasTagsElement = false
        var entries: [KPEntry] = []
        var groups: [KPGroup] = []
        var isExpanded = true
        var searchingEnabled: KPInheritableBool?
        var creationTime: Date?
        var lastModificationTime: Date?
        var locationChanged: Date?
        var unknownXML = OpaqueXMLNodes.empty
        var knownChildCount = 0
        var timesKnownChildCount = 0

        func build(recycleBinUUID: UUID? = nil) -> KPGroup {
            KPGroup(
                id: id,
                name: name,
                notes: notes,
                hasNotesElement: hasNotesElement,
                iconID: iconID,
                customIconUUID: customIconUUID,
                tags: tags,
                hasTagsElement: hasTagsElement,
                entries: entries,
                groups: groups,
                isExpanded: isExpanded,
                searchingEnabled: searchingEnabled,
                creationTime: creationTime,
                lastModificationTime: lastModificationTime,
                locationChanged: locationChanged,
                recycleBinUUID: recycleBinUUID,
                unknownXML: unknownXML
            )
        }
    }

    private struct MetaBuilder {
        var recycleBinUUID: UUID?
        var hasRecycleBinUUIDElement = false
        var maintenanceHistoryDays: Int?
        var historyMaxItems: Int?
        var historyMaxSize: Int64?
        var unknownXML = OpaqueXMLNodes.empty
        var knownChildCount = 0
        var customIcons: [UUID: Data] = [:]
        var customIconNames: [UUID: String] = [:]

        func build() -> KPMeta {
            KPMeta(
                recycleBinUUID: recycleBinUUID,
                hasRecycleBinUUIDElement: hasRecycleBinUUIDElement,
                maintenanceHistoryDays: maintenanceHistoryDays,
                historyMaxItems: historyMaxItems,
                historyMaxSize: historyMaxSize,
                unknownXML: unknownXML,
                customIcons: customIcons,
                customIconNames: customIconNames
            )
        }
    }

    private struct XMLCaptureElement {
        let name: String
        let attributes: [String: String]
        var content = ""

        mutating func append(text: String) {
            content += Self.escape(text)
        }

        mutating func append(rawXML: String) {
            content += rawXML
        }

        func render() -> String {
            let renderedAttributes = attributes
                .sorted { $0.key < $1.key }
                .map { " \($0.key)=\"\(Self.escapeAttribute($0.value))\"" }
                .joined()
            return "<\(name)\(renderedAttributes)>\(content)</\(name)>"
        }

        private static func escape(_ text: String) -> String {
            text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\r", with: "&#xD;")
        }

        private static func escapeAttribute(_ text: String) -> String {
            escape(text)
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
    }

    private let data: Data
    private let sessionKey: SymmetricKey

    private var groupStack: [GroupBuilder] = []
    private var currentMeta = MetaBuilder()
    private var entryStack: [EntryBuilder] = []
    private var currentKey = ""
    private var currentValue = ""
    private var currentText = ""
    private var isProtected = false
    private var currentStringWasProtected = false
    private var inValue = false
    private var inKey = false
    private var currentBinaryRef: Int?
    private var currentBinaryRefWasParsable = true
    /// False when the just-closed `<EnableSearching>` held a value we don't
    /// understand, so `recordOpaqueXML` keeps it as an opaque node instead of
    /// counting it as structured and losing it on write.
    private var currentEnableSearchingWasParsable = false
    /// Same contract as `currentEnableSearchingWasParsable`, for the
    /// `<Times>/<LocationChanged>` timestamp.
    private var currentLocationChangedWasParsable = false
    private var historyDepth = 0
    private var inMeta = false
    private var inCustomIcons = false
    private var currentCustomIconUUID: UUID?
    private var currentCustomIconData: Data?
    private var currentCustomIconName: String?
    private var captureStack: [XMLCaptureElement] = []

    private var innerStream: KDBXInnerStream

    private var rootEntries: [KPEntry] = []
    private var rootGroups: [KPGroup] = []
    private var rootUnknownXML = OpaqueXMLNodes.empty
    private var rootKnownChildCount = 0
    private var meta = KPMeta()

    // DeletedObjects tracking
    private var inDeletedObjects = false
    private var inDeletedObject = false
    private var currentDeletedObjectUUID: UUID?
    private var currentDeletedObjectTime: Date?
    private var parsedDeletedObjects: [KPDeletedObject] = []
    private static let syntheticRootUUID = nullUUID

    private var currentEntry: EntryBuilder? {
        entryStack.last
    }

    init(data: Data, innerStream: KDBXInnerStream, sessionKey: SymmetricKey) {
        self.data = data
        self.innerStream = innerStream
        self.sessionKey = sessionKey
    }

    func parse() throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw KDBXXMLParseError()
        }
        let root = KPGroup(
            id: Self.syntheticRootUUID,
            name: "Root",
            entries: rootEntries,
            groups: rootGroups,
            recycleBinUUID: meta.recycleBinUUID,
            unknownXML: rootUnknownXML
        )
        var completedMeta = meta
        completedMeta.deletedObjects = parsedDeletedObjects
        return (root, completedMeta)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        captureStack.append(XMLCaptureElement(name: elementName, attributes: attributes))

        switch elementName {
        case "Meta":
            inMeta = true
            currentMeta = MetaBuilder()

        case "CustomIcons" where inMeta:
            inCustomIcons = true

        case "Icon" where inCustomIcons:
            currentCustomIconUUID = nil
            currentCustomIconData = nil
            currentCustomIconName = nil

        case "Group":
            groupStack.append(GroupBuilder())

        case "History":
            historyDepth += 1
            currentEntry?.historyKnownChildCount = 0

        case "Entry":
            entryStack.append(EntryBuilder())

        case "DeletedObjects":
            inDeletedObjects = true

        case "DeletedObject" where inDeletedObjects:
            inDeletedObject = true
            currentDeletedObjectUUID = nil
            currentDeletedObjectTime = nil

        case "String":
            currentKey = ""
            currentValue = ""
            isProtected = false
            currentStringWasProtected = false

        case "Binary":
            currentKey = ""
            currentBinaryRef = nil
            currentBinaryRefWasParsable = true

        case "Key":
            inKey = true

        case "Value":
            inValue = true
            currentStringWasProtected = attributes["Protected"]?.lowercased() == "true"
            isProtected = currentStringWasProtected
            if let refAttribute = attributes["Ref"] {
                if let ref = Int(refAttribute) {
                    currentBinaryRef = ref
                } else {
                    currentBinaryRefWasParsable = false
                }
            }

        case "Times":
            if let currentEntry {
                currentEntry.timesKnownChildCount = 0
            } else if !inMeta, let index = groupStack.indices.last {
                groupStack[index].timesKnownChildCount = 0
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
        if let index = captureStack.indices.last {
            captureStack[index].append(text: string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let captured = captureStack.removeLast()
        var capturedXML = captured.render()
        let parentName = captureStack.last?.name
        let grandparentName = captureStack.count >= 2 ? captureStack[captureStack.count - 2].name : nil

        switch elementName {
        case "Meta":
            inMeta = false
            meta = currentMeta.build()

        case "RecycleBinUUID":
            if inMeta {
                currentMeta.hasRecycleBinUUIDElement = true
                currentMeta.recycleBinUUID = parseKPUUID(currentText)
            }

        case "MaintenanceHistoryDays":
            if inMeta {
                currentMeta.maintenanceHistoryDays = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case "HistoryMaxItems":
            if inMeta {
                currentMeta.historyMaxItems = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case "HistoryMaxSize":
            if inMeta {
                currentMeta.historyMaxSize = Int64(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case "CustomIcons":
            inCustomIcons = false

        case "Icon" where inCustomIcons:
            if let uuid = currentCustomIconUUID, let data = currentCustomIconData {
                currentMeta.customIcons[uuid] = data
                currentMeta.customIconNames[uuid] = currentCustomIconName
            }
            currentCustomIconUUID = nil
            currentCustomIconData = nil

        case "Name" where inCustomIcons && parentName == "Icon":
            currentCustomIconName = currentText

        case "UUID" where inCustomIcons:
            currentCustomIconUUID = parseKPUUID(currentText)

        case "Data" where inCustomIcons && parentName == "Icon":
            currentCustomIconData = Data(
                base64Encoded: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                options: .ignoreUnknownCharacters
            )

        case "CustomIconUUID":
            if let currentEntry {
                currentEntry.customIconUUID = parseKPUUID(currentText)
            } else if !inMeta, let index = groupStack.indices.last {
                groupStack[index].customIconUUID = parseKPUUID(currentText)
            }

        case "Group":
            let group = groupStack.removeLast().build()
            if let index = groupStack.indices.last {
                groupStack[index].groups.append(group)
            } else {
                rootGroups.append(group)
            }

        case "DeletedObjects":
            inDeletedObjects = false

        case "DeletedObject" where inDeletedObjects:
            if let uuid = currentDeletedObjectUUID, let time = currentDeletedObjectTime {
                parsedDeletedObjects.append(KPDeletedObject(uuid: uuid, deletionTime: time))
            }
            inDeletedObject = false

        case "UUID" where inDeletedObject:
            currentDeletedObjectUUID = parseKPUUID(currentText)

        case "DeletionTime" where inDeletedObject:
            currentDeletedObjectTime = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))

        case "History":
            historyDepth = max(0, historyDepth - 1)

        case "Entry":
            guard let builder = entryStack.popLast() else { return }
            let entry = builder.build(sessionKey: sessionKey)
            if isInsideHistory(), let parentEntry = currentEntry {
                parentEntry.history.append(entry)
            } else if let index = groupStack.indices.last {
                groupStack[index].entries.append(entry)
            } else {
                rootEntries.append(entry)
            }
            if entryStack.isEmpty {
                currentKey = ""
                currentValue = ""
            }

        case "Name":
            if !inMeta, currentEntry == nil, let index = groupStack.indices.last {
                groupStack[index].name = currentText
            }

        case "Notes" where parentName == "Group":
            // A group's own notes. An entry's live in `<String><Key>Notes</Key>`
            // and never reach here, and the guards match the counter arm in
            // `recordOpaqueXML` exactly — if the two disagree, every opaque
            // fragment after `<Notes>` in that group shifts position. Presence
            // is tracked separately from content (three-state, like `Tags`),
            // and the text is stored untrimmed: leading or trailing whitespace
            // in free-form notes is the author's.
            if !inMeta, currentEntry == nil, let index = groupStack.indices.last {
                groupStack[index].hasNotesElement = true
                groupStack[index].notes = currentText
            }

        case "IconID":
            let val = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if let currentEntry {
                currentEntry.iconID = val
            } else if let index = groupStack.indices.last {
                groupStack[index].iconID = val
            }

        case "Key":
            if inKey {
                currentKey = currentText
                inKey = false
            }

        case "Value":
            if inValue {
                // Preserve leading/trailing whitespace in stored values — a
                // username or custom field may intentionally contain spaces,
                // and trimming here silently destroys that data. Only the
                // base64 ciphertext of a protected value needs trimming before
                // decoding.
                if isProtected {
                    let base64 = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let decoded = Data(base64Encoded: base64) {
                        currentValue = decryptProtectedValue(decoded)
                    } else {
                        currentValue = currentText
                    }
                } else {
                    currentValue = currentText
                }
                inValue = false
            }

        case "String":
            if let entry = currentEntry {
                if currentStringWasProtected, !currentKey.isEmpty {
                    entry.protectedStringKeys.insert(currentKey)
                }
                switch currentKey {
                case "Title": entry.title = currentValue
                case "UserName": entry.username = currentValue
                case "Password": entry.password = currentValue
                case "URL": entry.url = currentValue
                case "Notes": entry.notes = currentValue
                case "otp": entry.otpURL = currentValue
                default:
                    if !currentKey.isEmpty {
                        if entry.customFields[currentKey] == nil {
                            entry.customFieldOrder.append(currentKey)
                        }
                        entry.customFields[currentKey] = currentValue
                    }
                }
            }

        case "Binary":
            if let entry = currentEntry, currentBinaryRefWasParsable, let ref = currentBinaryRef {
                entry.attachments.append(
                    KPAttachment(name: currentKey, ref: ref, insertionIndex: entry.attachmentAnchorChildCount)
                )
            } else {
                // Malformed or missing Ref: keep the element as opaque XML
                // rather than failing the parse.
                currentBinaryRefWasParsable = false
            }

        case "Times":
            break // handled by sub-elements

        case "CreationTime":
            let date = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            if let currentEntry {
                currentEntry.creationTime = date
            } else if let index = groupStack.indices.last {
                groupStack[index].creationTime = date
            }

        case "LastModificationTime":
            let date = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            if let currentEntry {
                currentEntry.lastModificationTime = date
            } else if let index = groupStack.indices.last {
                groupStack[index].lastModificationTime = date
            }

        case "ExpiryTime" where parentName == "Times":
            if let currentEntry {
                currentEntry.expiryTime = parseKPDate(
                    currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

        case "Expires" where parentName == "Times":
            if let currentEntry {
                currentEntry.expires = currentText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "true"
            }

        case "LocationChanged" where parentName == "Times":
            // Structured only when the timestamp actually parsed; otherwise it
            // stays opaque, exactly like `EnableSearching`, so the counter arm
            // below and the serializer's emission stay in lockstep.
            currentLocationChangedWasParsable = false
            guard let date = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                break
            }
            if let currentEntry {
                currentEntry.locationChanged = date
                currentLocationChangedWasParsable = true
            } else if !inMeta, let index = groupStack.indices.last {
                groupStack[index].locationChanged = date
                currentLocationChangedWasParsable = true
            }

        case "Tags":
            if let entry = currentEntry {
                // Track element presence separately from content so that an
                // empty `<Tags></Tags>` element round-trips instead of being
                // silently dropped on save.
                entry.hasTagsElement = true
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    entry.tags = Self.splitStoredTags(trimmed)
                }
            } else if parentName == "Group", !inMeta, let index = groupStack.indices.last {
                // KDBX 4.1 group tags, same three-state presence semantics as
                // entries. Guarded like `EnableSearching`'s group case so a
                // stray `<Tags>` in any other context stays opaque instead of
                // mutating the enclosing group builder.
                groupStack[index].hasTagsElement = true
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    groupStack[index].tags = Self.splitStoredTags(trimmed)
                }
            }

        case "UUID":
            if let entry = currentEntry, !inMeta {
                if let uuid = parseKPUUID(currentText) {
                    entry.uuid = uuid
                }
            } else if currentEntry == nil, !inMeta, let index = groupStack.indices.last {
                if let uuid = parseKPUUID(currentText) {
                    groupStack[index].id = uuid
                }
            }

        case "IsExpanded":
            if let index = groupStack.indices.last {
                groupStack[index].isExpanded = currentText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "false"
            }

        case "EnableSearching" where parentName == "Group":
            currentEnableSearchingWasParsable = false
            if currentEntry == nil, !inMeta, let index = groupStack.indices.last,
               let value = KPInheritableBool.parse(currentText) {
                groupStack[index].searchingEnabled = value
                currentEnableSearchingWasParsable = true
            }

        default:
            break
        }

        if elementName == "Value", currentStringWasProtected {
            capturedXML = renderProtectedValueElement(attributes: captured.attributes, plaintext: currentValue)
        }

        recordOpaqueXML(
            elementName: elementName,
            parentName: parentName,
            grandparentName: grandparentName,
            xml: capturedXML
        )

        if let index = captureStack.indices.last {
            captureStack[index].append(rawXML: capturedXML)
        }
    }

    // MARK: - Protected Value Decryption

    private func decryptProtectedValue(_ encrypted: Data) -> String {
        let decrypted = innerStream.apply(encrypted)
        return String(data: decrypted, encoding: .utf8) ?? ""
    }

    private func isInsideHistory() -> Bool {
        historyDepth > 0
    }

    private func renderProtectedValueElement(attributes: [String: String], plaintext: String) -> String {
        let renderedAttributes = attributes
            .sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(escapeAttribute($0.value))\"" }
            .joined()
        return "<Value\(renderedAttributes)>\(escapeText(plaintext))</Value>"
    }

    private func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#xD;")
    }

    private func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func recordOpaqueXML(
        elementName: String,
        parentName: String?,
        grandparentName: String?,
        xml: String
    ) {
        switch parentName {
        case "Root":
            if elementName == "Entry" || elementName == "Group" || elementName == "DeletedObjects" {
                rootKnownChildCount += 1
            } else {
                rootUnknownXML.append(xml: xml, insertionIndex: rootKnownChildCount)
            }

        case "Meta":
            if elementName == "RecycleBinUUID" {
                currentMeta.knownChildCount += 1
            } else if elementName == "MaintenanceHistoryDays" ||
                        elementName == "HistoryMaxItems" ||
                        elementName == "HistoryMaxSize" {
                currentMeta.knownChildCount += 1
            } else {
                currentMeta.unknownXML.append(xml: xml, insertionIndex: currentMeta.knownChildCount)
            }

        case "Group":
            guard let index = groupStack.indices.last else { return }
            switch elementName {
            case "UUID", "Name", "IconID", "IsExpanded", "Times", "Entry", "Group":
                groupStack[index].knownChildCount += 1
            case "Tags" where !inMeta && currentEntry == nil,
                 "Notes" where !inMeta && currentEntry == nil:
                // Counted as structured only under exactly the conditions the
                // parse handler accepted it (a direct group child, outside
                // Meta, with no entry open); anywhere else the element stays
                // opaque, keeping this counter and the serializer's emission
                // in lockstep.
                groupStack[index].knownChildCount += 1
            case "EnableSearching" where currentEnableSearchingWasParsable:
                groupStack[index].knownChildCount += 1
            default:
                groupStack[index].unknownXML.append(
                    xml: xml,
                    insertionIndex: groupStack[index].knownChildCount
                )
            }

        case "Entry":
            guard let entry = currentEntry else { return }
            switch elementName {
            case "UUID", "IconID", "Tags", "Times", "String", "History":
                entry.knownChildCount += 1
                entry.attachmentAnchorChildCount += 1
            case "Binary" where currentBinaryRefWasParsable:
                // Counts toward opaque-XML sibling positioning (knownChildCount)
                // but not toward attachmentAnchorChildCount: the writer's
                // interleaving loop only advances past non-attachment known
                // elements, so attachment insertionIndex must live in that same
                // position space rather than including other attachments.
                entry.knownChildCount += 1
            default:
                entry.unknownXML.append(xml: xml, insertionIndex: entry.knownChildCount)
            }

        case "History":
            guard let entry = currentEntry else { return }
            switch elementName {
            case "Entry":
                entry.historyKnownChildCount += 1
            default:
                entry.unknownXML.append(
                    xml: xml,
                    path: ["History"],
                    insertionIndex: entry.historyKnownChildCount
                )
            }

        case "Times":
            switch grandparentName {
            case "Entry":
                guard let entry = currentEntry else { return }
                switch elementName {
                case "CreationTime", "LastModificationTime":
                    entry.timesKnownChildCount += 1
                case "LocationChanged" where currentLocationChangedWasParsable:
                    entry.timesKnownChildCount += 1
                default:
                    entry.unknownXML.append(
                        xml: xml,
                        path: ["Times"],
                        insertionIndex: entry.timesKnownChildCount
                    )
                }

            case "Group":
                guard let index = groupStack.indices.last else { return }
                switch elementName {
                case "CreationTime", "LastModificationTime":
                    groupStack[index].timesKnownChildCount += 1
                case "LocationChanged" where currentLocationChangedWasParsable:
                    groupStack[index].timesKnownChildCount += 1
                default:
                    groupStack[index].unknownXML.append(
                        xml: xml,
                        path: ["Times"],
                        insertionIndex: groupStack[index].timesKnownChildCount
                    )
                }

            default:
                break
            }

        default:
            break
        }
    }

    /// Splits a stored `<Tags>` value the way KeePass reads it: on `,` and
    /// `;`, trimming each piece and dropping empties — no deduplication and
    /// no reordering, so the source file's list (duplicates included)
    /// round-trips verbatim. Shared by the entry and group paths; this is
    /// deliberately NOT `TagNormalizer`, whose first-occurrence dedupe is an
    /// edit-side policy that would rewrite parsed data at read time.
    private static func splitStoredTags(_ trimmedText: String) -> [String] {
        trimmedText.components(separatedBy: CharacterSet([",", ";"])).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private static let nullUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))

    private func parseKPUUID(_ string: String) -> UUID? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 16 else { return nil }
        let uuid = data.withUnsafeBytes { ptr -> UUID in
            UUID(uuid: ptr.loadUnaligned(as: uuid_t.self))
        }
        // Null UUID means "not configured"
        return uuid == Self.nullUUID ? nil : uuid
    }

    /// Seconds from Foundation's reference date (2001-01-01 UTC) to the KeePass
    /// epoch (0001-01-01 UTC).  This equals −730 485 days × 86 400 s/day, i.e.
    /// 2 000 Gregorian years containing 485 leap years — matching .NET
    /// `DateTime`'s epoch that the KDBX binary timestamp format is based on.
    private static let kpEpochOffset: TimeInterval = -63_113_904_000

    private func parseKPDate(_ string: String) -> Date? {
        // KDBX4 stores timestamps as 8 bytes of little-endian seconds since
        // year 0001, base64-encoded (always 12 characters with padding).
        // Try this form first — base64 strings can legitimately contain the
        // characters 'T' and '-', so a substring check is not a reliable way
        // to distinguish binary from ISO-8601 form.
        if string.count == 12, let data = Data(base64Encoded: string), data.count == 8 {
            let seconds = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).littleEndian }
            return Date(timeIntervalSinceReferenceDate: Self.kpEpochOffset + TimeInterval(seconds))
        }
        // KDBX 3.x and some KDBX 4 writers use ISO-8601 text form.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Entry Builder

private class EntryBuilder {
    var uuid: UUID?
    var title = ""
    var username = ""
    var password = ""
    var url = ""
    var notes = ""
    var iconID = 0
    var customIconUUID: UUID?
    var tags: [String] = []
    var hasTagsElement = false
    var customFields: [String: String] = [:]
    var customFieldOrder: [String] = []
    var protectedStringKeys: Set<String> = []
    var otpURL: String?
    var creationTime: Date?
    var lastModificationTime: Date?
    var expires = false
    var expiryTime: Date?
    var locationChanged: Date?
    var history: [KPEntry] = []
    var unknownXML = OpaqueXMLNodes.empty
    var knownChildCount = 0
    /// Count of non-`Binary` known children seen so far, i.e. the same
    /// position space the writer's `serializeEntry` counter occupies (it
    /// never advances for attachments). Used as `KPAttachment.insertionIndex`
    /// so re-serialization interleaves `<Binary>` at its original position
    /// without attachments polluting each other's recorded index the way a
    /// shared counter would.
    var attachmentAnchorChildCount = 0
    var timesKnownChildCount = 0
    var historyKnownChildCount = 0
    var attachments: [KPAttachment] = []

    func build(sessionKey: SymmetricKey) -> KPEntry {
        let encryptedPassword = (try? EncryptedValue.encrypt(password, using: sessionKey)) ?? .empty
        let totpConfig = buildTOTPConfig(sessionKey: sessionKey)
        // Only the field that actually backs the TOTP config is managed by
        // the serializer; other otp-named fields must stay in customFields
        // so they round-trip.
        let keeOTPFieldName = totpConfig?.keeOTPSource?.fieldName
        // Divert the PEM out of customFields and seal it so the plaintext does
        // not outlive lock. Only the canonical spelling carries a PEM — the
        // legacy Strongbox/KeePassXC aliases rename other fields (see
        // PasskeyCredential).
        let passkeyPrivateKey = customFields[PasskeyCredential.privateKeyPEMKey].map {
            (try? EncryptedValue.encrypt($0, using: sessionKey)) ?? .empty
        }
        return KPEntry(
            id: uuid ?? UUID(),
            title: title,
            username: username,
            password: encryptedPassword,
            url: url,
            notes: notes,
            iconID: iconID,
            customIconUUID: customIconUUID,
            tags: tags,
            hasTagsElement: hasTagsElement,
            customFields: customFields.filter {
                !$0.key.hasPrefix("TimeOtp-") && $0.key != "TOTP Settings" && $0.key != "TOTP Seed"
                    && $0.key != keeOTPFieldName
                    && $0.key != PasskeyCredential.privateKeyPEMKey
            },
            customFieldOrder: customFieldOrder,
            passkeyPrivateKey: passkeyPrivateKey,
            totpConfig: totpConfig,
            otpURL: otpURL,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            expires: expires,
            expiryTime: expiryTime,
            locationChanged: locationChanged,
            history: history,
            unknownXML: unknownXML,
            protectedStringKeys: protectedStringKeys,
            attachments: attachments
        )
    }

    private func buildTOTPConfig(sessionKey: SymmetricKey) -> TOTPConfig? {
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
