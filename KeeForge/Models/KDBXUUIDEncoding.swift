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
}
