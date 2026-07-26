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
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
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

enum CloudProviderError: LocalizedError, Equatable {
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

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "Cloud sync is not configured for this build.")
        case .authenticationCancelled:
            String(localized: "Authentication was cancelled.")
        case .notAuthenticated:
            String(localized: "Please reconnect this cloud account.")
        case .networkUnavailable:
            String(localized: "No network connection. Using the cached copy if available.")
        case .fileNotFound:
            String(localized: "The remote database could not be found.")
        case .conflict:
            String(localized: "This database changed in the cloud. Reload before saving again.")
        case .writeScopeRequired:
            String(localized: "Reconnect this cloud account to save changes.")
        case .rateLimited:
            String(localized: "The cloud service is busy right now. Try again in a moment.")
        case .serviceUnavailable:
            String(localized: "The cloud service is temporarily unavailable. Try again later.")
        case .insufficientSpace:
            String(localized: "There isn't enough storage space in this cloud account.")
        case .permissionDenied:
            String(localized: "You don't have permission to change this file.")
        case .invalidName:
            String(localized: "The cloud service rejected this file name.")
        case .unknown(let message):
            message
        }
    }

    static func message(for error: Error) -> String {
        if let cloudError = error as? CloudProviderError,
           let description = cloudError.errorDescription {
            return description
        }

        let nsError = error as NSError
        return nsError.localizedDescription
    }

    static func isLikelyOffline(_ error: Error) -> Bool {
        if let cloudError = error as? CloudProviderError, cloudError == .networkUnavailable {
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
