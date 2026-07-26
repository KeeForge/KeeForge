import AuthenticationServices
import Foundation
import os
@preconcurrency import SwiftyDropbox
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
    static let requestedScopes = [
        "account_info.read",
        "files.metadata.read",
        "files.content.read",
        "files.content.write",
    ]

    /// Attempt budget and delay ceiling for the transient failures Dropbox asks
    /// callers to retry; SwiftyDropbox retries none of them itself.
    static let maxAttempts = 3
    static let maxRetryDelay: TimeInterval = 10

    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    @MainActor
    private var pendingAuthContinuation: CheckedContinuation<CloudAccount, Error>?

    /// SwiftyDropbox's global setup asserts it runs exactly once, and its
    /// clients own URLSessions outliving a single call, so both are reached
    /// only through this lock — entry points span the main actor and the
    /// cooperative pool.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    private struct State {
        var didConfigure = false
        var clients: [String: DropboxClient] = [:]
    }

    /// A Dropbox failure the caller is expected to retry itself. `withRetry`
    /// always either retries or rethrows `mapped`, so this never escapes the
    /// provider; the `LocalizedError` conformance is a backstop.
    struct TransientFailure: Error, LocalizedError {
        enum Kind: Equatable {
            case rateLimited(retryAfter: UInt64)
            case tooManyWriteOperations
            case serverError
        }

        let kind: Kind
        let mapped: CloudProviderError

        var errorDescription: String? { mapped.errorDescription }
    }

    private init() {}

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        try configureIfNeeded()

        guard pendingAuthContinuation == nil else {
            throw CloudProviderError.unknown(String(localized: "Another Dropbox sign-in is already in progress."))
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingAuthContinuation = continuation

            let scopeRequest = Self.makeScopeRequest()

            #if os(iOS)
            DropboxClientsManager.authorizeFromControllerV2(
                UIApplication.shared,
                controller: presentingController(from: anchor),
                loadingStatusDelegate: nil,
                openURL: { url in
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                },
                scopeRequest: scopeRequest
            )
            #else
            // Desktop OAuth (PKCE): SwiftyDropbox opens the system browser via
            // NSWorkspace; the redirect returns through the db-<appkey> URL
            // scheme, which the SwiftUI onOpenURL handler forwards to
            // `handleRedirectURL(_:)` below to resume the continuation.
            DropboxClientsManager.authorizeFromControllerV2(
                sharedApplication: NSApplication.shared,
                controller: presentingController(from: anchor),
                loadingStatusDelegate: nil,
                openURL: { url in
                    NSWorkspace.shared.open(url)
                },
                scopeRequest: scopeRequest
            )
            #endif
        }
    }

    @MainActor
    func cancelPendingAuthentication() {
        guard let continuation = pendingAuthContinuation else { return }
        pendingAuthContinuation = nil
        continuation.resume(throwing: CloudProviderError.authenticationCancelled)
    }

    func isAuthenticated(accountId: String) -> Bool {
        guard let manager = try? configuredOAuthManager() else { return false }
        return manager.getAccessToken(accountId) != nil
    }

    func signOut(accountId: String) {
        // The SDK's OAuth manager only exists once configuration has
        // succeeded, so a disconnect that never touched the SDK this session
        // would strand the long-lived refresh token. Delete the row directly
        // too, so the token is gone either way.
        if let manager = try? configuredOAuthManager(),
           let token = manager.getAccessToken(accountId) {
            _ = manager.clearStoredAccessToken(token)
        }

        _ = CloudTokenStore.deleteToken(provider: id, accountId: accountId)
        invalidateClient(accountId: accountId)
        CloudAccountStore.remove(provider: id, accountId: accountId)
        DropboxClientsManager.resetClients()
    }

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        let client = try client(for: accountId)

        return try await withRetry {
            if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return try await self.searchFiles(client: client, path: path, query: query)
            }

            return try await self.listFolder(client: client, path: path)
        }
    }

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        let client = try client(for: accountId)

        return try await withRetry {
            try await self.performDownload(client: client, fileId: fileId, to: localURL, progress: progress)
        }
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let client = try client(for: accountId)

        return try await withRetry {
            try await self.performGetMetadata(client: client, fileId: fileId)
        }
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        let client = try client(for: accountId)

        return try await withRetry {
            try await self.performUpload(
                client: client,
                fileId: fileId,
                data: data,
                expectedRev: expectedRev,
                progress: progress
            )
        }
    }

    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        let client = try client(for: accountId)

        return try await withRetry {
            try await self.performCreateFile(client: client, path: path, data: data, progress: progress)
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

    /// Repeats `operation` while Dropbox reports a transient failure. Every
    /// route used here is safe to repeat: reads are idempotent and both writes
    /// carry `strictConflict`, so a retried write either applies once or fails
    /// as a conflict.
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1

        while true {
            do {
                return try await operation()
            } catch let failure as TransientFailure {
                guard let delay = Self.retryDelay(for: failure.kind, attempt: attempt) else {
                    throw failure.mapped
                }

                try await Task.sleep(for: .seconds(delay))
                attempt += 1
            }
        }
    }

    /// Delay before the next attempt, or nil once the attempt budget is spent.
    /// Dropbox's `retry_after` can be minutes, so it is clamped — a save must
    /// fail with a message rather than stall.
    static func retryDelay(for kind: TransientFailure.Kind, attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt < maxAttempts else { return nil }

        switch kind {
        case .rateLimited(let retryAfter):
            return min(max(TimeInterval(retryAfter), 1), maxRetryDelay)
        case .tooManyWriteOperations, .serverError:
            // Dropbox sends no hint for these, so back off from a second.
            return min(pow(2, TimeInterval(attempt - 1)), maxRetryDelay)
        }
    }

    private func performDownload(
        client: DropboxClient,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CloudFileMetadata?, Error>) in
            client.files.download(path: fileId, overwrite: true, destination: localURL)
                .progress { transferProgress in
                    progress(transferProgress.fractionCompleted)
                }
                .response { response, error in
                    // The download response carries the metadata of the exact
                    // revision that was served, which is what the caller must
                    // record — not the one it saw beforehand.
                    if let response {
                        continuation.resume(returning: Self.makeCloudFileMetadata(from: response.0))
                    } else {
                        continuation.resume(throwing: Self.mapDownloadError(error))
                    }
                }
        }
    }

    private func performGetMetadata(client: DropboxClient, fileId: String) async throws -> CloudFileMetadata {
        try await withCheckedThrowingContinuation { continuation in
            client.files.getMetadata(path: fileId)
                .response { response, error in
                    if let file = response as? Files.FileMetadata {
                        continuation.resume(returning: Self.makeCloudFileMetadata(from: file))
                    } else if response != nil {
                        continuation.resume(throwing: CloudProviderError.fileNotFound)
                    } else {
                        continuation.resume(throwing: Self.mapGetMetadataError(error))
                    }
                }
        }
    }

    private func performUpload(
        client: DropboxClient,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        let mode: Files.WriteMode = if let expectedRev {
            .update(expectedRev)
        } else {
            .overwrite
        }

        return try await withCheckedThrowingContinuation { continuation in
            client.files.upload(
                path: fileId,
                mode: mode,
                strictConflict: true,
                input: data
            )
            .progress { transferProgress in
                progress(transferProgress.fractionCompleted)
            }
            .response { response, error in
                if let file = response {
                    continuation.resume(returning: Self.makeCloudFileMetadata(from: file))
                } else if let error {
                    self.resolveUploadFailure(
                        client: client,
                        fileId: fileId,
                        error: error,
                        continuation: continuation
                    )
                } else {
                    continuation.resume(throwing: CloudProviderError.unknown(String(localized: "Dropbox upload failed.")))
                }
            }
        }
    }

    private func performCreateFile(
        client: DropboxClient,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        try await withCheckedThrowingContinuation { continuation in
            client.files.upload(
                path: path,
                mode: .add,
                strictConflict: true,
                input: data
            )
            .progress { transferProgress in
                progress(transferProgress.fractionCompleted)
            }
            .response { response, error in
                if let file = response,
                   let cloudFile = Self.makeCloudFile(from: file) {
                    continuation.resume(
                        returning: CloudCreatedFile(
                            file: cloudFile,
                            metadata: Self.makeCloudFileMetadata(from: file)
                        )
                    )
                } else if let error {
                    self.resolveCreateFailure(
                        client: client,
                        path: path,
                        error: error,
                        continuation: continuation
                    )
                } else {
                    continuation.resume(throwing: CloudProviderError.unknown(String(localized: "Dropbox upload failed.")))
                }
            }
        }
    }

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

    /// One client per account, kept for the process lifetime: each owns two
    /// URLSessions that only `shutdown()` invalidates and caches the refreshed
    /// access token, so building one per call leaked sessions and forced an
    /// OAuth round-trip per request.
    private func client(for accountId: String) throws -> DropboxClient {
        // `withLockUnchecked` because the SDK's client and OAuth manager are not
        // `Sendable`; the lock is what keeps them single-threaded here.
        try state.withLockUnchecked { state in
            try Self.configure(&state)

            if let cached = state.clients[accountId] {
                return cached
            }

            guard let manager = DropboxOAuthManager.sharedOAuthManager,
                  let token = manager.getAccessToken(accountId) else {
                throw CloudProviderError.notAuthenticated
            }

            let client = DropboxClient(accessToken: token, dropboxOauthManager: manager)
            state.clients[accountId] = client
            return client
        }
    }

    private func invalidateClient(accountId: String) {
        let client = state.withLockUnchecked { $0.clients.removeValue(forKey: accountId) }
        client?.shutdown()
    }

    private func configuredOAuthManager() throws -> DropboxOAuthManager {
        try state.withLockUnchecked { state in
            try Self.configure(&state)

            guard let manager = DropboxOAuthManager.sharedOAuthManager else {
                throw CloudProviderError.invalidConfiguration
            }

            return manager
        }
    }

    #if os(iOS)
    @MainActor
    private func presentingController(from anchor: ASPresentationAnchor) -> UIViewController? {
        let window = anchor
        return topViewController(startingAt: window.rootViewController)
    }

    @MainActor
    private func topViewController(startingAt root: UIViewController?) -> UIViewController? {
        var current = root

        while let presented = current?.presentedViewController {
            current = presented
        }

        if let navigationController = current as? UINavigationController {
            return topViewController(startingAt: navigationController.visibleViewController)
        }

        if let tabBarController = current as? UITabBarController {
            return topViewController(startingAt: tabBarController.selectedViewController)
        }

        return current
    }
    #endif

    #if os(macOS)
    // On macOS the presentation anchor is the NSWindow; SwiftyDropbox only
    // uses the controller to anchor error alerts (auth itself runs in the
    // default browser), and falls back to the key window's content view
    // controller when nil.
    @MainActor
    private func presentingController(from anchor: ASPresentationAnchor) -> NSViewController? {
        anchor.contentViewController ?? NSApplication.shared.keyWindow?.contentViewController
    }
    #endif

    private func configureIfNeeded() throws {
        try state.withLockUnchecked { try Self.configure(&$0) }
    }

    /// SwiftyDropbox asserts that its global setup runs exactly once, so the
    /// guard and the setup call have to be atomic; callers must already hold
    /// the state lock.
    private static func configure(_ state: inout State) throws {
        guard state.didConfigure == false else { return }
        guard let appKey = appKey else {
            throw CloudProviderError.invalidConfiguration
        }

        #if os(iOS)
        DropboxClientsManager.setupWithAppKeyMultiUser(
            appKey,
            tokenUid: nil,
            secureStorageAccess: DropboxSecureStorageAccess()
        )
        #else
        DropboxClientsManager.setupWithAppKeyMultiUserDesktop(
            appKey,
            secureStorageAccess: DropboxSecureStorageAccess(),
            tokenUid: nil
        )
        #endif
        state.didConfigure = true
    }

    private static var appKey: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "DROPBOX_APP_KEY",
              trimmed != "YOUR_DROPBOX_APP_KEY",
              // Current CI placeholder (RFC1738-safe so `db-<key>` stays a legal
              // URL scheme) plus the legacy underscore form kept for older configs.
              trimmed != "ciplaceholderdropboxappkey",
              trimmed != "CI_PLACEHOLDER_DROPBOX_APP_KEY" else {
            return nil
        }

        return trimmed
    }

    private func resolveUploadFailure(
        client: DropboxClient,
        fileId: String,
        error: CallError<Files.UploadError>,
        continuation: CheckedContinuation<CloudFileMetadata, Error>
    ) {
        let mappedError = Self.mapUploadError(error)
        guard let cloudError = mappedError as? CloudProviderError else {
            continuation.resume(throwing: mappedError)
            return
        }

        switch cloudError {
        case .conflict:
            client.files.getMetadata(path: fileId)
                .response { response, _ in
                    let remoteRev = (response as? Files.FileMetadata)?.rev
                    continuation.resume(throwing: CloudProviderError.conflict(remoteRev: remoteRev))
                }
        default:
            continuation.resume(throwing: cloudError)
        }
    }

    private func resolveCreateFailure(
        client: DropboxClient,
        path: String,
        error: CallError<Files.UploadError>,
        continuation: CheckedContinuation<CloudCreatedFile, Error>
    ) {
        let mappedError = Self.mapUploadError(error)
        guard let cloudError = mappedError as? CloudProviderError else {
            continuation.resume(throwing: mappedError)
            return
        }

        switch cloudError {
        case .conflict:
            client.files.getMetadata(path: path)
                .response { response, _ in
                    let remoteRev = (response as? Files.FileMetadata)?.rev
                    continuation.resume(throwing: CloudProviderError.conflict(remoteRev: remoteRev))
                }
        default:
            continuation.resume(throwing: cloudError)
        }
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
        case .success(let accessToken):
            do {
                let account = try await currentAccountFromAuthorizedClient(tokenUID: accessToken.uid)
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
    private func currentAccountFromAuthorizedClient(tokenUID: String) async throws -> CloudAccount {
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

        // SwiftyDropbox stores and resolves tokens by OAuth uid, not by account_id.
        // Keep our persisted account key aligned with the SDK token key so subsequent
        // file listing and downloads can resolve the stored refresh token.
        if account.accountId != tokenUID {
            CloudAccountStore.remove(provider: id, accountId: account.accountId)
        }

        return CloudAccount(id: tokenUID, displayName: displayName, provider: id)
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

    private static func makeCloudFileMetadata(from file: Files.FileMetadata) -> CloudFileMetadata {
        CloudFileMetadata(
            modifiedDate: file.serverModified,
            contentHash: file.contentHash,
            size: Int64(file.size),
            rev: file.rev
        )
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
            return CloudProviderError.unknown(String(localized: "Dropbox metadata request failed."))
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
            return CloudProviderError.unknown(String(localized: "Dropbox download failed."))
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
            return CloudProviderError.unknown(String(localized: "Dropbox folder listing failed."))
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
            return CloudProviderError.unknown(String(localized: "Dropbox folder listing failed."))
        }

        return mapGenericDropboxError(error)
    }

    private static func mapSearchError(_ error: CallError<Files.SearchError>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown(String(localized: "Dropbox search failed."))
        }

        return mapGenericDropboxError(error)
    }

    private static func mapUploadError(_ error: CallError<Files.UploadError>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown(String(localized: "Dropbox upload failed."))
        }

        if case .routeError(let boxed, _, _, _) = error,
           let mapped = mapUploadRouteError(boxed.unboxed) {
            return mapped
        }

        return mapGenericDropboxError(error)
    }

    /// Split out of `mapUploadError` so it is reachable from tests: SwiftyDropbox's
    /// `Box` has no public initializer, so a `CallError.routeError` cannot be
    /// built outside the SDK.
    static func mapUploadRouteError(_ uploadError: Files.UploadError) -> Error? {
        guard case .path(let writeFailure) = uploadError else { return nil }
        return mapWriteError(writeFailure.reason)
    }

    /// Returns nil for reasons Dropbox leaves unspecified, so the caller falls
    /// back to the generic mapping rather than inventing a wrong message.
    static func mapWriteError(_ writeError: Files.WriteError) -> Error? {
        switch writeError {
        case .conflict:
            return CloudProviderError.conflict(remoteRev: nil)
        case .insufficientSpace:
            return CloudProviderError.insufficientSpace
        case .noWritePermission, .teamFolder, .operationSuppressed:
            return CloudProviderError.permissionDenied
        case .disallowedName, .malformedPath:
            return CloudProviderError.invalidName
        case .tooManyWriteOperations:
            return TransientFailure(kind: .tooManyWriteOperations, mapped: .rateLimited)
        case .other:
            return nil
        }
    }

    private static func mapGenericDropboxError<E>(_ error: CallError<E>?) -> Error {
        guard let error else {
            return CloudProviderError.unknown(String(localized: "Dropbox request failed."))
        }

        return mapGenericDropboxError(error)
    }

    static func mapGenericDropboxError<E>(_ error: CallError<E>) -> Error {
        switch error {
        case .clientError(let clientError):
            switch clientError {
            case .urlSessionError(let underlyingError):
                return mapTransportError(underlyingError)
            case .oauthError(let underlyingError):
                return mapOAuthRefreshError(underlyingError)
            default:
                return CloudProviderError.unknown(String(describing: error))
            }

        case .authError(let authError, _, _, _):
            switch authError {
            case .expiredAccessToken, .invalidAccessToken:
                return CloudProviderError.notAuthenticated
            case .missingScope:
                return CloudProviderError.writeScopeRequired
            default:
                return CloudProviderError.unknown(String(describing: error))
            }

        case .rateLimitError(let rateLimitError, _, _, _):
            return TransientFailure(
                kind: .rateLimited(retryAfter: rateLimitError.retryAfter),
                mapped: .rateLimited
            )

        case .internalServerError:
            return TransientFailure(kind: .serverError, mapped: .serviceUnavailable)

        case .httpError(let statusCode, _, _):
            // 5xx normally arrives as `.internalServerError`; this covers the
            // responses the SDK leaves unclassified.
            guard let statusCode, (500 ... 599).contains(statusCode) else {
                return CloudProviderError.unknown(String(describing: error))
            }

            return TransientFailure(kind: .serverError, mapped: .serviceUnavailable)

        default:
            return CloudProviderError.unknown(String(describing: error))
        }
    }

    static func mapTransportError(_ error: Error) -> CloudProviderError {
        if CloudProviderError.isLikelyOffline(error) {
            return .networkUnavailable
        }

        return .unknown((error as NSError).localizedDescription)
    }

    /// KeeForge persists only the refresh token, so every request refreshes
    /// first and an offline call fails at the OAuth stage. `OAuthTokenRequest`
    /// flattens the transport cause into a message string, leaving the OAuth
    /// code as the only thing to classify by.
    static func mapOAuthRefreshError(_ error: Error) -> CloudProviderError {
        // Defensive: honour a genuine URL error should a future SDK version
        // preserve one.
        if CloudProviderError.isLikelyOffline(error) {
            return .networkUnavailable
        }

        guard let oauthError = error as? OAuth2Error else {
            return .unknown((error as NSError).localizedDescription)
        }

        switch oauthError {
        case .unknown:
            // Only transport failures and unparseable responses reach `.unknown`,
            // so treat it as connectivity: an airplane-mode open then falls back
            // to the cached copy instead of persisting a raw SDK dump.
            return .networkUnavailable
        case .serverError, .temporarilyUnavailable:
            return .serviceUnavailable
        default:
            // invalid_grant and the other credential-shaped codes need a reconnect.
            return .notAuthenticated
        }
    }

    static func makeScopeRequest() -> ScopeRequest {
        ScopeRequest(
            scopeType: .user,
            scopes: requestedScopes,
            includeGrantedScopes: false
        )
    }
}
