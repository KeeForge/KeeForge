import AuthenticationServices
import Foundation
#if canImport(AppAuthCore)
@preconcurrency import AppAuthCore
#endif

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

    func saveAuthorization(_ data: Data, accountID: String, expectedLifetime: UInt64?, authorizationGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard authorizationGeneration == authorizationEpoch,
              expectedLifetime == nil || expectedLifetime == lifetimes[accountID, default: 0] else { return false }
        guard write(data, accountID) else { return false }
        generations[accountID, default: 0] &+= 1
        lifetimes[accountID, default: 0] &+= 1
        authorizationEpoch &+= 1
        signedOutAccounts.remove(accountID)
        return true
    }

    @discardableResult
    func remove(_ accountID: String, ifGeneration: UInt64? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let ifGeneration, generations[accountID, default: 0] != ifGeneration { return false }
        generations[accountID, default: 0] &+= 1
        lifetimes[accountID, default: 0] &+= 1
        authorizationEpoch &+= 1
        signedOutAccounts.insert(accountID)
        if delete(accountID) { return true }
        // A tombstone in the same Keychain row survives relaunch if deletion is refused.
        return write(Self.tombstone, accountID)
    }
}

struct GoogleDriveRefreshedCredential: Sendable {
    let accessToken: String
    let archive: Data
}

struct GoogleDriveInteractiveCredential: Sendable {
    let accessToken: String
    let archive: Data
    let pickedFileIDs: [String]
}

typealias GoogleDriveInteractiveAuthorization = @MainActor @Sendable (ASPresentationAnchor, GoogleDriveConfiguration) async throws -> GoogleDriveInteractiveCredential

typealias GoogleDriveCredentialRefresh = @MainActor @Sendable (Data, GoogleDriveConfiguration) async throws -> GoogleDriveRefreshedCredential

final class GoogleDriveAuthorization: GoogleDriveAuthorizing {
    private let configuration: GoogleDriveConfiguration?
    private let credentials: GoogleDriveCredentialStore
    private let transport: any GoogleDriveTransport
    private let refresh: GoogleDriveCredentialRefresh
    private let interactiveAuthorization: GoogleDriveInteractiveAuthorization?
    private let accountAuthorization: GoogleDriveInteractiveAuthorization?
    private let tokenDeliveryBarrier: (@MainActor @Sendable () async -> Void)?
    @MainActor private var refreshes: [String: (id: UUID, generation: UInt64, lifetime: UInt64, task: Task<String, Error>)] = [:]
    @MainActor private var attempt: UUID?
    #if canImport(AppAuthCore)
    @MainActor private var pendingSession: (any OIDExternalUserAgentSession)?
    #endif

    init(configuration: GoogleDriveConfiguration? = .load(), credentials: GoogleDriveCredentialStore = GoogleDriveCredentialStore(), transport: any GoogleDriveTransport = GoogleDriveURLSessionTransport(), refresh: @escaping GoogleDriveCredentialRefresh = GoogleDriveAuthorization.refreshCredential, interactiveAuthorization: GoogleDriveInteractiveAuthorization? = nil, accountAuthorization: GoogleDriveInteractiveAuthorization? = nil, tokenDeliveryBarrier: (@MainActor @Sendable () async -> Void)? = nil) {
        self.configuration = configuration
        self.credentials = credentials
        self.transport = transport
        self.refresh = refresh
        self.interactiveAuthorization = interactiveAuthorization
        self.accountAuthorization = accountAuthorization
        self.tokenDeliveryBarrier = tokenDeliveryBarrier
    }

    @MainActor var isConfigured: Bool {
        #if canImport(AppAuthCore)
        configuration != nil
        #else
        false
        #endif
    }

    func contains(accountID: String) -> Bool {
        #if canImport(AppAuthCore)
        configuration != nil && credentials.snapshot(accountID).data != nil
        #else
        false
        #endif
    }
    func remove(accountID: String) { credentials.remove(accountID) }

    @MainActor func cancel() {
        attempt = nil
        #if canImport(AppAuthCore)
        let session = pendingSession
        pendingSession = nil
        session?.cancel()
        #endif
    }

    @MainActor
    func authorizeAccount(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> CloudAccount {
        try await authorize(from: anchor, expectedAccountID: expectedAccountID, purpose: .account).account
    }

    @MainActor
    func authorize(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> GoogleDriveGrant {
        try await authorize(from: anchor, expectedAccountID: expectedAccountID, purpose: .fileSelection)
    }

    @MainActor
    private func authorize(from anchor: ASPresentationAnchor, expectedAccountID: String?, purpose: GoogleDriveAuthorizationPurpose) async throws -> GoogleDriveGrant {
        #if canImport(AppAuthCore)
        guard let configuration else { throw CloudProviderError.invalidConfiguration }
        guard attempt == nil else { throw CloudProviderError.authenticationCancelled }
        try Task.checkCancellation()
        let id = UUID()
        let expectedLifetime = expectedAccountID.map { credentials.snapshot($0).lifetime }
        let authorizationGeneration = credentials.authorizationGeneration
        attempt = id
        defer {
            if attempt == id { attempt = nil; pendingSession = nil }
        }
        return try await withTaskCancellationHandler {
            let credential: GoogleDriveInteractiveCredential
            if let operation = purpose == .account ? accountAuthorization : interactiveAuthorization {
                credential = try await operation(anchor, configuration)
            } else {
                credential = try await interactiveCredential(from: anchor, configuration: configuration, attemptID: id, purpose: purpose)
            }
            guard attempt == id else { throw CloudProviderError.authenticationCancelled }
            if purpose == .fileSelection {
                guard !credential.pickedFileIDs.isEmpty,
                      credential.pickedFileIDs.allSatisfy(GoogleDriveCallback.validID),
                      Set(credential.pickedFileIDs).count == credential.pickedFileIDs.count else {
                    throw CloudProviderError.permissionDenied
                }
            }
            let account = try await account(accessToken: credential.accessToken)
            try Self.checkAccount(account.id, expected: expectedAccountID)
            try Task.checkCancellation()
            guard attempt == id else { throw CloudProviderError.authenticationCancelled }
            guard credentials.saveAuthorization(credential.archive, accountID: account.id, expectedLifetime: expectedLifetime, authorizationGeneration: authorizationGeneration) else { throw CloudProviderError.notAuthenticated }
            return GoogleDriveGrant(account: account, pickedFileIDs: credential.pickedFileIDs)
        } onCancel: {
            Task { @MainActor in
                if self.attempt == id { self.cancel() }
            }
        }
        #else
        throw CloudProviderError.invalidConfiguration
        #endif
    }

    static func checkAccount(_ actual: String, expected: String?) throws {
        guard !actual.isEmpty, expected == nil || expected == actual else { throw CloudProviderError.permissionDenied }
    }

    @MainActor
    func accessToken(accountID: String) async throws -> String {
        guard isConfigured, let configuration else { throw CloudProviderError.invalidConfiguration }
        try Task.checkCancellation()
        let snapshot = credentials.snapshot(accountID)
        guard let data = snapshot.data else { throw CloudProviderError.notAuthenticated }
        let task: Task<String, Error>
        if let existing = refreshes[accountID], existing.generation == snapshot.generation, existing.lifetime == snapshot.lifetime {
            task = existing.task
        } else {
            let id = UUID()
            task = Task { @MainActor in
                defer {
                    if self.refreshes[accountID]?.id == id { self.refreshes[accountID] = nil }
                }
                do {
                    let refreshed = try await self.refresh(data, configuration)
                    guard self.credentials.save(refreshed.archive, accountID: accountID, generation: snapshot.generation, lifetime: snapshot.lifetime) else {
                        throw CloudProviderError.notAuthenticated
                    }
                    return refreshed.accessToken
                } catch {
                    if Self.isInvalidGrant(error) {
                        self.credentials.remove(accountID, ifGeneration: snapshot.generation)
                    }
                    throw Self.oauthError(error)
                }
            }
            refreshes[accountID] = (id, snapshot.generation, snapshot.lifetime, task)
        }
        // One cancelled waiter must not cancel the refresh shared by other requests.
        let token = try await task.value
        if let tokenDeliveryBarrier { await tokenDeliveryBarrier() }
        try Task.checkCancellation()
        let current = credentials.snapshot(accountID)
        guard current.data != nil, current.lifetime == snapshot.lifetime else { throw CloudProviderError.notAuthenticated }
        return token
    }

    @MainActor
    static func refreshCredential(_ archive: Data, configuration: GoogleDriveConfiguration) async throws -> GoogleDriveRefreshedCredential {
        #if canImport(AppAuthCore)
        guard let authState = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive),
              authState.lastAuthorizationResponse.request.clientID == configuration.clientID,
              authState.lastAuthorizationResponse.request.redirectURL == configuration.redirectURL else {
            throw CloudProviderError.notAuthenticated
        }
        let token = try await freshToken(authState)
        let data = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
        return GoogleDriveRefreshedCredential(accessToken: token, archive: data)
        #else
        throw CloudProviderError.invalidConfiguration
        #endif
    }

    private func account(accessToken: String) async throws -> CloudAccount {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(permissionId,displayName)") else { throw CloudProviderError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        try GoogleDriveResponse.check(data, response)
        struct About: Decodable {
            struct User: Decodable { let permissionId: String; let displayName: String? }
            let user: User
        }
        let user = try JSONDecoder().decode(About.self, from: data).user
        guard !user.permissionId.isEmpty else { throw CloudProviderError.notAuthenticated }
        return CloudAccount(id: user.permissionId, displayName: user.displayName ?? user.permissionId, provider: "googledrive")
    }

    #if canImport(AppAuthCore)
    static func authorizationRequest(configuration: GoogleDriveConfiguration, purpose: GoogleDriveAuthorizationPurpose = .fileSelection) throws -> OIDAuthorizationRequest {
        guard let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { throw CloudProviderError.invalidConfiguration }
        var parameters = ["prompt": "consent", "access_type": "offline"]
        if purpose == .fileSelection { parameters["trigger_onepick"] = "true" }
        return OIDAuthorizationRequest(
            configuration: OIDServiceConfiguration(authorizationEndpoint: authorizationURL, tokenEndpoint: tokenURL),
            clientId: configuration.clientID,
            scopes: [GoogleDriveCallback.scope],
            redirectURL: configuration.redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: parameters
        )
    }

    @MainActor private static func freshToken(_ state: OIDAuthState) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            state.performAction { token, _, error in
                if let token, !token.isEmpty { continuation.resume(returning: token) }
                else { continuation.resume(throwing: error ?? CloudProviderError.serviceUnavailable) }
            }
        }
    }

    @MainActor
    private func interactiveCredential(from anchor: ASPresentationAnchor, configuration: GoogleDriveConfiguration, attemptID: UUID, purpose: GoogleDriveAuthorizationPurpose) async throws -> GoogleDriveInteractiveCredential {
        let request = try Self.authorizationRequest(configuration: configuration, purpose: purpose)
        guard let state = request.state, !state.isEmpty else { throw CloudProviderError.invalidConfiguration }
        let browser = GoogleDriveBrowser(anchor: anchor, redirectURL: configuration.redirectURL, state: state, purpose: purpose)
        let authState: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
            pendingSession = OIDAuthState.authState(byPresenting: request, externalUserAgent: browser) { authState, error in
                MainActor.assumeIsolated {
                    guard self.attempt == attemptID else {
                        continuation.resume(throwing: CloudProviderError.authenticationCancelled)
                        return
                    }
                    self.pendingSession = nil
                    if let authState { continuation.resume(returning: authState) }
                    else { continuation.resume(throwing: Self.oauthError(error)) }
                }
            }
        }
        guard attempt == attemptID else { throw CloudProviderError.authenticationCancelled }
        let token: String
        do { token = try await Self.freshToken(authState) }
        catch { throw Self.oauthError(error) }
        return GoogleDriveInteractiveCredential(accessToken: token, archive: try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true), pickedFileIDs: browser.pickedFileIDs)
    }

    #endif
    static func isInvalidGrant(_ error: Error) -> Bool {
        #if canImport(AppAuthCore)
        return errorChain(error).contains { $0.domain == OIDOAuthTokenErrorDomain && $0.code == OIDErrorCodeOAuthToken.invalidGrant.rawValue }
        #else
        return false
        #endif
    }

    private static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, chain.count < 12 {
            chain.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    static func oauthError(_ error: Error?) -> Error {
        guard let error else { return CloudProviderError.serviceUnavailable }
        if error is CancellationError { return CancellationError() }
        if let error = error as? CloudProviderError { return error }
        let chain = errorChain(error)
        if isInvalidGrant(error) { return CloudProviderError.notAuthenticated }
        for current in chain {
            if CloudProviderError.isLikelyOffline(current) { return CloudProviderError.networkUnavailable }
            if current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled { return CancellationError() }
            if current.domain == ASWebAuthenticationSessionError.errorDomain && current.code == ASWebAuthenticationSessionError.canceledLogin.rawValue { return CloudProviderError.authenticationCancelled }
            #if canImport(AppAuthCore)
            if current.domain == OIDGeneralErrorDomain && [OIDErrorCode.userCanceledAuthorizationFlow.rawValue, OIDErrorCode.programCanceledAuthorizationFlow.rawValue].contains(current.code) { return CloudProviderError.authenticationCancelled }
            if current.domain == OIDHTTPErrorDomain {
                if current.code == 429 { return CloudProviderError.rateLimited }
                if current.code == 401 { return CloudProviderError.notAuthenticated }
                if current.code == 403 { return CloudProviderError.permissionDenied }
                if current.code >= 500 { return CloudProviderError.serviceUnavailable }
            }
            if current.domain == OIDOAuthTokenErrorDomain { return CloudProviderError.invalidConfiguration }
            #endif
        }
        #if canImport(AppAuthCore)
        if chain.count == 1, chain.first?.domain == OIDGeneralErrorDomain,
           chain.first?.code == OIDErrorCode.tokenRefreshError.rawValue { return CloudProviderError.notAuthenticated }
        #endif
        return CloudProviderError.serviceUnavailable
    }

}

#if canImport(AppAuthCore)
@MainActor
private final class GoogleDriveBrowser: NSObject, @preconcurrency OIDExternalUserAgent, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private let redirectURL: URL
    private let state: String
    private let purpose: GoogleDriveAuthorizationPurpose
    private var callbackConsumed = false
    private var browser: ASWebAuthenticationSession?
    private(set) var pickedFileIDs: [String] = []

    init(anchor: ASPresentationAnchor, redirectURL: URL, state: String, purpose: GoogleDriveAuthorizationPurpose) {
        self.anchor = anchor; self.redirectURL = redirectURL; self.state = state; self.purpose = purpose
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        guard browser == nil else { return false }
        let browser = ASWebAuthenticationSession(url: request.externalUserAgentRequestURL(), callbackURLScheme: redirectURL.scheme) { [weak self] url, error in
            Task { @MainActor in
                guard let self, self.browser != nil, !self.callbackConsumed else { return }
                self.callbackConsumed = true
                guard let url else {
                    session.failExternalUserAgentFlowWithError((error ?? CloudProviderError.authenticationCancelled) as NSError)
                    return
                }
                do {
                    self.pickedFileIDs = try GoogleDriveCallback.validate(url: url, redirectURL: self.redirectURL, state: self.state, purpose: self.purpose)
                    _ = try session.resumeExternalUserAgentFlow(url)
                } catch {
                    session.failExternalUserAgentFlowWithError(error as NSError)
                }
            }
        }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = true
        self.browser = browser
        let started = browser.start()
        if !started { self.browser = nil }
        return started
    }

    func dismiss(animated: Bool, completion: @escaping @Sendable () -> Void) {
        browser?.cancel()
        browser = nil
        completion()
    }
}
#endif
