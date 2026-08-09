import Foundation

/// Append-only breadcrumb log for diagnosing AutoFill request flows on a
/// development device. DEBUG-only; release builds compile every call to a
/// no-op. Lines carry event names, flags, and counts — never entry data,
/// URLs, or secrets.
///
/// The log lives at the App Group container root (`autofill-diagnostics.log`)
/// so a paired Mac can pull it after a reproduction:
/// `xcrun devicectl device copy from --domain-type appGroupDataContainer
///  --domain-identifier group.com.keevault.shared --source autofill-diagnostics.log`
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
            .appendingPathComponent("autofill-diagnostics.log")
    }

    static func log(_ event: String) {
        let line = "\(timestampFormatter.string(from: Date())) [\(ProcessInfo.processInfo.processName)] \(event)\n"
        queue.async { append(line) }
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
    #endif
}
