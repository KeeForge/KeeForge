import Foundation

extension UUID {
    /// The UUID as KDBX stores it: the 16 raw bytes, base64-encoded.
    ///
    /// Single-sourced because two encoders would be free to drift on a detail
    /// the format does not forgive — the serializer writes structured elements
    /// from here, and `DatabaseDraft` builds the preserved `<CustomIconUUID>`
    /// fragment from the same bytes.
    var kdbxBase64String: String {
        var raw = uuid
        return withUnsafeBytes(of: &raw) { Data($0).base64EncodedString() }
    }

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
