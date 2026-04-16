import CryptoKit
import Foundation

/// Processes KeePass key files into 32-byte keys.
///
/// Supports all 4 formats (tried in order):
/// 1. Binary — exactly 32 bytes raw
/// 2. Hex — exactly 64 ASCII hex characters → 32 bytes
/// 3. XML — v1.0 (base64) or v2.0 (hex + hash verify)
/// 4. Fallback — SHA-256 of entire file contents
enum KeyFileProcessor {
    enum KeyFileError: Error, LocalizedError {
        case emptyKeyFile
        case xmlKeyDataInvalid
        case xmlHashMismatch

        var errorDescription: String? {
            switch self {
            case .emptyKeyFile: "Key file is empty"
            case .xmlKeyDataInvalid: "Key file XML contains invalid key data"
            case .xmlHashMismatch: "Key file hash verification failed — file may be corrupted"
            }
        }
    }

    /// Process key file data into a 32-byte key, trying formats in KeePass order.
    static func processKeyFile(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw KeyFileError.emptyKeyFile }

        // 1. Exactly 32 bytes → raw binary key
        if let result = tryBinaryFormat(data) { return result }

        // 2. Exactly 64 hex chars → decode to 32 bytes
        if let result = tryHexFormat(data) { return result }

        // 3. XML key file (v1.0 or v2.0)
        if let result = try tryXMLFormat(data) { return result }

        // 4. Fallback: SHA-256 of entire file
        return hashFallback(data)
    }

    // MARK: - Format Handlers

    static func tryBinaryFormat(_ data: Data) -> Data? {
        guard data.count == 32 else { return nil }
        return data
    }

    static func tryHexFormat(_ data: Data) -> Data? {
        guard data.count == 64 else { return nil }

        // Must be valid ASCII hex characters
        guard let hexString = String(data: data, encoding: .ascii) else { return nil }
        let trimmed = hexString.trimmingCharacters(in: .newlines)
        guard trimmed.count == 64 else { return nil }

        return dataFromHex(trimmed)
    }

    static func tryXMLFormat(_ data: Data) throws -> Data? {
        // Quick check: does it look like XML?
        let prefix = data.prefix(256)
        guard let prefixStr = String(data: prefix, encoding: .utf8),
              prefixStr.contains("<?xml") || prefixStr.contains("<KeyFile") else {
            return nil
        }

        let delegate = KeyFileXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse(), delegate.foundKeyData else { return nil }

        if delegate.version == "2.0" {
            return try processV2KeyFile(delegate)
        } else {
            return try processV1KeyFile(delegate)
        }
    }

    static func hashFallback(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - XML Processing

    private static func processV1KeyFile(_ delegate: KeyFileXMLParserDelegate) throws -> Data? {
        // v1.0: Data element contains base64-encoded 32-byte key
        let trimmed = delegate.dataContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Data(base64Encoded: trimmed), keyData.count == 32 else {
            throw KeyFileError.xmlKeyDataInvalid
        }
        return keyData
    }

    private static func processV2KeyFile(_ delegate: KeyFileXMLParserDelegate) throws -> Data? {
        // v2.0: Data element contains hex-encoded 32-byte key (whitespace allowed)
        let hex = delegate.dataContent.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        guard let keyData = dataFromHex(hex), keyData.count == 32 else {
            throw KeyFileError.xmlKeyDataInvalid
        }

        // Verify hash attribute if present
        if let hashAttr = delegate.dataHashAttribute {
            let computedHash = Data(SHA256.hash(data: keyData))
            let expectedPrefix = dataFromHex(hashAttr)
            guard let expectedPrefix, computedHash.prefix(expectedPrefix.count) == expectedPrefix else {
                throw KeyFileError.xmlHashMismatch
            }
        }

        return keyData
    }

    // MARK: - Hex Utilities

    private static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }

        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

// MARK: - XML Parser Delegate

private final class KeyFileXMLParserDelegate: NSObject, XMLParserDelegate {
    var version: String = ""
    var dataContent: String = ""
    var dataHashAttribute: String?
    var foundKeyData = false

    private var currentElement: String = ""
    private var currentText: String = ""
    private var inMeta = false
    private var inKey = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "Meta": inMeta = true
        case "Key": inKey = true
        case "Data":
            if inKey {
                dataHashAttribute = attributes["Hash"]
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "Meta": inMeta = false
        case "Key": inKey = false
        case "Version":
            if inMeta {
                version = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "Data":
            if inKey {
                dataContent = currentText
                foundKeyData = true
            }
        default: break
        }
    }
}
