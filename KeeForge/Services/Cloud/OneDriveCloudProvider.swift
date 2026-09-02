import AuthenticationServices
import Foundation
@preconcurrency import MSAL
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class OneDriveCloudProvider: CloudProvider, @unchecked Sendable {
    static let shared = OneDriveCloudProvider()

    private static let scopes = [
        "Files.ReadWrite",
        "User.Read",
    ]
    private static let graphBaseURLString = "https://graph.microsoft.com/v1.0"
    private static let uploadChunkSize = 5 * 1_024 * 1_024

    /// Upper bound for the simple `PUT .../content` upload. Microsoft documents
    /// 4 MiB as the conservative, universally supported limit for a single-shot
    /// content upload (larger single PUTs are accepted by some endpoints but are
    /// not guaranteed). Anything above this has to go through an upload session.
    /// Internal for testing.
    static let simpleUploadByteLimit = 4 * 1_024 * 1_024

    /// Total attempts (1 initial + 2 retries) for any retryable Graph request.
    /// Microsoft asks for exponential backoff on interruptions and 5xx, but a
    /// save is interactive, so the ceiling stays low. Internal for testing.
    static let requestMaxAttempts = 3

    /// Total attempts (1 initial + 2 retries) allowed for the
    /// `createUploadSession` POST. Internal for testing.
    static let uploadSessionCreationMaxAttempts = 3

    /// The one `$select` list every stored rev/hash originates from. Upload
    /// responses use a different default shape and can omit `cTag`/`eTag`/
    /// `hashes`, so metadata is only ever derived from requests carrying this
    /// list. Internal for testing.
    static let metadataSelectList = "id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"

    /// Ceiling applied to a server-supplied `Retry-After`, so a misbehaving
    /// header cannot stall a save indefinitely.
    private static let maxRetryAfterSeconds: Double = 10

    let id = CloudProviderKind.oneDrive.rawValue
    let displayName = CloudProviderKind.oneDrive.displayName
    let iconName = CloudProviderKind.oneDrive.iconName

    /// Every mutable property of this singleton lives here. MSAL types are not
    /// `Sendable`, hence `uncheckedState`; the lock is what makes the accesses
    /// safe, and it is never held across an `await`.
    private struct MutableState {
        var application: MSALPublicClientApplication?
        var silentTokenTasks: [String: Task<String, Error>] = [:]
        var isAuthenticating = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: MutableState())

    private let decoder: JSONDecoder

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseISO8601Date(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid OneDrive date: \(value)"
            )
        }
        self.decoder = decoder
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        let application = try application()

        // MSAL permits one interactive session per process
        // (`MSALError.interactiveSessionAlreadyRunning`, -42402) and a second
        // request tears down the first one's web session, so reject the
        // reentry and let the in-flight sign-in survive.
        guard beginInteractiveAuthentication() else {
            throw CloudProviderError.unknown(String(localized: "Another OneDrive sign-in is already in progress."))
        }
        defer { endInteractiveAuthentication() }

        #if os(iOS)
        let webParameters = MSALWebviewParameters(authPresentationViewController: presentingController(from: anchor))
        #else
        let webParameters = Self.makeWebviewParameters(from: anchor)
        #endif
        let parameters = MSALInteractiveTokenParameters(scopes: Self.scopes, webviewParameters: webParameters)
        parameters.promptType = .selectAccount

        let result = try await acquireToken(application: application, parameters: parameters)
        let account = makeCloudAccount(from: result.account)
        CloudAccountStore.upsert(account)
        return account
    }

    func isAuthenticated(accountId: String) -> Bool {
        do {
            _ = try application().account(forIdentifier: accountId)
            return true
        } catch {
            return false
        }
    }

    func signOut(accountId: String) {
        do {
            let application = try application()
            let account = try application.account(forIdentifier: accountId)
            try application.remove(account)
        } catch {
            // The local account row is still stale even if MSAL has already dropped its token cache.
        }

        CloudAccountStore.remove(provider: id, accountId: accountId)
    }

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        let token = try await accessToken(accountId: accountId)
        var files: [CloudFile] = []
        var nextURL: URL? = try Self.graphURL(
            path: Self.listChildrenPath(for: path),
            queryItems: [
                URLQueryItem(name: "$top", value: "200"),
                URLQueryItem(name: "$select", value: Self.metadataSelectList),
            ]
        )

        while let currentURL = nextURL {
            let response: OneDriveCollectionResponse = try await decodedGraphResponse(
                OneDriveCollectionResponse.self,
                request: authorizedRequest(url: currentURL, token: token)
            )
            files.append(contentsOf: response.value.compactMap(Self.makeCloudFile(from:)))
            nextURL = response.nextLink.flatMap(URL.init(string:))
        }

        let filteredFiles = filter(files: files, query: query)
        return filteredFiles.sorted(by: Self.sortCloudFiles)
    }

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        let token = try await accessToken(accountId: accountId)
        let request = authorizedRequest(url: try Self.graphURL(path: Self.contentPath(for: fileId)), token: token)
        let downloadURL = try await downloadRetrying(request)

        do {
            let directoryURL = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: downloadURL, to: localURL)
            progress(1)
        } catch let error as CloudProviderError {
            throw error
        } catch {
            throw Self.mapGenericError(error)
        }

        // `/content` redirects to a pre-authenticated storage URL whose
        // response carries no eTag/cTag, and a second `GET /items/{id}` would
        // report the head then, not the revision these bytes came from.
        return nil
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let token = try await accessToken(accountId: accountId)
        return try await fetchItemMetadata(path: Self.itemPath(for: fileId), token: token)
    }

    private func fetchItemMetadata(path: String, token: String) async throws -> CloudFileMetadata {
        let item: OneDriveDriveItem = try await decodedGraphResponse(
            OneDriveDriveItem.self,
            request: authorizedRequest(
                url: try Self.graphURL(
                    path: path,
                    queryItems: [
                        URLQueryItem(name: "$select", value: Self.metadataSelectList),
                    ]
                ),
                token: token
            )
        )

        guard item.file != nil else {
            throw CloudProviderError.fileNotFound
        }

        return Self.makeCloudFileMetadata(from: item)
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        let token = try await accessToken(accountId: accountId)
        // Overwriting an existing file only needs `If-Match` for concurrency, so
        // a small database can take the single-request PUT and skip the flaky
        // `createUploadSession` endpoint entirely. Create-only uploads cannot:
        // they depend on `@microsoft.graph.conflictBehavior: fail`, which the
        // simple PUT has no equivalent for. See `createFile(...)`.
        let item: OneDriveDriveItem
        if Self.shouldUseSimpleUpload(byteCount: data.count) {
            item = try await uploadUsingSimplePut(
                path: fileId,
                data: data,
                expectedRev: expectedRev,
                token: token,
                progress: progress
            )
        } else {
            item = try await uploadUsingSession(
                path: fileId,
                data: data,
                expectedRev: expectedRev,
                conflictBehavior: "replace",
                token: token,
                progress: progress
            )
        }
        return await metadataAfterUpload(uploadedItem: item, token: token)
    }

    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        let token = try await accessToken(accountId: accountId)
        // Create-only semantics are required here (see `Cloud/CLAUDE.md`), and
        // only the upload-session body carries
        // `@microsoft.graph.conflictBehavior: fail`. Never route this through
        // the simple PUT, which would silently overwrite an existing file.
        let item = try await uploadUsingSession(
            path: path,
            data: data,
            expectedRev: nil,
            conflictBehavior: "fail",
            token: token,
            progress: progress
        )

        guard let file = Self.makeCloudFile(from: item) else {
            throw CloudProviderError.unknown(String(localized: "OneDrive upload did not return a file."))
        }

        return CloudCreatedFile(
            file: file,
            metadata: await metadataAfterUpload(uploadedItem: item, token: token)
        )
    }

    /// Re-reads the committed item so the stored rev/hash come from the same
    /// `$select`ed request shape as `getMetadata`; the upload response's shape
    /// differs and OneDrive can omit `cTag`/`eTag`/`hashes` from it.
    private func metadataAfterUpload(uploadedItem: OneDriveDriveItem, token: String) async -> CloudFileMetadata {
        await Self.resolveUploadMetadata(fallback: Self.makeCloudFileMetadata(from: uploadedItem)) {
            try await self.fetchItemMetadata(path: Self.itemIdPath(for: uploadedItem.id), token: token)
        }
    }

    /// The upload has already committed when this runs, so a failed re-read
    /// must not report the save as failed — fall back to the upload response's
    /// metadata. Internal for testing.
    static func resolveUploadMetadata(
        fallback: CloudFileMetadata,
        fetchAuthoritative: () async throws -> CloudFileMetadata
    ) async -> CloudFileMetadata {
        (try? await fetchAuthoritative()) ?? fallback
    }

    @MainActor
    func handleRedirectURL(_ url: URL) -> Bool {
        #if os(iOS)
        MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
        #else
        // MSAL compiles `handleMSALResponse` only for TARGET_OS_IPHONE. On
        // macOS interactive auth runs inside an ASWebAuthenticationSession /
        // WKWebView that intercepts the msauth redirect internally, and there
        // is no broker round-trip that re-enters the app, so there is nothing
        // to forward here. Returning false lets other URL handlers run.
        false
        #endif
    }

    // MARK: - Authentication

    private func application() throws -> MSALPublicClientApplication {
        if let cached = state.withLockUnchecked({ $0.application }) {
            return cached
        }

        guard let clientID else {
            throw CloudProviderError.invalidConfiguration
        }

        guard let authorityURL = URL(string: "https://login.microsoftonline.com/consumers") else {
            throw CloudProviderError.invalidConfiguration
        }
        let authority = try MSALAADAuthority(url: authorityURL)
        let configuration = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: redirectURI,
            authority: authority
        )
        // Built outside the lock because the MSAL initializer throws and does
        // I/O. Two racing callers can each build one; the first instance
        // published wins, so every caller shares a single MSAL token cache.
        let application = try MSALPublicClientApplication(configuration: configuration)
        return state.withLockUnchecked { state in
            if let cached = state.application {
                return cached
            }
            state.application = application
            return application
        }
    }

    /// Claims the single interactive-auth slot. `false` means a sign-in is
    /// already running and this caller must not start another.
    private func beginInteractiveAuthentication() -> Bool {
        state.withLockUnchecked { state in
            guard state.isAuthenticating == false else { return false }
            state.isAuthenticating = true
            return true
        }
    }

    private func endInteractiveAuthentication() {
        state.withLockUnchecked { $0.isAuthenticating = false }
    }

    private var clientID: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "OneDriveClientID") as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "$(ONEDRIVE_CLIENT_ID)",
              trimmed != "ONEDRIVE_CLIENT_ID",
              trimmed != "YOUR_ONEDRIVE_CLIENT_ID",
              trimmed != "00000000-0000-0000-0000-000000000000" else {
            return nil
        }

        return trimmed
    }

    private var redirectURI: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "OneDriveRedirectURI") as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func acquireToken(
        application: MSALPublicClientApplication,
        parameters: MSALInteractiveTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: Self.mapMSALError(error))
                }
            }
        }
    }

    /// Returns a bearer token for `accountId`, coalescing concurrent callers:
    /// one in-flight acquisition per account. MSAL documents no dedup or
    /// thread-safety for simultaneous `acquireTokenSilent` calls, and
    /// Microsoft refresh tokens are rolling, so two redemptions racing on one
    /// account can invalidate each other and force an interactive sign-in.
    private func accessToken(accountId: String) async throws -> String {
        let application = try application()
        let account: MSALAccount
        do {
            account = try application.account(forIdentifier: accountId)
        } catch {
            throw CloudProviderError.notAuthenticated
        }

        let (task, isOwner) = state.withLockUnchecked { state -> (Task<String, Error>, Bool) in
            if let existing = state.silentTokenTasks[accountId] {
                return (existing, false)
            }

            // Unstructured on purpose: it must outlive a caller that gets
            // cancelled, otherwise the other waiters lose their token.
            let task = Task {
                try await Self.acquireTokenSilently(application: application, account: account)
            }
            state.silentTokenTasks[accountId] = task
            return (task, true)
        }

        defer {
            if isOwner {
                state.withLockUnchecked { $0.silentTokenTasks[accountId] = nil }
            }
        }

        return try await task.value
    }

    private static func acquireTokenSilently(
        application: MSALPublicClientApplication,
        account: MSALAccount
    ) async throws -> String {
        let parameters = MSALSilentTokenParameters(scopes: scopes, account: account)
        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: mapMSALError(error))
                }
            }
        }
        return result.accessToken
    }

    #if os(iOS)
    @MainActor
    private func presentingController(from anchor: ASPresentationAnchor) -> UIViewController {
        topViewController(startingAt: anchor.rootViewController) ?? UIViewController()
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
    /// Builds the MSAL web-view presentation configuration for macOS.
    ///
    /// `MSALWebviewParameters(authPresentationViewController:)` accepts an
    /// `NSViewController` on macOS; it is derived from the anchor window's
    /// `contentViewController`. There is no MSAL broker on macOS, so
    /// interactive auth always uses the system web session presented from
    /// this controller. Internal (not private) so unit tests can assert the
    /// mac path produces a well-formed configuration.
    @MainActor
    static func makeWebviewParameters(from anchor: ASPresentationAnchor) -> MSALWebviewParameters {
        let controller = anchor.contentViewController
            ?? NSApplication.shared.keyWindow?.contentViewController
            ?? NSViewController()
        return MSALWebviewParameters(authPresentationViewController: controller)
    }
    #endif

    private func makeCloudAccount(from account: MSALAccount) -> CloudAccount {
        let accountID = account.identifier ?? account.username ?? UUID().uuidString
        let displayName = account.username ?? accountID
        return CloudAccount(id: accountID, displayName: displayName, provider: id)
    }

    // MARK: - Graph requests

    /// Single-request upload for small files: `PUT .../content`.
    ///
    /// This deliberately bypasses `createUploadSession`, whose two-request
    /// handshake buys nothing for a file that fits in one request and which
    /// intermittently rejects well-formed requests with HTTP 400
    /// `invalidRequest`. Overwrite-only — concurrency is still enforced with
    /// `If-Match`, but there is no create-only (`fail`) conflict behavior here.
    private func uploadUsingSimplePut(
        path: String,
        data: Data,
        expectedRev: String?,
        token: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> OneDriveDriveItem {
        guard data.isEmpty == false else {
            throw CloudProviderError.unknown(String(localized: "OneDrive cannot upload an empty database."))
        }

        var request = authorizedRequest(
            url: try Self.graphURL(path: Self.contentPath(for: path)),
            method: "PUT",
            token: token
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let expectedRev {
            request.setValue(expectedRev, forHTTPHeaderField: "If-Match")
        }
        request.httpBody = data

        let item: OneDriveDriveItem = try await decodedGraphResponse(
            OneDriveDriveItem.self,
            request: request
        )
        progress(1)
        return item
    }

    private func uploadUsingSession(
        path: String,
        data: Data,
        expectedRev: String?,
        conflictBehavior: String,
        token: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> OneDriveDriveItem {
        guard data.isEmpty == false else {
            throw CloudProviderError.unknown(String(localized: "OneDrive cannot upload an empty database."))
        }

        let session = try await createUploadSession(
            path: path,
            expectedRev: expectedRev,
            conflictBehavior: conflictBehavior,
            token: token
        )

        guard let uploadURL = URL(string: session.uploadURL) else {
            throw CloudProviderError.unknown(String(localized: "OneDrive returned an invalid upload URL."))
        }

        var offset = 0
        var completedItem: OneDriveDriveItem?
        // Counts *consecutive* failures at the current offset; a chunk that
        // lands clears it, so a long upload is not capped at three hiccups
        // overall.
        var attempt = 0

        while offset < data.count {
            let end = min(offset + Self.uploadChunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            var chunkRequest = URLRequest(url: uploadURL)
            chunkRequest.httpMethod = "PUT"
            chunkRequest.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
            chunkRequest.setValue("bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            chunkRequest.httpBody = chunk
            // No `Authorization` on the pre-authenticated upload URL: Graph
            // documents that including it can fail the PUT with HTTP 401.

            let responseData: Data
            let httpResponse: HTTPURLResponse
            do {
                (responseData, httpResponse) = try await send(chunkRequest)
            } catch {
                // The connection dropped mid-chunk. The session outlives it, so
                // the bytes already stored are still usable; only the abandoned
                // request is lost.
                attempt += 1
                guard attempt < Self.requestMaxAttempts else {
                    await cancelUploadSession(at: uploadURL)
                    throw error
                }

                try await Task.sleep(for: Self.retryDelay(forAttempt: attempt, retryAfter: nil))
                offset = await synchronizedOffset(for: uploadURL, fallback: offset, totalBytes: data.count)
                continue
            }

            switch httpResponse.statusCode {
            case 200, 201:
                do {
                    completedItem = try decoder.decode(OneDriveDriveItem.self, from: responseData)
                } catch let decodingError as DecodingError {
                    await cancelUploadSession(at: uploadURL)
                    throw CloudProviderError.unknown(String(describing: decodingError))
                }
            case 202:
                break
            default:
                attempt += 1
                guard Self.shouldRetryUploadChunk(statusCode: httpResponse.statusCode, attempt: attempt) else {
                    let mappedError = mapHTTPError(statusCode: httpResponse.statusCode, data: responseData)
                    await cancelUploadSession(at: uploadURL)
                    throw mappedError
                }

                try await Task.sleep(
                    for: Self.retryDelay(
                        forAttempt: attempt,
                        retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
                    )
                )
                // Never blindly resend: the service may already hold some or all
                // of this range, and resending it earns a 416.
                offset = await synchronizedOffset(for: uploadURL, fallback: offset, totalBytes: data.count)
                continue
            }

            offset = end
            attempt = 0
            progress(Double(offset) / Double(data.count))
        }

        guard let completedItem else {
            await cancelUploadSession(at: uploadURL)
            throw CloudProviderError.unknown(String(localized: "OneDrive upload did not complete."))
        }
        return completedItem
    }

    /// Re-anchors the upload offset on the service's own view of the session:
    /// `GET uploadUrl` reports the ranges it has not received, and resumption
    /// starts at the lowest. On failure returns `fallback`, re-sending the
    /// failed chunk — worst case a 416 and another status read next pass.
    private func synchronizedOffset(for uploadURL: URL, fallback: Int, totalBytes: Int) async -> Int {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "GET"

        guard let (data, httpResponse) = try? await send(request),
              (200..<300).contains(httpResponse.statusCode),
              let status = try? decoder.decode(OneDriveUploadSessionStatus.self, from: data),
              let ranges = status.nextExpectedRanges,
              let offset = Self.resumeOffset(fromNextExpectedRanges: ranges, totalBytes: totalBytes) else {
            return fallback
        }

        return offset
    }

    /// Best-effort `DELETE uploadUrl`. An abandoned session holds its partial
    /// bytes until `expirationDateTime`, and on a create-only upload keeps the
    /// destination name reserved. Result discarded on purpose: a failed cancel
    /// must not mask the error that caused the abort.
    private func cancelUploadSession(at uploadURL: URL) async {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Creates an upload session, retrying transient failures.
    ///
    /// The POST reserves an upload URL but commits no bytes, so it is
    /// side-effect free and safe to repeat. OneDrive is known to answer
    /// well-formed requests with a spurious HTTP 400 `invalidRequest`
    /// (https://github.com/OneDrive/onedrive-api-docs/issues/1064), which used
    /// to surface as a failed save that succeeded on a manual retry; Microsoft's
    /// own best-practice guidance for this endpoint is to retry transient
    /// failures.
    ///
    /// **Known unguarded window.** `If-Match` is validated here, at session
    /// creation, but the replace happens when the last chunk lands, so a
    /// remote write inside that window is overwritten silently. Graph's only
    /// revalidate-at-commit path is `deferCommit: true`, whose personal-drive
    /// commit is reported broken for exactly this case
    /// (https://github.com/OneDrive/onedrive-api-docs/issues/1616, open since
    /// 2022). Bounded in practice: overwrites at or below
    /// `simpleUploadByteLimit` never reach this path, and cover essentially
    /// every KDBX database.
    private func createUploadSession(
        path: String,
        expectedRev: String?,
        conflictBehavior: String,
        token: String
    ) async throws -> OneDriveUploadSession {
        let url = try Self.graphURL(path: Self.uploadSessionPath(for: path))
        let body = try JSONSerialization.data(
            withJSONObject: [
                "item": [
                    "@microsoft.graph.conflictBehavior": conflictBehavior,
                    "name": (path as NSString).lastPathComponent,
                ],
            ],
            options: []
        )

        var attempt = 0
        while true {
            attempt += 1

            var request = authorizedRequest(url: url, method: "POST", token: token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let expectedRev {
                request.setValue(expectedRev, forHTTPHeaderField: "If-Match")
            }
            request.httpBody = body

            let (responseData, httpResponse) = try await send(request)

            if (200..<300).contains(httpResponse.statusCode) {
                do {
                    return try decoder.decode(OneDriveUploadSession.self, from: responseData)
                } catch let decodingError as DecodingError {
                    throw CloudProviderError.unknown(String(describing: decodingError))
                }
            }

            let errorCode = (try? decoder.decode(OneDriveErrorResponse.self, from: responseData))?.error.code
            guard Self.shouldRetryUploadSessionCreation(
                statusCode: httpResponse.statusCode,
                errorCode: errorCode,
                attempt: attempt
            ) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: responseData)
            }

            try await Task.sleep(
                for: Self.retryDelay(
                    forAttempt: attempt,
                    retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
    }

    /// Whether a failed Graph request should be tried again. `attempt` is
    /// 1-based and counts the attempt that just failed. Auth, permission,
    /// not-found, and concurrency failures are deterministic, and retrying a
    /// 409/412 would paper over a genuine conflict; what is left is throttling
    /// and server errors. No retried request is an unguarded write: reads are
    /// idempotent, the simple `PUT` carries `If-Match`, the session POST
    /// commits no bytes, and a chunk `PUT` is re-anchored against
    /// `nextExpectedRanges` first. Internal for testing.
    static func shouldRetryRequest(
        statusCode: Int,
        attempt: Int,
        maxAttempts: Int = requestMaxAttempts
    ) -> Bool {
        guard attempt >= 1, attempt < maxAttempts else {
            return false
        }

        switch statusCode {
        case 401, 403, 404, 409, 412:
            return false
        case 429:
            return true
        case 500..<600:
            return true
        default:
            return false
        }
    }

    /// Whether a failed `createUploadSession` POST should be tried again.
    /// `shouldRetryRequest`'s policy plus one endpoint-specific case: OneDrive
    /// answers well-formed session-creation requests with a spurious HTTP 400
    /// `invalidRequest` (https://github.com/OneDrive/onedrive-api-docs/issues/1064).
    /// Safe to repeat only here, where the POST commits no bytes. Matches on
    /// the Graph error *code*, never the message. Internal for testing.
    static func shouldRetryUploadSessionCreation(
        statusCode: Int,
        errorCode: String?,
        attempt: Int
    ) -> Bool {
        guard statusCode != 400 else {
            guard attempt >= 1, attempt < uploadSessionCreationMaxAttempts else {
                return false
            }
            return errorCode?.caseInsensitiveCompare("invalidRequest") == .orderedSame
        }

        return shouldRetryRequest(
            statusCode: statusCode,
            attempt: attempt,
            maxAttempts: uploadSessionCreationMaxAttempts
        )
    }

    /// Whether a failed chunk `PUT` can be resumed. Adds 416 to the shared
    /// transient set: Graph answers 416 when the client resends bytes the
    /// service already holds, fixed by resyncing against `nextExpectedRanges`
    /// rather than failing the save. Internal for testing.
    static func shouldRetryUploadChunk(statusCode: Int, attempt: Int) -> Bool {
        guard statusCode != 416 else {
            return attempt >= 1 && attempt < requestMaxAttempts
        }

        return shouldRetryRequest(statusCode: statusCode, attempt: attempt)
    }

    /// Backoff before retrying a Graph request: ~0.5s, then ~1.5s. A
    /// server-supplied `Retry-After` (seconds) wins when present, clamped so a
    /// bad header cannot stall the save. Internal for testing.
    static func retryDelay(forAttempt attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter,
           let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)),
           seconds > 0 {
            return .seconds(min(seconds, maxRetryAfterSeconds))
        }

        return .seconds(0.5 * pow(3.0, Double(max(attempt, 1) - 1)))
    }

    /// Byte offset to resume an interrupted upload session from. The service
    /// may list several gaps and does not promise to list them all, so the
    /// only safe resumption point is the lowest missing byte. `nil` when the
    /// payload is complete or the ranges will not parse, leaving the caller on
    /// its own offset. Internal for testing.
    static func resumeOffset(fromNextExpectedRanges ranges: [String], totalBytes: Int) -> Int? {
        let starts = ranges.compactMap { range -> Int? in
            let start = range.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
            guard let start, let offset = Int(start.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return (0..<totalBytes).contains(offset) ? offset : nil
        }

        return starts.min()
    }

    /// Whether an overwrite of this size can take the single-request PUT.
    /// Internal for testing.
    static func shouldUseSimpleUpload(byteCount: Int) -> Bool {
        byteCount <= simpleUploadByteLimit
    }

    /// Issues one Graph request, normalizing transport failures.
    private func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudProviderError.unknown(String(localized: "OneDrive request failed."))
            }
            return (data, httpResponse)
        } catch let error as CloudProviderError {
            throw error
        } catch {
            throw Self.mapGenericError(error)
        }
    }

    /// Issues a Graph request, retrying throttling and server errors with
    /// capped exponential backoff that honors `Retry-After`.
    private func sendRetrying(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1

            let (data, httpResponse) = try await send(request)
            if (200..<300).contains(httpResponse.statusCode) {
                return data
            }

            guard Self.shouldRetryRequest(statusCode: httpResponse.statusCode, attempt: attempt) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            try await Task.sleep(
                for: Self.retryDelay(
                    forAttempt: attempt,
                    retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
    }

    /// Downloads to a temporary file, retrying throttling and server errors.
    /// The caller owns the returned URL; every discarded body is unlinked here
    /// so a retried download cannot leak temp files.
    private func downloadRetrying(_ request: URLRequest) async throws -> URL {
        var attempt = 0
        while true {
            attempt += 1

            let temporaryURL: URL
            let httpResponse: HTTPURLResponse
            do {
                let (url, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse else {
                    try? FileManager.default.removeItem(at: url)
                    throw CloudProviderError.unknown(String(localized: "OneDrive download failed."))
                }
                temporaryURL = url
                httpResponse = http
            } catch let error as CloudProviderError {
                throw error
            } catch {
                throw Self.mapGenericError(error)
            }

            if (200..<300).contains(httpResponse.statusCode) {
                return temporaryURL
            }

            let body = try? Data(contentsOf: temporaryURL)
            try? FileManager.default.removeItem(at: temporaryURL)

            guard Self.shouldRetryRequest(statusCode: httpResponse.statusCode, attempt: attempt) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: body)
            }

            try await Task.sleep(
                for: Self.retryDelay(
                    forAttempt: attempt,
                    retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
    }

    private func decodedGraphResponse<T: Decodable>(
        _ type: T.Type,
        request: URLRequest
    ) async throws -> T {
        let data = try await sendRetrying(request)
        do {
            return try decoder.decode(type, from: data)
        } catch let decodingError as DecodingError {
            throw CloudProviderError.unknown(String(describing: decodingError))
        }
    }

    private func authorizedRequest(
        url: URL,
        method: String = "GET",
        token: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds a Graph URL from an **already percent-encoded** path.
    ///
    /// Every caller passes a path built with `encodedGraphPath(_:)`, so the
    /// string must be used verbatim. `URL.appendingPathComponent` would encode
    /// it a second time (`My%20Vault.kdbx` → `My%2520Vault.kdbx`), which broke
    /// listing, metadata, download, and upload for any OneDrive path containing
    /// a space, `&`, `#`, or non-ASCII character. `URL(string:)` and
    /// `URLComponents.percentEncodedPath` both preserve existing encoding.
    /// Internal for testing.
    static func graphURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let absolutePath = path.hasPrefix("/") ? path : "/\(path)"
        guard let baseURL = URL(string: Self.graphBaseURLString + absolutePath),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CloudProviderError.invalidConfiguration
        }

        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw CloudProviderError.invalidConfiguration
        }
        return url
    }

    // The four path builders below are pure and `static`/internal so tests can
    // pin the full cloud-path → percent-encoded → Graph URL pipeline.

    static func listChildrenPath(for path: String?) -> String {
        let normalized = normalizedCloudPath(path)
        guard normalized != "/" else {
            return "me/drive/root/children"
        }
        return "me/drive/root:\(encodedGraphPath(normalized)):/children"
    }

    static func itemPath(for path: String) -> String {
        "me/drive/root:\(encodedGraphPath(normalizedCloudPath(path))):"
    }

    /// Addresses an item by its Graph item id (as returned in an upload
    /// response), immune to concurrent renames of the path.
    static func itemIdPath(for itemId: String) -> String {
        "me/drive/items/\(itemId)"
    }

    static func contentPath(for path: String) -> String {
        "me/drive/root:\(encodedGraphPath(normalizedCloudPath(path))):/content"
    }

    static func uploadSessionPath(for path: String) -> String {
        "me/drive/root:\(encodedGraphPath(normalizedCloudPath(path))):/createUploadSession"
    }

    private func filter(files: [CloudFile], query: String?) -> [CloudFile] {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              query.isEmpty == false else {
            return files
        }

        let loweredQuery = query.lowercased()
        return files.filter { file in
            file.name.lowercased().contains(loweredQuery)
                || file.path.lowercased().contains(loweredQuery)
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data?) -> Error {
        let error = data.flatMap { try? decoder.decode(OneDriveErrorResponse.self, from: $0) }?.error
        return Self.mapGraphError(
            statusCode: statusCode,
            errorCode: error?.code,
            message: error?.message
        )
    }

    /// Maps a Graph failure onto a provider error. The decoded `code` leads
    /// and the status is only the fallback: a 403 is `accessDenied` far more
    /// often than a missing scope, and a full drive arrives as HTTP 507 or
    /// `quotaLimitReached`, not as the word "quota" in a 400 message.
    /// Internal for testing.
    static func mapGraphError(statusCode: Int, errorCode: String?, message: String?) -> CloudProviderError {
        switch errorCode?.lowercased() {
        case "quotalimitreached", "insufficientstorage", "storagelimitreached":
            return .insufficientSpace
        case "accessdenied", "notallowed":
            return .permissionDenied
        case "unauthenticated", "invalidauthenticationtoken", "expiredauthtoken":
            return .notAuthenticated
        case "authorizationrequestdenied", "insufficientscope", "insufficientpermissions":
            return .writeScopeRequired
        case "namealreadyexists", "resourcemodified":
            return .conflict(remoteRev: nil)
        case "itemnotfound":
            return .fileNotFound
        case "activitylimitreached":
            return .rateLimited
        case "servicenotavailable":
            return .serviceUnavailable
        case "invalidrequest" where isNameShapedFailure(message: message):
            return .invalidName
        default:
            break
        }

        switch statusCode {
        case 401:
            return .notAuthenticated
        case 403:
            return .permissionDenied
        case 404:
            return .fileNotFound
        case 409, 412:
            return .conflict(remoteRev: nil)
        case 429:
            return .rateLimited
        case 507:
            return .insufficientSpace
        case 500..<600:
            return .serviceUnavailable
        default:
            return .unknown(message ?? String(localized: "OneDrive request failed with HTTP \(statusCode)."))
        }
    }

    /// Whether a Graph `invalidRequest` is complaining about the file name.
    /// Graph has no dedicated code for an illegal name, so only the
    /// always-English message says so. Deliberately narrow — anything that
    /// does not clearly read as a name complaint falls through to the raw
    /// message rather than being mislabeled. Internal for testing.
    static func isNameShapedFailure(message: String?) -> Bool {
        guard let message, message.localizedCaseInsensitiveContains("name") else {
            return false
        }

        let markers = ["invalid", "illegal", "not allowed", "disallowed", "character"]
        return markers.contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func mapMSALError(_ error: Error?) -> Error {
        guard let error else {
            return CloudProviderError.unknown(String(localized: "OneDrive sign-in failed."))
        }

        let nsError = error as NSError
        if nsError.domain == MSALErrorDomain,
           nsError.code == MSALError.userCanceled.rawValue {
            return CloudProviderError.authenticationCancelled
        }

        if nsError.domain == MSALErrorDomain,
           nsError.code == MSALError.interactionRequired.rawValue {
            return CloudProviderError.notAuthenticated
        }

        return CloudProviderError.unknown(nsError.localizedDescription)
    }

    /// Maps a transport failure onto a provider error. Only genuinely
    /// connectivity-shaped `NSURLErrorDomain` codes become
    /// `.networkUnavailable`: collapsing the whole domain reported a TLS or
    /// certificate rejection as "no network connection", hiding a
    /// security-relevant error behind a cached-copy fallback. Internal for
    /// testing.
    static func mapGenericError(_ error: Error) -> Error {
        if CloudProviderError.isLikelyOffline(error) {
            return CloudProviderError.networkUnavailable
        }
        return CloudProviderError.unknown((error as NSError).localizedDescription)
    }

    private static func makeCloudFile(from item: OneDriveDriveItem) -> CloudFile? {
        let isFolder = item.folder != nil
        if !isFolder {
            guard item.name.lowercased().hasSuffix(".kdbx") else { return nil }
        }

        let path = displayPath(for: item)
        return CloudFile(
            id: path,
            name: item.name,
            path: path,
            isFolder: isFolder,
            modifiedDate: item.lastModifiedDateTime,
            size: item.size
        )
    }

    private static func makeCloudFileMetadata(from item: OneDriveDriveItem) -> CloudFileMetadata {
        CloudFileMetadata(
            modifiedDate: item.lastModifiedDateTime ?? .now,
            contentHash: taggedContentHash(
                quickXorHash: item.file?.hashes?.quickXorHash,
                sha1Hash: item.file?.hashes?.sha1Hash
            ),
            size: item.size ?? 0,
            rev: item.cTag ?? item.eTag
        )
    }

    /// Prefers `quickXorHash`, the only hash Graph guarantees on both Personal
    /// and Business drives, and tags the algorithm into the opaque token so
    /// hashes of different algorithms can never compare equal. Internal for
    /// testing.
    static func taggedContentHash(quickXorHash: String?, sha1Hash: String?) -> String? {
        if let quickXorHash {
            return "quickXor:\(quickXorHash)"
        }
        if let sha1Hash {
            return "sha1:\(sha1Hash)"
        }
        return nil
    }

    private static func displayPath(for item: OneDriveDriveItem) -> String {
        let parentPath = item.parentReference?.path ?? "/drive/root:"
        let parentAfterRoot = parentPath.range(of: "root:").map { range in
            String(parentPath[range.upperBound...])
        } ?? parentPath
        let strippedParent = parentAfterRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if strippedParent.isEmpty {
            return "/\(item.name)"
        }
        return "/\(strippedParent)/\(item.name)"
    }

    private static func sortCloudFiles(_ lhs: CloudFile, _ rhs: CloudFile) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func normalizedCloudPath(_ path: String?) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "/" else {
            return "/"
        }

        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/\(withoutTrailingSlash)"
    }

    private static func encodedGraphPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: graphPathAllowedCharacters) ?? String(segment)
            }
            .joined(separator: "/")
            .prependingSlash()
    }

    private static let graphPathAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":?#[]@!$&'()*+,;=%")
        return allowed
    }()

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension String {
    func prependingSlash() -> String {
        hasPrefix("/") ? self : "/\(self)"
    }
}

private struct OneDriveCollectionResponse: Decodable {
    let value: [OneDriveDriveItem]
    let nextLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct OneDriveDriveItem: Decodable {
    let id: String
    let name: String
    let size: Int64?
    let eTag: String?
    let cTag: String?
    let lastModifiedDateTime: Date?
    let folder: OneDriveFolderFacet?
    let file: OneDriveFileFacet?
    let parentReference: OneDriveParentReference?
}

private struct OneDriveFolderFacet: Decodable {}

private struct OneDriveFileFacet: Decodable {
    let hashes: OneDriveHashes?
}

private struct OneDriveHashes: Decodable {
    let sha1Hash: String?
    let quickXorHash: String?
}

private struct OneDriveParentReference: Decodable {
    let path: String?
}

private struct OneDriveUploadSession: Decodable {
    let uploadURL: String

    private enum CodingKeys: String, CodingKey {
        case uploadURL = "uploadUrl"
    }
}

/// `GET uploadUrl` response: the byte ranges the service has *not* received.
private struct OneDriveUploadSessionStatus: Decodable {
    let nextExpectedRanges: [String]?
}

private struct OneDriveErrorResponse: Decodable {
    let error: OneDriveError
}

private struct OneDriveError: Decodable {
    let code: String?
    let message: String
}
