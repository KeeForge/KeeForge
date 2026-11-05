import Foundation

/// The one line the iPhone and iPad database cards and tiles say about a
/// database, most urgent first: a notice from `DatabaseRowStatusSummary`,
/// then read-only, then when it was last synced or opened.
struct DatabaseStatusLine: Equatable {
    let text: String
    let systemImage: String
    let needsAttention: Bool
    /// Set where a UI test finds the line by its identifier.
    let accessibilityIdentifier: String?

    init?(reference: DatabaseReference, status: DatabaseRowStatus, lastOpenedDescription: String?) {
        let summary = DatabaseRowStatusSummary(
            isReadOnly: reference.isReadOnly,
            isQuickLaunch: reference.isQuickLaunch,
            status: status
        )
        if let notice = summary.notices.first {
            text = notice.text
            systemImage = Self.systemImage(for: notice)
            needsAttention = true
            accessibilityIdentifier = notice == .documentsFileMissing ? "database-row.documents-file-missing" : nil
        } else if reference.isReadOnly {
            text = String(localized: "Read-only")
            systemImage = "lock"
            needsAttention = false
            accessibilityIdentifier = nil
        } else if let lastSyncedAt = reference.cloudSyncMetadata?.lastSyncedAt {
            text = String(localized: "Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))")
            systemImage = "icloud"
            needsAttention = false
            accessibilityIdentifier = nil
        } else if let lastOpenedDescription {
            text = lastOpenedDescription
            systemImage = "clock"
            needsAttention = false
            accessibilityIdentifier = "database-row.last-opened"
        } else {
            return nil
        }
    }

    private static func systemImage(for notice: DatabaseRowStatusSummary.Notice) -> String {
        switch notice {
        case .waitingToUpload: "arrow.up.circle"
        case .cloudWarning: "exclamationmark.icloud"
        case .uploadConflicts, .documentsFileMissing, .fileUnavailable, .cacheUnavailable: "exclamationmark.triangle"
        }
    }
}
