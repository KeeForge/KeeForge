import Foundation

extension UUID {
    /// The UUID as KDBX stores it: the 16 raw bytes, base64-encoded.
    public var kdbxBase64String: String {
        var raw = uuid
        return withUnsafeBytes(of: &raw) { Data($0).base64EncodedString() }
    }

    static let kdbxNone = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Reads element text: base64 of exactly 16 bytes, surrounding whitespace
    /// allowed. The all-zero UUID is returned as is.
    init?(kdbxText text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 16 else { return nil }
        self = data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

extension Date {
    /// Seconds from Foundation's reference date (2001-01-01 UTC) to the KDBX
    /// epoch (0001-01-01 UTC, .NET `DateTime`): 730,485 days.
    private static let kdbxEpochOffset: TimeInterval = -63_113_904_000

    /// The date as KDBX 4 stores it: little-endian Int64 seconds since
    /// 0001-01-01 UTC, base64-encoded. Fractions are cut; out-of-range dates
    /// saturate.
    public var kdbxBase64String: String {
        var leSeconds = kdbxSeconds.littleEndian
        return withUnsafeBytes(of: &leSeconds) { Data($0).base64EncodedString() }
    }

    /// Reads only the KDBX 4 binary form.
    public init?(kdbxBase64String string: String) {
        guard let data = Data(base64Encoded: string), data.count == 8 else { return nil }
        let seconds = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).littleEndian }
        self.init(timeIntervalSinceReferenceDate: Self.kdbxEpochOffset + TimeInterval(seconds))
    }

    /// This date cut to the whole second `kdbxBase64String` keeps.
    public var kdbxStoredDate: Date {
        Date(timeIntervalSinceReferenceDate: Self.kdbxEpochOffset + TimeInterval(kdbxSeconds))
    }

    /// Reads element text in either form: KDBX 4 binary, or the ISO 8601 text
    /// of KDBX 3.1 and some KDBX 4 writers. Surrounding whitespace is allowed.
    init?(kdbxText text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked first by shape: base64 can contain the `T` and `-` of ISO text.
        if trimmed.count == 12, let date = Date(kdbxBase64String: trimmed) {
            self = date
            return
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed) else {
            return nil
        }
        self = date
    }

    private var kdbxSeconds: Int64 {
        let interval = timeIntervalSinceReferenceDate - Self.kdbxEpochOffset
        if interval.isNaN {
            return 0
        } else if interval >= Double(Int64.max) {
            return .max
        } else if interval <= Double(Int64.min) {
            return .min
        }
        return Int64(interval)
    }
}

extension KDBXDocument.RecycleBin {
    /// The stored UUID.
    var uuid: UUID {
        switch self {
        case .unset: .kdbxNone
        case .group(let uuid): uuid
        }
    }
}

extension KDBXDocument.InheritableBool {
    /// `True`/`False`/`null`, case-insensitive, whitespace allowed.
    init?(xmlText: String) {
        switch xmlText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "null": self = .inherit
        case "true": self = .enabled
        case "false": self = .disabled
        default: return nil
        }
    }

    /// KeePass casing.
    var xmlText: String {
        switch self {
        case .inherit: "null"
        case .enabled: "True"
        case .disabled: "False"
        }
    }
}
