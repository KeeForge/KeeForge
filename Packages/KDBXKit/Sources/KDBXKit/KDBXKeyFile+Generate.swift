import CryptoKit
import Foundation
import Security

extension KDBXKeyFile {
    public static let generatedFileExtension = "keyx"

    /// A new key file in the KeePass XML 2.0 format, laid out as KeePass 2.x and KeePassXC
    /// write it: 32 random bytes as upper-case hex in groups of eight characters, and the
    /// first 4 bytes of their SHA-256 in the `Hash` attribute. The returned bytes are zeroed
    /// when their last holder releases them.
    public static func generate() throws -> Data {
        try generate { SecRandomCopyBytes(kSecRandomDefault, $0.count, &$0) }
    }

    static func generate(fillingRandomBytes fill: (inout [UInt8]) -> OSStatus) throws -> Data {
        var key = [UInt8](repeating: 0, count: 32)
        defer { SecureWipe.wipe(&key) }
        let status = fill(&key)
        guard status == errSecSuccess else {
            throw KDBXContainerWriter.WriteError.randomGenerationFailed(status)
        }

        // Reserved up front: growing the buffer would leave an unwiped copy behind.
        var file = [UInt8]()
        file.reserveCapacity(512)
        defer { SecureWipe.wipe(&file) }

        append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<KeyFile>\n\t<Meta>\n\t\t<Version>2.0</Version>\n\t</Meta>\n\t<Key>\n\t\t<Data Hash=\"", to: &file)
        for byte in SHA256.hash(data: key).prefix(4) {
            appendHex(byte, to: &file)
        }
        append("\">\n\t\t\t", to: &file)
        for index in key.indices {
            if index == 16 {
                append("\n\t\t\t", to: &file)
            } else if index > 0, index.isMultiple(of: 4) {
                append(" ", to: &file)
            }
            appendHex(key[index], to: &file)
        }
        append("\n\t\t</Data>\n\t</Key>\n</KeyFile>\n", to: &file)
        return SecureWipe.wipingData(copying: file)
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    private static func append(_ literal: StaticString, to file: inout [UInt8]) {
        literal.withUTF8Buffer { file.append(contentsOf: $0) }
    }

    private static func appendHex(_ byte: UInt8, to file: inout [UInt8]) {
        file.append(hexDigits[Int(byte >> 4)])
        file.append(hexDigits[Int(byte & 0x0F)])
    }
}
