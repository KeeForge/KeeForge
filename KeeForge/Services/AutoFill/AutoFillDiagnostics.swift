import Foundation

/// Append-only breadcrumb log for diagnosing AutoFill request flows on a
/// development device. DEBUG-only; release builds compile every call to a
/// no-op. Lines carry event names, flags, and counts — never entry data,
/// URLs, or secrets.
///
/// The log lives at `Library/autofill-diagnostics.log` in the App Group
/// container — `Library` because devicectl's file service only reaches
/// Library, Documents, and tmp — so a paired Mac can pull it after a
/// reproduction:
/// `xcrun devicectl device copy from --domain-type appGroupDataContainer
///  --domain-identifier group.com.keevault.shared
///  --source Library/autofill-diagnostics.log`
enum AutoFillDiagnostics {
    #if DEBUG
    private static let queue = DispatchQueue(label: "com.keevault.autofill-diagnostics", qos: .utility)
    private static let maxBytes = 128 * 1024

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID)?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("autofill-diagnostics.log")
    }

    static func log(_ event: String) {
        let line = "\(timestampFormatter.string(from: Date())) [\(ProcessInfo.processInfo.processName)] \(event)\n"
        queue.async { append(line) }
    }

    /// Folds a log an earlier build wrote at the container root (which
    /// devicectl cannot read) into the `Library` location. App launch calls
    /// this so breadcrumbs recorded before the move stay retrievable.
    static func migrateLegacyLogLocation() {
        queue.async {
            let fileManager = FileManager.default
            guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID) else { return }
            let legacy = container.appendingPathComponent("autofill-diagnostics.log")
            guard let url = fileURL, fileManager.fileExists(atPath: legacy.path) else { return }
            var combined = (try? Data(contentsOf: legacy)) ?? Data()
            combined.append((try? Data(contentsOf: url)) ?? Data())
            try? combined.write(to: url, options: .atomic)
            try? fileManager.removeItem(at: legacy)
        }
    }

    private static func append(_ line: String) {
        guard let url = fileURL, let data = line.data(using: .utf8) else { return }
        var existing = (try? Data(contentsOf: url)) ?? Data()
        if existing.count > maxBytes {
            existing = existing.suffix(maxBytes / 2)
        }
        existing.append(data)
        try? existing.write(to: url, options: .atomic)
    }
    #else
    static func log(_ event: String) {}
    static func migrateLegacyLogLocation() {}
    #endif
}
