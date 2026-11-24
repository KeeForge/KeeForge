#if os(iOS)
@preconcurrency import AppAuth
import AuthenticationServices
import Foundation
import UIKit

final class GoogleDriveCredentialStore: @unchecked Sendable {
    struct Snapshot { let data: Data?; let generation: UInt64; let lifetime: UInt64 }
    private let lock = NSLock()
    // Archive writes advance generation; only reconnect or signout invalidates token lifetimes.
    private var generations: [String: UInt64] = [:]
    private var lifetimes: [String: UInt64] = [:]
    private var signedOutAccounts = Set<String>()
    private var authorizationEpoch: UInt64 = 0
    private static let tombstone = Data("KeeForge.GoogleDrive.signed-out.v1".utf8)
    private let read: @Sendable (String) -> Data?
    private let write: @Sendable (Data, String) -> Bool
    private let delete: @Sendable (String) -> Bool

    init(
        read: @escaping @Sendable (String) -> Data? = { CloudTokenStore.tokenData(provider: "googledrive", accountId: $0) },
        write: @escaping @Sendable (Data, String) -> Bool = { CloudTokenStore.setTokenData($0, provider: "googledrive", accountId: $1) },
        delete: @escaping @Sendable (String) -> Bool = { CloudTokenStore.deleteToken(provider: "googledrive", accountId: $0) }
    ) { self.read = read; self.write = write; self.delete = delete }

    func snapshot(_ accountID: String) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let data = signedOutAccounts.contains(accountID) ? nil : read(accountID)
        return Snapshot(data: data == Self.tombstone ? nil : data, generation: generations[accountID, default: 0], lifetime: lifetimes[accountID, default: 0])
    }

    var authorizationGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return authorizationEpoch
    }

    func save(_ data: Data, accountID: String, generation: UInt64, lifetime: UInt64? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generations[accountID, default: 0] == generation,
              lifetime == nil || lifetime == lifetimes[accountID, default: 0] else { return false }
        guard write(data, accountID) else { return false }
        generations[accountID, default: 0] &+= 1
        signedOutAccounts.remove(accountID)
        return true
    }

    func saveAuthorization(_ data: Data, accountID: String, expectedLifetime: UInt64?, authorizationGeneration: UInt64, registered: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard authorizationGeneration == authorizationEpoch,
              expectedLifetime == nil || expectedLifetime == lifetimes[accountID, default: 0] else { return false }
        guard write(data, accountID) else { return false }
        generations[accountID, default: 0] &+= 1
        lifetimes[accountID, default: 0] &+= 1
        authorizationEpoch &+= 1
        signedOutAccounts.remove(accountID)
        registered()
        return true
    }

    @discardableResult
    func remove(_ accountID: String, ifGeneration: UInt64? = nil, removed: () -> Void = {}) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let ifGeneration, generations[accountID, default: 0] != ifGeneration { return false }
        generations[accountID, default: 0] &+= 1
        lifetimes[accountID, default: 0] &+= 1
        authorizationEpoch &+= 1
        signedOutAccounts.insert(accountID)
        removed()
        if delete(accountID) { return true }
        // A tombstone in the same Keychain row survives relaunch if deletion is refused.
        return write(Self.tombstone, accountID)
    }
}

struct GoogleDriveConfiguration: Sendable, Equatable {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    let clientID: String
    let redirectURL: URL

    init?(clientID: String?, scheme: String?) {
        guard let clientID, clientID.wholeMatch(of: /[A-Za-z0-9-]+\.apps\.googleusercontent\.com/) != nil,
              let scheme, scheme == clientID.split(separator: ".").reversed().joined(separator: "."),
              let redirectURL = URL(string: scheme + ":/oauthredirect") else { return nil }
        self.clientID = clientID
        self.redirectURL = redirectURL
    }

    static func load(bundle: Bundle = .main) -> Self? {
        guard bundle.object(forInfoDictionaryKey: "GoogleDriveEnabled") as? String == "YES" else { return nil }
        return Self(clientID: bundle.object(forInfoDictionaryKey: "GoogleDriveClientID") as? String,
             scheme: bundle.object(forInfoDictionaryKey: "GoogleDriveRedirectScheme") as? String)
    }
}

struct GoogleDriveToken: Sendable {
    let accessToken: String
    let archive: Data
}

@MainActor
final class GoogleDriveAuthorization {
    struct Grant: Sendable {
        let token: GoogleDriveToken
        let fileID: String
    }

    typealias Present = @MainActor @Sendable (ASPresentationAnchor, GoogleDriveConfiguration, String?) async throws -> Grant
    typealias Refresh = @MainActor @Sendable (Data, GoogleDriveConfiguration) async throws -> GoogleDriveToken

    @MainActor
    private final class TokenRefresh {
        let generation: UInt64
        private var result: Result<String, Error>?
        private var waiters: [UUID: CheckedContinuation<String, Error>] = [:]

        init(generation: UInt64) {
            self.generation = generation
        }

        func value() async throws -> String {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let result {
                        continuation.resume(with: result)
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }

        func finish(_ result: Result<String, Error>) {
            self.result = result
            let waiting = waiters.values
            waiters.removeAll()
            for waiter in waiting { waiter.resume(with: result) }
        }
    }

    nonisolated let configuration: GoogleDriveConfiguration?
    private nonisolated let credentials: GoogleDriveCredentialStore
    private let present: Present?
    private let refresh: Refresh
    private var attempt: UUID?
    private var pendingSession: (any OIDExternalUserAgentSession)?
    private var refreshes: [String: TokenRefresh] = [:]

    nonisolated init(configuration: GoogleDriveConfiguration? = .load(),
                     credentials: GoogleDriveCredentialStore = GoogleDriveCredentialStore(),
                     present: Present? = nil,
                     refresh: @escaping Refresh = GoogleDriveAuthorization.refreshCredential) {
        self.configuration = configuration
        self.credentials = credentials
        self.present = present
        self.refresh = refresh
    }

    nonisolated func contains(accountID: String) -> Bool {
        configuration != nil && credentials.snapshot(accountID).data != nil
    }

    nonisolated func signOut(accountID: String) {
        credentials.remove(accountID) {
            CloudAccountStore.remove(provider: CloudProviderKind.googleDrive.rawValue, accountId: accountID)
        }
    }

    func cancel() {
        attempt = nil
        let session = pendingSession
        pendingSession = nil
        session?.cancel()
    }

    func select(from anchor: ASPresentationAnchor, expected: CloudSyncMetadata?,
                verify: (Grant) async throws -> CloudDatabaseSelection) async throws -> CloudDatabaseSelection {
        guard let configuration else { throw CloudProviderError.invalidConfiguration }
        guard attempt == nil else { throw CloudProviderError.authenticationCancelled }
        try Task.checkCancellation()
        let id = UUID()
        let generation = credentials.authorizationGeneration
        let lifetime = expected.map { credentials.snapshot($0.accountId).lifetime }
        attempt = id
        defer { if attempt == id { cancel() } }
        return try await withTaskCancellationHandler {
            let grant: Grant
            do {
                if let present { grant = try await present(anchor, configuration, expected?.fileId) }
                else { grant = try await interactiveGrant(from: anchor, configuration: configuration, fileID: expected?.fileId) }
            } catch {
                throw Self.oauthError(error)
            }
            guard attempt == id else { throw CloudProviderError.authenticationCancelled }
            if let expected, grant.fileID != expected.fileId { throw CloudProviderError.permissionDenied }
            let selection = try await verify(grant)
            try Task.checkCancellation()
            guard attempt == id else { throw CloudProviderError.authenticationCancelled }
            guard expected == nil || expected?.accountId == selection.account.id else { throw CloudProviderError.permissionDenied }
            let saved = credentials.saveAuthorization(grant.token.archive, accountID: selection.account.id,
                expectedLifetime: lifetime, authorizationGeneration: generation) {
                CloudAccountStore.upsert(selection.account)
            }
            guard saved else { throw CloudProviderError.notAuthenticated }
            return selection
        } onCancel: {
            Task { @MainActor in
                if self.attempt == id { self.cancel() }
            }
        }
    }

    func accessToken(accountID: String) async throws -> String {
        guard let configuration else { throw CloudProviderError.invalidConfiguration }
        try Task.checkCancellation()
        let snapshot = credentials.snapshot(accountID)
        guard let data = snapshot.data else { throw CloudProviderError.notAuthenticated }
        let request: TokenRefresh
        if let existing = refreshes[accountID], existing.generation == snapshot.generation {
            request = existing
        } else {
            request = TokenRefresh(generation: snapshot.generation)
            refreshes[accountID] = request
            // A cancelled caller leaves its wait while other callers keep the shared refresh.
            Task {
                defer { if refreshes[accountID] === request { refreshes[accountID] = nil } }
                do {
                    let refreshed = try await refresh(data, configuration)
                    guard credentials.save(refreshed.archive, accountID: accountID, generation: snapshot.generation) else {
                        throw CloudProviderError.notAuthenticated
                    }
                    request.finish(.success(refreshed.accessToken))
                } catch {
                    if Self.isInvalidGrant(error) { credentials.remove(accountID, ifGeneration: snapshot.generation) }
                    request.finish(.failure(Self.oauthError(error)))
                }
            }
        }
        let token = try await request.value()
        try Task.checkCancellation()
        let current = credentials.snapshot(accountID)
        guard current.data != nil, current.lifetime == snapshot.lifetime else { throw CloudProviderError.notAuthenticated }
        return token
    }

    static func authorizationRequest(configuration: GoogleDriveConfiguration, fileID: String?) throws -> OIDAuthorizationRequest {
        guard let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { throw CloudProviderError.invalidConfiguration }
        var parameters = ["prompt": "consent", "access_type": "offline", "trigger_onepick": "true"]
        if let fileID { parameters["file_ids"] = fileID }
        return OIDAuthorizationRequest(
            configuration: OIDServiceConfiguration(authorizationEndpoint: authorizationURL, tokenEndpoint: tokenURL),
            clientId: configuration.clientID, scopes: [GoogleDriveConfiguration.scope],
            redirectURL: configuration.redirectURL, responseType: OIDResponseTypeCode, additionalParameters: parameters)
    }

    private func interactiveGrant(from anchor: ASPresentationAnchor, configuration: GoogleDriveConfiguration,
                                  fileID: String?) async throws -> Grant {
        guard var host = anchor.rootViewController else { throw CloudProviderError.invalidConfiguration }
        while let presented = host.presentedViewController { host = presented }
        let request = try Self.authorizationRequest(configuration: configuration, fileID: fileID)
        let authState = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OIDAuthState, Error>) in
            pendingSession = OIDAuthState.authState(byPresenting: request, presenting: host, prefersEphemeralSession: true) { state, error in
                if let state { continuation.resume(returning: state) }
                else { continuation.resume(throwing: Self.oauthError(error)) }
            }
        }
        guard let picked = GoogleDrivePickerSelection.fileID(from: authState.lastAuthorizationResponse.additionalParameters),
              let token = authState.lastTokenResponse?.accessToken,
              authState.refreshToken?.isEmpty == false else { throw CloudProviderError.permissionDenied }
        try Self.checkScope(authState)
        return Grant(token: GoogleDriveToken(accessToken: token, archive: try Self.archive(authState)), fileID: picked)
    }

    private static func checkScope(_ state: OIDAuthState) throws {
        if let scope = state.scope, Set(scope.split(separator: " ").map(String.init)) != [GoogleDriveConfiguration.scope] {
            throw CloudProviderError.permissionDenied
        }
    }

    private static func archive(_ state: OIDAuthState) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
    }

    static func refreshCredential(_ archive: Data, configuration: GoogleDriveConfiguration) async throws -> GoogleDriveToken {
        guard let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive),
              state.lastAuthorizationResponse.request.clientID == configuration.clientID,
              state.lastAuthorizationResponse.request.redirectURL == configuration.redirectURL else {
            throw CloudProviderError.notAuthenticated
        }
        let token = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            state.performAction { token, _, error in
                if let token, !token.isEmpty { continuation.resume(returning: token) }
                else { continuation.resume(throwing: error ?? CloudProviderError.serviceUnavailable) }
            }
        }
        try checkScope(state)
        return GoogleDriveToken(accessToken: token, archive: try Self.archive(state))
    }

    nonisolated static func isInvalidGrant(_ error: Error) -> Bool {
        errorChain(error).contains { $0.domain == OIDOAuthTokenErrorDomain && $0.code == OIDErrorCodeOAuthToken.invalidGrant.rawValue }
    }

    private nonisolated static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, chain.count < 12 {
            chain.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    nonisolated static func oauthError(_ error: Error?) -> Error {
        guard let error else { return CloudProviderError.serviceUnavailable }
        if error is CancellationError || error is CloudProviderError { return error }
        if isInvalidGrant(error) { return CloudProviderError.notAuthenticated }
        for current in errorChain(error) {
            if CloudProviderError.isLikelyOffline(current) { return CloudProviderError.networkUnavailable }
            if current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled { return CancellationError() }
            if current.domain == OIDGeneralErrorDomain,
               [OIDErrorCode.userCanceledAuthorizationFlow.rawValue, OIDErrorCode.programCanceledAuthorizationFlow.rawValue].contains(current.code) {
                return CloudProviderError.authenticationCancelled
            }
            if current.domain == ASWebAuthenticationSessionError.errorDomain,
               current.code == ASWebAuthenticationSessionError.canceledLogin.rawValue { return CloudProviderError.authenticationCancelled }
        }
        return CloudProviderError.serviceUnavailable
    }
}
#endif
