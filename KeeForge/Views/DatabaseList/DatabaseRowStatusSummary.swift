import Foundation

/// What a database row says about its database, in display order: the badges
/// beside its name and the notices below it.
struct DatabaseRowStatusSummary: Equatable {
    enum Badge: Equatable {
        case readOnly
        case quickLaunch
        case uploadPending
    }

    enum Notice: Equatable {
        case uploadConflicts(Int)
        case waitingToUpload(Int)
        case cloudWarning(String)
        case documentsFileMissing
        case fileUnavailable
        case cacheUnavailable

        var text: String {
            switch self {
            case .uploadConflicts(let count):
                String(localized: "\(count) pending upload conflicts")
            case .waitingToUpload(let count):
                String(localized: "\(count) changes waiting to upload")
            case .cloudWarning(let text):
                text
            case .documentsFileMissing:
                String(localized: "File removed from KeeForge’s folder")
            case .fileUnavailable:
                String(localized: "File unavailable")
            case .cacheUnavailable:
                String(localized: "Cache unavailable")
            }
        }
    }

    let badges: [Badge]
    let notices: [Notice]

    init(isReadOnly: Bool, isQuickLaunch: Bool, status: DatabaseRowStatus) {
        var badges: [Badge] = []
        if isReadOnly { badges.append(.readOnly) }
        if isQuickLaunch { badges.append(.quickLaunch) }
        if status.pendingUploadCount > 0 { badges.append(.uploadPending) }
        self.badges = badges

        var notices: [Notice] = []
        if status.pendingUploadConflictCount > 0 {
            notices.append(.uploadConflicts(status.pendingUploadConflictCount))
        } else {
            if status.pendingUploadCount > 0 {
                notices.append(.waitingToUpload(status.pendingUploadCount))
            }
            if let warningText = status.cloudState?.warningText {
                notices.append(.cloudWarning(warningText))
            }
        }
        if status.isDocumentsFileMissing {
            notices.append(.documentsFileMissing)
        } else if status.hasAccessIssue {
            notices.append(status.cloudState == nil ? .fileUnavailable : .cacheUnavailable)
        }
        self.notices = notices
    }
}
