import Foundation

// The base64 form KDBX XML stores is `UUID.kdbxBase64String` in KDBXXML.
extension UUID {
    /// The 32 uppercase hex digits of the raw bytes, no dashes — the form
    /// KeePass field references (`{REF:…@I:…}`) use to name an entry.
    var kdbxHexString: String {
        uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Parses the 32-hex form; dashes and case are tolerated.
    init?(kdbxHexString: String) {
        let hex = kdbxHexString.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        var dashed = ""
        for (offset, character) in hex.enumerated() {
            if [8, 12, 16, 20].contains(offset) { dashed.append("-") }
            dashed.append(character)
        }
        self.init(uuidString: dashed)
    }
}
