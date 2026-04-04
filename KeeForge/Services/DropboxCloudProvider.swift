import AuthenticationServices
import Foundation
@preconcurrency import SwiftyDropbox
import UIKit

private struct StoredDropboxRefreshToken: Codable {
    let uid: String
    let refreshToken: String
}

private final class DropboxSecureStorageAccess: SecureStorageAccess {
    func checkAccessibilityMigrationOneTime() {}

    func setAccessTokenData(for userId: String, data: Data) -> Bool {
        if let decoded = try? JSONDecoder().decode(DropboxAccessToken.self, from: data),
           let refreshToken = decoded.refreshToken {
            let stored = StoredDropboxRefreshToken(uid: userId, refreshToken: refreshToken)
            guard let encoded = try? JSONEncoder().encode(stored) else { return false }
            return CloudTokenStore.setTokenData(encoded, provider: CloudProviderKind.dropbox.rawValue, accountId: userId)
        }

        return CloudTokenStore.setTokenData(data, provider: CloudProviderKind.dropbox.rawValue, accountId: userId)
    }

    func getAllUserIds() -> [String] {
        CloudTokenStore.allAccountIDs(provider: CloudProviderKind.dropbox.rawValue)
    }

    func getDropboxAccessToken(for key: String) -> DropboxAccessToken? {
        guard let data = CloudTokenStore.tokenData(provider: CloudProviderKind.dropbox.rawValue, accountId: key) else {
            return nil
        }

        if let stored = try? JSONDecoder().decode(StoredDropboxRefreshToken.self, from: data) {
            return DropboxAccessToken(
                accessToken: "",
                uid: stored.uid,
                refreshToken: stored.refreshToken,
                tokenExpirationTimestamp: 0
            )
        }

        if let token = try? JSONDecoder().decode(DropboxAccessToken.self, from: data) {
            return token
        }

        if let accessToken = String(data: data, encoding: .utf8) {
            return DropboxAccessToken(accessToken: accessToken, uid: key)
        }

        return nil
    }

    func deleteInfo(for key: String) -> Bool {
        CloudTokenStore.deleteToken(provider: CloudProviderKind.dropbox.rawValue, accountId: key)
    }

    func deleteInfoForAllKeys() -> Bool {
        let accountIDs = getAllUserIds()
        return accountIDs.allSatisfy { deleteInfo(for: $0) }
    }
}

final class DropboxCloudProvider: CloudProvider, @unchecked Sendable {
    static let shared = DropboxCloudProvider()

    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    @MainActor
    private var pendingAuthContinuation: CheckedContinuation<CloudAccount, Error>?
    private var didConfigure = false

    private init() {}

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        try configureIfNeeded()

        guard pendingAuthContinuation == nil else {
            throw CloudProviderError.unknown("Another Dropbox sign-in is already in progress.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingAuthContinuation = continuation

            let scopeRequest = ScopeRequest(
                scopeType: .user,
                scopes: ["account_info.read", "files.metadata.read", "files.content.read"],
                includeGrantedScopes: false
            )

            DropboxClientsManager.authorizeFromControllerV2(
                UIApplication.shared,
                controller: nil,
                loadingStatusDelegate: nil,
                openURL: { url in
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                },
                scopeRequest: scopeRequest
            )
        }
    }

    func isAuthenticated(accountId: String) -> Bool {
        do {
            try configureIfNeeded()
        } catch {
            return false
        }

        return oauthManager()?.getAccessToken(accountId) != nil
    }

    func signOut(accountId: String) {
        guard let manager = oauthManager() else {
            CloudAccountStore.remove(provider: id, accountId: accountId)
            return
        }

        if let token = manager.getAccessToken(accountId) {
            _ = manager.clearStoredAccessToken(token)
        }

        CloudAccountStore.remove(provider: id, accountId: accountId)
        DropboxClientsManager.resetClients()
    }

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        let client = try client(for: accountId)

        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await searchFiles(client: client, path: path, query: query)
        }

        return try await listFolder(client: client, path: path)
    }

    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let client = try client(for: accountId)

        try await withCheckedThrowingContinuation { continuation in
            client.files.download(path: fileId, overwrite: true, destination: localURL)
                .progress { transferProgress in
                    progress(transferProgress.fractionCompleted)
                }
                .response { response, error in
                    if response != nil {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: Self.mapDownloadError(error))
                    }
                }
        }
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let client = try client(for: accountId)

        return try await withCheckedThrowingContinuation { continuation in
            client.files.getMetadata(path: fileId)
                .response { response, error in
                    if let file = response as? Files.FileMetadata {
                        continuation.resume(
                            returning: CloudFileMetadata(
                                modifiedDate: file.serverModified,
                                contentHash: file.contentHash,
                                size: Int64(file.size)
                            )
                        )
                    } else if response != nil {
                        continuation.resume(throwing: CloudProviderError.fileNotFound)
                    } else {
                        continuation.resume(throwing: Self.mapGetMetadataError(error))
                    }
                }
        }
    }

    @MainActor
    func handleRedirectURL(_ url: URL) -> Bool {
        do {
            try configureIfNeeded()
        } catch {
            return false
        }

        return DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { [weak self] result in
            Task { @MainActor in
                await self?.finishAuthentication(with: result)
            }
        }
    }

    // MARK: - Private

    private func listFolder(client: DropboxClient, path: String?) async throws -> [CloudFile] {
        var aggregatedEntries: [Files.Metadata] = []
        let rootPath = path ?? ""

        let firstResult: Files.ListFolderResult = try await withCheckedThrowingContinuation { continuation in
            client.files.listFolder(path: rootPath)
                .response { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: Self.mapListFolderError(error))
                    }
                }
        }

        aggregatedEntries.append(contentsOf: firstResult.entries)
        var cursor = firstResult.cursor
        var hasMore = firstResult.hasMore

        while hasMore {
            let nextResult: Files.ListFolderResult = try await withCheckedThrowingContinuation { continuation in
                client.files.listFolderContinue(cursor: cursor)
                    .response { response, error in
                        if let response {
                            continuation.resume(returning: response)
                        } else {
                            continuation.resume(throwing: Self.mapListFolderContinueError(error))
                        }
                    }
            }

            aggregatedEntries.append(contentsOf: nextResult.entries)
            cursor = nextResult.cursor
            hasMore = nextResult.hasMore
        }

        return aggregatedEntries.compactMap(Self.makeCloudFile(from:))
            .sorted(by: Self.sortCloudFiles)
    }

    private func searchFiles(client: DropboxClient, path: String?, query: String) async throws -> [CloudFile] {
        var matches: [Files.SearchMatchV2] = []
        let options = Files.SearchOptions(
            path: path,
            maxResults: 100,
            filenameOnly: false,
            fileExtensions: ["kdbx"]
        )

        let firstResult: Files.SearchV2Result = try await withCheckedThrowingContinuation { continuation in
            client.files.searchV2(query: query, options: options)
                .response { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: Self.mapSearchError(error))
                    }
                }
        }

        matches.append(contentsOf: firstResult.matches)
        var cursor = firstResult.cursor
        var hasMore = firstResult.hasMore

        while hasMore, let currentCursor = cursor {
            let nextResult: Files.SearchV2Result = try await withCheckedThrowingContinuation { continuation in
                client.files.searchContinueV2(cursor: currentCursor)
                    .response { response, error in
                        if let response {
                            continuation.resume(returning: response)
                        } else {
                            continuation.resume(throwing: Self.mapSearchError(error))
                        }
                    }
            }

            matches.append(contentsOf: nextResult.matches)
            cursor = nextResult.cursor
            hasMore = nextResult.hasMore
        }

        let files = matches.compactMap(Self.makeCloudFile(from:))
        return Array(Set(files)).sorted(by: Self.sortCloudFiles)
    }

    private func client(for accountId: String) throws -> DropboxClient {
        try configureIfNeeded()

        guard let manager = oauthManager(),
              let token = manager.getAccessToken(accountId) else {
            throw CloudProviderError.notAuthenticated
        }

        return DropboxClient(accessToken: token, dropboxOauthManager: manager)
    }

    private func oauthManager() -> DropboxOAuthManager? {
        DropboxOAuthManager.sharedOAuthManager
    }

    private func configureIfNeeded() throws {
        guard didConfigure == false else { return }
        guard let appKey = appKey else {
            throw CloudProviderError.invalidConfiguration
        }

        DropboxClientsManager.setupWithAppKeyMultiUser(
            appKey,
            tokenUid: nil,
            secureStorageAccess: DropboxSecureStorageAccess()
        )
        didConfigure = true
    }

    private var appKey: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "DROPBOX_APP_KEY" else {
            return nil
        }

        return trimmed
    }

    @MainActor
    private func finishAuthentication(with result: DropboxOAuthResult?) async {
        guard let continuation = pendingAuthContinuation else { return }
        pendingAuthContinuation = nil

        guard let result else {
            continuation.resume(throwing: CloudProviderError.authenticationCancelled)
            return
        }

        switch result {
        case .success:
            do {
                let account = try await currentAccountFromAuthorizedClient()
                CloudAccountStore.upsert(account)
                continuation.resume(returning: account)
            } catch {
                continuation.resume(throwing: error)
            }

        case .cancel:
            continuation.resume(throwing: CloudProviderError.authenticationCancelled)

        case .error(let authError, let description):
            if authError.isInvalidGrantError {
                continuation.resume(throwing: CloudProviderError.notAuthenticated)
            } else {
                continuation.resume(throwing: CloudProviderError.unknown(description ?? authError.localizedDescription))
            }
        }
    }

    @MainActor
    private func currentAccountFromAuthorizedClient() async throws -> CloudAccount {
        guard let client = DropboxClientsManager.authorizedClient else {
            throw CloudProviderError.notAuthenticated
        }

        let account: Users.FullAccount = try await withCheckedThrowingContinuation { continuation in
            client.users.getCurrentAccount()
                .response { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: Self.mapGenericDropboxError(error))
                    }
                }
        }

        let displayName = account.email.isEmpty ? account.name.displayName : account.email
        return CloudAccount(id: account.accountId, displayName: displayName, provider: id)
    }

    private static func makeCloudFile(from metadata: Files.Metadata) -> CloudFile? {
        if let file = metadata as? Files.FileMetadata {
            guard file.name.lowercased().hasSuffix(".kdbx") else { return nil }
            let fileID = file.pathDisplay ?? file.pathLower ?? "/\(file.name)"
            let displayPath = file.pathDisplay ?? file.pathLower ?? file.name
            return CloudFile(
                id: fileID,
                name: file.name,
                path: displayPath,
                isFolder: false,
                modifiedDate: file.serverModified,
                size: Int64(file.size)
            )
        }

        if let folder = metadata as? Files.FolderMetadata {
            let fileID = folder.pathDisplay ?? folder.pathLower ?? "/\(folder.name)"
            let displayPath = folder.pathDisplay ?? folder.pathLower ?? folder.name
            return CloudFile(
                id: fileID,
                name: folder.name,
                path: displayPath,
                isFolder: true,
                modifiedDate: nil,
                size: nil
            )
        }

        return nil
    }

    private static func makeCloudFile(from match: Files.SearchMatchV2) -> CloudFile? {
        guard case .metadata(let metadata) = match.metadata else { return nil }
        return makeCloudFile(from: metadata)
    }

    private static func sortCloudFiles(_ lhs: CloudFile, _ rhs: CloudFile) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func mapGetMetadataError(_ error: CallError<Files.GetMetadataError>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("Dropbox metadata request failed.")
        }

        if case .routeError(let boxed, _, _, _) = error,
           case .path(let lookupError) = boxed.unboxed,
           case .notFound = lookupError {
            return CloudProviderError.fileNotFound
        }

        return mapGenericDropboxError(error)
    }

    private static func mapDownloadError(_ error: CallError<Files.DownloadError>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("Dropbox download failed.")
        }

        if case .routeError(let boxed, _, _, _) = error,
           case .path(let lookupError) = boxed.unboxed,
           case .notFound = lookupError {
            return CloudProviderError.fileNotFound
        }

        return mapGenericDropboxError(error)
    }

    private static func mapListFolderError(_ error: CallError<Files.ListFolderError>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("Dropbox folder listing failed.")
        }

        if case .routeError(let boxed, _, _, _) = error,
           case .path(let lookupError) = boxed.unboxed,
           case .notFound = lookupError {
            return CloudProviderError.fileNotFound
        }

        return mapGenericDropboxError(error)
    }

    private static func mapListFolderContinueError(_ error: CallError<Files.ListFolderContinueError>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("Dropbox folder listing failed.")
        }

        return mapGenericDropboxError(error)
    }

    private static func mapSearchError(_ error: CallError<Files.SearchError>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("Dropbox search failed.")
        }

        return mapGenericDropboxError(error)
    }

    private static func mapGenericDropboxError(_ error: Error?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("Dropbox request failed.")
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return CloudProviderError.networkUnavailable
        }

        return CloudProviderError.unknown(nsError.localizedDescription)
    }

    private static func mapGenericDropboxError<E>(_ error: CallError<E>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("Dropbox request failed.")
        }

        return mapGenericDropboxError(error)
    }

    private static func mapGenericDropboxError<E>(_ error: CallError<E>) -> Error {
        switch error {
        case .clientError(let clientError):
            switch clientError {
            case .urlSessionError(let underlyingError):
                let nsError = underlyingError as NSError
                if nsError.domain == NSURLErrorDomain {
                    return CloudProviderError.networkUnavailable
                }
                return CloudProviderError.unknown(nsError.localizedDescription)
            default:
                return CloudProviderError.unknown(String(describing: error))
            }

        case .authError(let authError, _, _, _):
            switch authError {
            case .expiredAccessToken, .invalidAccessToken:
                return CloudProviderError.notAuthenticated
            default:
                return CloudProviderError.unknown(String(describing: error))
            }

        default:
            return CloudProviderError.unknown(String(describing: error))
        }
    }
}
