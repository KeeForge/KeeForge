import AuthenticationServices
import Foundation

struct CloudDatabaseSelection: Hashable, Sendable {
    let provider: String
    let account: CloudAccount
    let file: CloudFile
}

protocol CloudProvider: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var iconName: String { get }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount

    @MainActor
    func cancelPendingAuthentication()

    func isAuthenticated(accountId: String) -> Bool
    func signOut(accountId: String)

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile]
    /// Writes the remote file to `localURL` and reports the metadata of the
    /// bytes actually written — the pre-download rev goes stale the moment
    /// someone else writes mid-transfer. `nil` where the transport cannot say:
    /// OneDrive's `/content` redirects to a pre-authenticated URL carrying no
    /// item tag, and a WebDAV `GET` may answer without an `ETag`.
    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata?
    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata
    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata
    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile
}

extension CloudProvider {
    @MainActor
    func cancelPendingAuthentication() {}

    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        throw CloudProviderError.invalidConfiguration
    }
}

enum CloudProviderError: LocalizedError, Equatable, CloudSyncIssueConvertible {
    case invalidConfiguration
    case authenticationCancelled
    case notAuthenticated
    case networkUnavailable
    case fileNotFound
    case conflict(remoteRev: String?)
    case writeScopeRequired
    case rateLimited
    case serviceUnavailable
    case insufficientSpace
    case permissionDenied
    case invalidName
    case unknown(String)

    /// The persistable form of this error. The user-facing wording lives on
    /// `CloudSyncIssue`, so a message shown live and one replayed out of the
    /// database list cannot drift apart.
    var syncIssue: CloudSyncIssue {
        switch self {
        case .invalidConfiguration: .invalidConfiguration
        case .authenticationCancelled: .authenticationCancelled
        case .notAuthenticated: .notAuthenticated
        case .networkUnavailable: .networkUnavailable
        case .fileNotFound: .fileNotFound
        case .conflict: .conflict
        case .writeScopeRequired: .writeScopeRequired
        case .rateLimited: .rateLimited
        case .serviceUnavailable: .serviceUnavailable
        case .insufficientSpace: .insufficientSpace
        case .permissionDenied: .permissionDenied
        case .invalidName: .invalidName
        case .unknown(let message): .unknown(message)
        }
    }

    var errorDescription: String? {
        syncIssue.localizedDescription
    }

    static func message(for error: Error) -> String {
        issue(for: error).localizedDescription
    }

    /// Maps any sync failure onto the code that gets persisted. An error the
    /// app did not define keeps its own description — that text is the best
    /// available for it, and is the one case that cannot be re-localized
    /// later.
    static func issue(for error: Error) -> CloudSyncIssue {
        if let convertible = error as? CloudSyncIssueConvertible {
            return convertible.syncIssue
        }
        return .unknown((error as NSError).localizedDescription)
    }

    /// Whether `error` means "no working server on the other end" — the
    /// device is offline, or the service answered 502/503/504 — so a cached
    /// copy is the calm, expected fallback rather than an error to alarm over.
    static func isLikelyOffline(_ error: Error) -> Bool {
        if let cloudError = error as? CloudProviderError,
           cloudError == .networkUnavailable || cloudError == .serviceUnavailable {
            return true
        }

        // Only transport failures that plausibly mean "no connectivity" count as
        // offline; TLS errors, cancellations, and other NSURLErrorDomain codes
        // must keep surfacing as real errors.
        let offlineCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
        ]
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && offlineCodes.contains(nsError.code)
    }
}
