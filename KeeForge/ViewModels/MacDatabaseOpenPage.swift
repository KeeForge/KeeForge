#if os(macOS)
import Foundation

/// Which page a database window shows until it unlocks: the unlock form
/// (with a card for a failure the form can fix), the opening steps, or a
/// recovery page for a failure another password cannot fix.
enum MacDatabaseOpenPage: Equatable {
    struct FailureCard: Equatable {
        let title: String
        let summary: String
        let code: String
        /// A Locate not yet confirmed by an unlock may have picked the wrong file.
        var offersLocate = false
    }

    struct Opening: Equatable {
        let steps: [DatabaseOpeningSteps.Step]
        let status: String
        let canCancel: Bool
    }

    struct OpeningProgress: Equatable {
        let step: DatabaseViewModel.OpeningStep
        let syncProgress: Double?
        let syncReachedCloud: Bool
        let status: String
        let canCancel: Bool
    }

    enum RecoverySymbol: Equatable {
        case missingFile
        case fileAccess
        case server
        case account
        case unsupportedFormat
        case unexpected
    }

    enum RecoveryAction: Equatable {
        case locateDatabaseFile
        case reconnect(CloudProviderKind)
        case tryAgain
        case removeFromList
    }

    struct RecoveryPage: Equatable {
        let symbol: RecoverySymbol
        let title: String
        let subtitle: String
        let summary: String
        let actions: [RecoveryAction]
        let errorCode: String
    }

    case form(card: FailureCard?, footer: String?)
    case opening(Opening)
    case recovery(RecoveryPage)
    /// A reference with no file, bookmark or cached copy to open.
    case unavailable

    private static let reconnectCodes: Set<String> = ["cloud.not_authenticated", "cloud.write_scope_required"]

    /// `nil` once the session is open.
    @MainActor
    static func make(for session: DatabaseViewModel) -> MacDatabaseOpenPage? {
        make(
            state: session.state,
            reference: session.databaseReference,
            hasSavedFile: session.hasSavedFile,
            canRelink: session.canRelinkDatabaseFile,
            lastLockCause: session.lastLockCause,
            opening: OpeningProgress(
                step: session.openingStep,
                syncProgress: session.cloudSyncProgress,
                syncReachedCloud: session.openingSyncReachedCloud,
                status: session.unlockStatusMessage,
                canCancel: session.canCancelUnlockAttempt
            )
        )
    }

    static func make(
        state: DatabaseViewModel.State,
        reference: DatabaseReference,
        hasSavedFile: Bool,
        canRelink: Bool,
        lastLockCause: DatabaseViewModel.LockCause?,
        opening: OpeningProgress
    ) -> MacDatabaseOpenPage? {
        switch state {
        case .unlocked:
            return nil
        case .unlocking:
            return .opening(Opening(
                steps: DatabaseOpeningSteps.make(
                    step: opening.step,
                    isCloudBacked: reference.isCloudBacked,
                    provider: reference.cloudProviderKind,
                    progress: opening.syncProgress,
                    syncReachedCloud: opening.syncReachedCloud
                ),
                status: opening.status,
                canCancel: opening.canCancel
            ))
        case .locked:
            guard hasSavedFile else { return .unavailable }
            return .form(card: nil, footer: footer(for: lastLockCause))
        case .error(let failure) where failure.canRetryUnlock:
            let card = FailureCard(title: failure.title, summary: failure.summary, code: failure.errorCode,
                                   offersLocate: canRelink)
            return .form(card: card, footer: footer(for: lastLockCause))
        case .error(let failure):
            return .recovery(recoveryPage(for: failure, reference: reference, canRelink: canRelink))
        }
    }

    /// Only an inactivity lock is explained; a disabled timeout has no length to state.
    static func footer(for cause: DatabaseViewModel.LockCause?) -> String? {
        guard case .inactivity(let timeout) = cause else { return nil }
        switch timeout {
        case .thirtySeconds: return String(localized: "Locked automatically after 30 seconds of inactivity")
        case .oneMinute: return String(localized: "Locked automatically after 1 minute of inactivity")
        case .fiveMinutes: return String(localized: "Locked automatically after 5 minutes of inactivity")
        case .never: return nil
        }
    }

    private static func recoveryPage(
        for failure: DatabaseOpenFailure,
        reference: DatabaseReference,
        canRelink: Bool
    ) -> RecoveryPage {
        var actions: [RecoveryAction] = []
        if canRelink { actions.append(.locateDatabaseFile) }
        if reconnectCodes.contains(failure.errorCode), let provider = reference.cloudProviderKind {
            actions.append(.reconnect(provider))
        }
        actions += [.tryAgain, .removeFromList]
        return RecoveryPage(
            symbol: symbol(for: failure),
            title: failure.title,
            subtitle: MacLockedDatabaseSummary(reference: reference, lastOpened: nil).recoverySubtitle,
            summary: failure.summary,
            actions: actions,
            errorCode: failure.errorCode
        )
    }

    private static func symbol(for failure: DatabaseOpenFailure) -> RecoverySymbol {
        switch failure.errorCode {
        case "file.not_found", "file.in_recently_deleted", "cloud.file_not_found":
            return .missingFile
        case "file.read_timeout", "cloud.network_unavailable", "cloud.service_unavailable":
            return .server
        case "cloud.not_authenticated", "cloud.write_scope_required", "cloud.authentication_cancelled",
             "cloud.invalid_configuration":
            return .account
        default:
            break
        }
        switch failure.category {
        case .fileAccess: return .fileAccess
        case .unsupportedFormat: return .unsupportedFormat
        case .authentication, .biometric, .cloud, .hardwareKey, .unexpected: return .unexpected
        }
    }
}
#endif
