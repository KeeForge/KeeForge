import CryptoKit
import Foundation

/// Creates key files in the KeePass XML 2.0 format (`.keyx`), laid out as KeePass 2.x and
/// KeePassXC write them: 32 random bytes as upper-case hex in groups of eight characters,
/// and the first 4 bytes of their SHA-256 in the `Hash` attribute.
public enum KeyFileGenerator {
    public static let fileExtension = "keyx"

    public static func makeKeyFile() throws -> Data {
        var key = try KDBXContainerWriter.randomData(count: 32)
        defer { SecureWipe.wipe(&key) }

        let hash = hex(Data(SHA256.hash(data: key)).prefix(4))
        let groups = stride(from: 0, to: key.count, by: 4).map { offset in
            hex(key[(key.startIndex + offset)..<(key.startIndex + offset + 4)])
        }
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile>
        \t<Meta>
        \t\t<Version>2.0</Version>
        \t</Meta>
        \t<Key>
        \t\t<Data Hash="\(hash)">
        \t\t\t\(groups[0..<4].joined(separator: " "))
        \t\t\t\(groups[4..<8].joined(separator: " "))
        \t\t</Data>
        \t</Key>
        </KeyFile>

        """
        return Data(xml.utf8)
    }

    private static func hex(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
