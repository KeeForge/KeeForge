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
