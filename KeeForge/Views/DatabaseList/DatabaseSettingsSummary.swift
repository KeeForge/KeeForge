import Foundation

/// The one-line state each row of the Database Details hub shows under its
/// title, and the file facts in its header.
enum DatabaseSettingsSummary {
    static func header(filename: String, fileInfo: DatabaseFileInfo?) -> String {
        SettingsSummaryText.joined([
            filename,
            fileInfo?.summary?.formatDisplayName,
            fileInfo?.fileSizeBytes?.formatted(.byteCount(style: .file)),
        ])
    }

    static func general(isQuickLaunch: Bool, isReadOnly: Bool) -> String {
        SettingsSummaryText.joined([
            isQuickLaunch ? String(localized: "Quick Launch") : nil,
            isReadOnly ? String(localized: "Read-only") : String(localized: "Editing allowed"),
        ])
    }

    /// `destinationGroupName` is known only while the database is unlocked.
    static func autoFill(isEnabled: Bool, destinationGroupName: String?) -> String {
        guard isEnabled else { return String(localized: "Not included") }
        return SettingsSummaryText.joined([
            String(localized: "Included"),
            destinationGroupName.map { String(localized: "Saves to \($0)") },
        ])
    }

    static func masterKey(keyFileFilename: String?, usesHardwareKey: Bool) -> String {
        SettingsSummaryText.joined([
            usesHardwareKey ? String(localized: "YubiKey") : nil,
            keyFileFilename ?? String(localized: "No key file"),
        ])
    }

    static func encryption(_ summary: KDBXFileSummary?) -> String? {
        guard let summary else { return nil }
        return SettingsSummaryText.joined([summary.cipherDisplayName, summary.keyDerivationDisplayName])
    }

    static func cloudSync(_ cloudState: CloudRowState, lastSyncedAt: Date?) -> String {
        let status = cloudState.warningText
            ?? lastSyncedAt.map { String(localized: "Last synced \($0.formatted(.relative(presentation: .named)))") }
            ?? String(localized: "Healthy")
        return SettingsSummaryText.joined([cloudState.providerName, status])
    }

    static func backups(_ backups: [DatabaseExportService.Backup]) -> String {
        guard backups.isEmpty == false else { return String(localized: "No backups on this device.") }
        let latest = backups.compactMap(\.createdAt).max()
        return SettingsSummaryText.joined([
            String(localized: "\(backups.count) backups"),
            latest.map { String(localized: "Latest: \($0.formatted(.relative(presentation: .named)))") },
        ])
    }
}
