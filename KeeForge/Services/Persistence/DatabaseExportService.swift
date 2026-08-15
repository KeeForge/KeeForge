import Foundation

enum DatabaseExportError: Error, LocalizedError, Equatable, Sendable {
    case cloudCacheMissing
    case localFileUnavailable
    case backupMissing
    case readFailed

    var errorDescription: String? {
        switch self {
        case .cloudCacheMissing:
            String(localized: "KeeForge has no local copy of this database yet. Open it once while online, then try exporting again.")
        case .localFileUnavailable:
            String(localized: "The database file could not be found. Make sure it is still available in the Files app.")
        case .backupMissing:
            String(localized: "This backup is no longer available.")
        case .readFailed:
            String(localized: "The database file could not be read.")
        }
    }
}

/// Hands the raw encrypted bytes of a database (its current local copy, or one
/// of the app-container backups) to a Files export. Suggested filenames carry a
/// timestamp suffix so a save into the source folder never replaces the
/// original file.
enum DatabaseExportService {
    struct ExportPayload: Sendable {
        let data: Data
        let suggestedFilename: String
    }

    struct Backup: Identifiable, Sendable, Equatable {
        let url: URL
        /// Parsed from the `yyyyMMdd-HHmmss-uuuuuu.kdbx` filename (UTC); nil
        /// when the name does not match.
        let createdAt: Date?

        var id: URL { url }
    }

    private static let readTimeout: Duration = .seconds(10)

    static func exportCurrentCopy(
        for reference: DatabaseReference,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) async throws -> ExportPayload {
        let data = try await CoordinatedFileReader.performBlocking(timeout: readTimeout) {
            do {
                return try DatabaseFileAccess.withReadableURL(for: reference) { url in
                    try CoordinatedFileReader.readData(from: url)
                }
            } catch DatabaseFileAccess.ResolutionFailure.cloudCacheMissing {
                throw DatabaseExportError.cloudCacheMissing
            } catch DatabaseFileAccess.ResolutionFailure.localFileUnavailable {
                throw DatabaseExportError.localFileUnavailable
            } catch {
                throw DatabaseExportError.readFailed
            }
        }
        return ExportPayload(
            data: data,
            suggestedFilename: currentCopyFilename(for: reference, date: now, timeZone: timeZone)
        )
    }

    static func backups(for reference: DatabaseReference) -> [Backup] {
        DatabaseListStore.recentBackups(for: reference).map { url in
            Backup(url: url, createdAt: backupDate(fromFilename: url.lastPathComponent))
        }
    }

    static func exportBackup(
        _ backup: Backup,
        for reference: DatabaseReference,
        timeZone: TimeZone = .current
    ) async throws -> ExportPayload {
        let data = try await CoordinatedFileReader.performBlocking(timeout: readTimeout) {
            guard FileManager.default.fileExists(atPath: backup.url.path) else {
                throw DatabaseExportError.backupMissing
            }
            do {
                return try CoordinatedFileReader.readData(from: backup.url)
            } catch {
                throw DatabaseExportError.readFailed
            }
        }
        return ExportPayload(
            data: data,
            suggestedFilename: backupFilename(for: reference, backup: backup, timeZone: timeZone)
        )
    }

    // MARK: - Filenames

    static func currentCopyFilename(for reference: DatabaseReference, date: Date, timeZone: TimeZone = .current) -> String {
        "\(baseName(of: reference)) (KeeForge copy \(suffixTimestamp(for: date, timeZone: timeZone))).kdbx"
    }

    static func backupFilename(for reference: DatabaseReference, backup: Backup, timeZone: TimeZone = .current) -> String {
        let stem = baseName(of: reference)
        guard let createdAt = backup.createdAt else {
            return "\(stem) (backup \((backup.url.lastPathComponent as NSString).deletingPathExtension)).kdbx"
        }
        return "\(stem) (backup \(suffixTimestamp(for: createdAt, timeZone: timeZone))).kdbx"
    }

    /// Inverse of the savers' `backupFilename(for:)`: `yyyyMMdd-HHmmss-uuuuuu.kdbx` in UTC.
    static func backupDate(fromFilename filename: String) -> Date? {
        let stem = (filename as NSString).deletingPathExtension
        guard (filename as NSString).pathExtension.lowercased() == "kdbx" else { return nil }
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 8, parts[1].count == 6, parts[2].count == 6,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0].prefix(4)),
              let month = Int(parts[0].dropFirst(4).prefix(2)),
              let day = Int(parts[0].suffix(2)),
              let hour = Int(parts[1].prefix(2)),
              let minute = Int(parts[1].dropFirst(2).prefix(2)),
              let second = Int(parts[1].suffix(2)),
              let microseconds = Int(parts[2]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second,
            nanosecond: microseconds * 1_000
        )
        // Calendar silently rolls over-range fields (month 13, second 61)
        // into a real date, so only accept a lossless round trip.
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else {
            return nil
        }
        return date
    }

    private static func baseName(of reference: DatabaseReference) -> String {
        let filename = reference.filename
        if filename.lowercased().hasSuffix(".kdbx") {
            return String(filename.dropLast(5))
        }
        return filename
    }

    private static func suffixTimestamp(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: date)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
