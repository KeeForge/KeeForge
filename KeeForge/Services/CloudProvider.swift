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
}

extension CloudProvider {
    @MainActor
    func cancelPendingAuthentication() {}
}

enum CloudProviderError: LocalizedError, Equatable {
    case invalidConfiguration
    case authenticationCancelled
    case notAuthenticated
    case networkUnavailable
    case fileNotFound
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Cloud sync is not configured for this build."
        case .authenticationCancelled:
            "Authentication was cancelled."
        case .notAuthenticated:
            "Please reconnect this cloud account."
        case .networkUnavailable:
            "No network connection. Using the cached copy if available."
        case .fileNotFound:
            "The remote database could not be found."
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

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }
}
