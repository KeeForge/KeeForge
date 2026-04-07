import CryptoKit
import Foundation

struct KDBXXMLSerializer {
    enum SerializationError: Error {
        case invalidInnerStreamKey
    }

    private let rootGroup: KPGroup
    private let meta: KPMeta
    private let innerStreamKey: Data
    private let sessionKey: SymmetricKey

    private var chachaCounter: UInt32 = 0
    private var keystreamBlock = Data()
    private var keystreamBlockOffset = 0

    private static let xmlPrefix = Data([0xEF, 0xBB, 0xBF]) +
        Data("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n".utf8)

    init(rootGroup: KPGroup, meta: KPMeta, innerStreamKey: Data, sessionKey: SymmetricKey) {
        self.rootGroup = rootGroup
        self.meta = meta
        self.innerStreamKey = innerStreamKey
        self.sessionKey = sessionKey
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

        xml += try opaqueXML(from: meta.unknownXML, path: [], insertionIndex: knownChildCount)
        if meta.hasRecycleBinUUIDElement || meta.recycleBinUUID != nil {
            let recycleBinUUID = meta.recycleBinUUID
            xml += element("RecycleBinUUID", value: serializeUUID(recycleBinUUID))
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
        var knownChildCount = 0

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += element("UUID", value: serializeUUID(entry.id))
        knownChildCount += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += element("IconID", value: String(entry.iconID))
        knownChildCount += 1

        if !entry.tags.isEmpty {
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += element("Tags", value: escape(entry.tags.joined(separator: ",")))
            knownChildCount += 1
        }

        if entry.creationTime != nil || entry.lastModificationTime != nil || hasOpaqueTimes(entry.unknownXML) {
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try serializeTimes(
                creationTime: entry.creationTime,
                lastModificationTime: entry.lastModificationTime,
                unknownXML: entry.unknownXML
            )
            knownChildCount += 1
        }

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try serializeString(key: "Title", value: entry.title, isProtected: entry.protectedStringKeys.contains("Title"))
        knownChildCount += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try serializeString(key: "UserName", value: entry.username, isProtected: entry.protectedStringKeys.contains("UserName"))
        knownChildCount += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try serializeString(
            key: "Password",
            value: try entry.password.decrypt(using: sessionKey),
            isProtected: true
        )
        knownChildCount += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try serializeString(key: "URL", value: entry.url, isProtected: entry.protectedStringKeys.contains("URL"))
        knownChildCount += 1

        xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
        xml += try serializeString(key: "Notes", value: entry.notes, isProtected: entry.protectedStringKeys.contains("Notes"))
        knownChildCount += 1

        if let totpConfig = entry.totpConfig {
            let secret = try totpConfig.secret.decrypt(using: sessionKey)
            let totpFields = [
                ("TimeOtp-Secret-Base32", secret, true),
                ("TimeOtp-Period", String(totpConfig.period), false),
                ("TimeOtp-Length", String(totpConfig.digits), false),
                ("TimeOtp-Algorithm", totpConfig.algorithm.rawValue, false),
            ]

            for (key, value, isProtected) in totpFields {
                xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
                xml += try serializeString(key: key, value: value, isProtected: isProtected)
                knownChildCount += 1
            }
        }

        for key in entry.customFields.keys.sorted() {
            let value = entry.customFields[key] ?? ""
            xml += try opaqueXML(from: entry.unknownXML, path: [], insertionIndex: knownChildCount)
            xml += try serializeString(
                key: key,
                value: value,
                isProtected: entry.protectedStringKeys.contains(key)
            )
            knownChildCount += 1
        }

        xml += try trailingOpaqueXML(from: entry.unknownXML, path: [], knownChildCount: knownChildCount)
        xml += "</Entry>"
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

    private mutating func encryptProtectedValue(_ plaintext: String) throws -> String {
        guard innerChaChaKey.count == 32, innerChaChaNonce.count == 12 else {
            throw SerializationError.invalidInnerStreamKey
        }

        let input = Data(plaintext.utf8)
        var encrypted = Data()
        encrypted.reserveCapacity(input.count)

        for byte in input {
            encrypted.append(byte ^ nextKeystreamByte())
        }

        return encrypted.base64EncodedString()
    }

    private var streamCipherKey: Data {
        KDBXCrypto.sha512(innerStreamKey)
    }

    private var innerChaChaKey: Data {
        Data(streamCipherKey.prefix(32))
    }

    private var innerChaChaNonce: Data {
        Data(streamCipherKey[32..<44])
    }

    private mutating func nextKeystreamByte() -> UInt8 {
        if keystreamBlockOffset >= keystreamBlock.count {
            keystreamBlock = makeChaCha20Block(counter: chachaCounter)
            keystreamBlockOffset = 0
            chachaCounter &+= 1
        }

        let byte = keystreamBlock[keystreamBlockOffset]
        keystreamBlockOffset += 1
        return byte
    }

    private func makeChaCha20Block(counter: UInt32) -> Data {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574

        innerChaChaKey.withUnsafeBytes { pointer in
            for index in 0..<8 {
                state[4 + index] = pointer
                    .loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    .littleEndian
            }
        }

        state[12] = counter
        innerChaChaNonce.withUnsafeBytes { pointer in
            for index in 0..<3 {
                state[13 + index] = pointer
                    .loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    .littleEndian
            }
        }

        var working = state
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        for index in 0..<16 {
            working[index] = working[index] &+ state[index]
        }

        var block = Data(capacity: 64)
        for word in working {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                block.append(contentsOf: bytes)
            }
        }
        return block
    }

    private func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = (state[d] << 16) | (state[d] >> 16)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = (state[b] << 12) | (state[b] >> 20)
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = (state[d] << 8) | (state[d] >> 24)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = (state[b] << 7) | (state[b] >> 25)
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

        var raw = uuid.uuid
        return withUnsafeBytes(of: &raw) { bytes in
            Data(bytes).base64EncodedString()
        }
    }

    private func serializeDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
