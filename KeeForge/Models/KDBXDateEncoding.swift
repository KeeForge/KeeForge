import Foundation

extension Date {
    /// Seconds from Foundation's reference date (2001-01-01 UTC) to the KeePass
    /// epoch (0001-01-01 UTC). Must stay in sync with the constant in
    /// `KDBXParser`.
    private static let kdbxEpochOffset: TimeInterval = -63_113_904_000

    /// The date as KDBX 4 stores it: little-endian Int64 seconds since
    /// 0001-01-01 UTC, base64-encoded.
    ///
    /// Single-sourced for the same reason as `UUID.kdbxBase64String`: the
    /// serializer writes structured timestamps from here, and
    /// `EntryExpiryXML` builds the preserved `<ExpiryTime>` fragment from it.
    var kdbxBase64String: String {
        var leSeconds = kdbxSeconds.littleEndian
        return withUnsafeBytes(of: &leSeconds) { Data($0).base64EncodedString() }
    }

    /// Reads only the KDBX 4 binary form; text timestamps return nil.
    init?(kdbxBase64String string: String) {
        guard let data = Data(base64Encoded: string), data.count == 8 else { return nil }
        let seconds = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).littleEndian }
        self.init(timeIntervalSinceReferenceDate: Self.kdbxEpochOffset + TimeInterval(seconds))
    }

    /// This date cut to the whole second `kdbxBase64String` keeps, which is
    /// what a parse of the written element reads back.
    var kdbxStoredDate: Date {
        Date(timeIntervalSinceReferenceDate: Self.kdbxEpochOffset + TimeInterval(kdbxSeconds))
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
