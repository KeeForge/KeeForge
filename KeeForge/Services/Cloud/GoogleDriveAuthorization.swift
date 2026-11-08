import AuthenticationServices
import Foundation
#if canImport(AppAuthCore)
@preconcurrency import AppAuthCore
#endif

final class GoogleDriveCredentialStore: @unchecked Sendable {
    struct Snapshot { let data: Data?; let generation: UInt64 }
    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]
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
        return Snapshot(data: read(accountID), generation: generations[accountID, default: 0])
    }

    func save(_ data: Data, accountID: String, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generations[accountID, default: 0] == generation else { return false }
        return write(data, accountID)
    }

    func remove(_ accountID: String) {
        lock.lock()
        defer { lock.unlock() }
        generations[accountID, default: 0] &+= 1
        _ = delete(accountID)
    }
}

final class GoogleDriveAuthorization: GoogleDriveAuthorizing {
    private let configuration: GoogleDriveConfiguration?
    private let credentials: GoogleDriveCredentialStore
    private let transport: any GoogleDriveTransport
    @MainActor private var attempt: UUID?
    #if canImport(AppAuthCore)
    @MainActor private var pendingSession: (any OIDExternalUserAgentSession)?
    #endif

    init(configuration: GoogleDriveConfiguration? = .load(), credentials: GoogleDriveCredentialStore = GoogleDriveCredentialStore(), transport: any GoogleDriveTransport = GoogleDriveURLSessionTransport()) {
        self.configuration = configuration
        self.credentials = credentials
        self.transport = transport
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
    func authorize(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> GoogleDriveGrant {
        #if canImport(AppAuthCore)
        guard let configuration else { throw CloudProviderError.invalidConfiguration }
        guard attempt == nil else { throw CloudProviderError.authenticationCancelled }
        try Task.checkCancellation()
        let id = UUID()
        let expectedGeneration = expectedAccountID.map { credentials.snapshot($0).generation }
        attempt = id
        defer {
            if attempt == id { attempt = nil; pendingSession = nil }
        }
        return try await withTaskCancellationHandler {
            let request = try Self.authorizationRequest(configuration: configuration)
            guard let state = request.state, !state.isEmpty else { throw CloudProviderError.invalidConfiguration }
            let browser = GoogleDriveBrowser(anchor: anchor, redirectURL: configuration.redirectURL, state: state)
            let authState: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
                pendingSession = OIDAuthState.authState(byPresenting: request, externalUserAgent: browser) { authState, error in
                    MainActor.assumeIsolated {
                        guard self.attempt == id else {
                            continuation.resume(throwing: CloudProviderError.authenticationCancelled)
                            return
                        }
                        self.pendingSession = nil
                        if let authState { continuation.resume(returning: authState) }
                        else { continuation.resume(throwing: Self.oauthError(error)) }
                    }
                }
            }
            guard attempt == id else { throw CloudProviderError.authenticationCancelled }
            let token = try await Self.freshToken(authState)
            let account = try await account(accessToken: token)
            try Self.checkAccount(account.id, expected: expectedAccountID)
            try Task.checkCancellation()
            guard attempt == id else { throw CloudProviderError.authenticationCancelled }
            let generation = expectedGeneration ?? credentials.snapshot(account.id).generation
            let archived = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
            guard credentials.save(archived, accountID: account.id, generation: generation) else { throw CloudProviderError.notAuthenticated }
            return GoogleDriveGrant(account: account, pickedFileIDs: browser.pickedFileIDs)
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
        #if canImport(AppAuthCore)
        guard let configuration else { throw CloudProviderError.invalidConfiguration }
        let snapshot = credentials.snapshot(accountID)
        guard let data = snapshot.data,
              let authState = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data),
              authState.lastAuthorizationResponse.request.clientID == configuration.clientID,
              authState.lastAuthorizationResponse.request.redirectURL == configuration.redirectURL else {
            throw CloudProviderError.notAuthenticated
        }
        do {
            let token = try await Self.freshToken(authState)
            try Task.checkCancellation()
            let data = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
            guard credentials.save(data, accountID: accountID, generation: snapshot.generation) else { throw CloudProviderError.notAuthenticated }
            return token
        } catch {
            if (error as? CloudProviderError) == .notAuthenticated {
                // A refresh must never resurrect an account signed out during its network request.
                if credentials.snapshot(accountID).generation == snapshot.generation { credentials.remove(accountID) }
            }
            throw error
        }
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
    static func authorizationRequest(configuration: GoogleDriveConfiguration) throws -> OIDAuthorizationRequest {
        guard let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { throw CloudProviderError.invalidConfiguration }
        return OIDAuthorizationRequest(
            configuration: OIDServiceConfiguration(authorizationEndpoint: authorizationURL, tokenEndpoint: tokenURL),
            clientId: configuration.clientID,
            scopes: [GoogleDriveCallback.scope],
            redirectURL: configuration.redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: ["prompt": "consent", "trigger_onepick": "true", "access_type": "offline"]
        )
    }

    @MainActor private static func freshToken(_ state: OIDAuthState) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            state.performAction { token, _, error in
                if let token, !token.isEmpty { continuation.resume(returning: token) }
                else { continuation.resume(throwing: oauthError(error)) }
            }
        }
    }

    private static func oauthError(_ error: Error?) -> Error {
        if let error = error as? CloudProviderError { return error }
        if let error, CloudProviderError.isLikelyOffline(error) { return CloudProviderError.networkUnavailable }
        let nsError = error as NSError?
        if nsError?.domain == ASWebAuthenticationSessionError.errorDomain,
           nsError?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue { return CloudProviderError.authenticationCancelled }
        if nsError?.domain == OIDOAuthTokenErrorDomain { return CloudProviderError.notAuthenticated }
        if nsError?.domain == OIDGeneralErrorDomain,
           nsError?.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue { return CloudProviderError.authenticationCancelled }
        return CloudProviderError.notAuthenticated
    }
    #endif
}

#if canImport(AppAuthCore)
@MainActor
private final class GoogleDriveBrowser: NSObject, @preconcurrency OIDExternalUserAgent, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private let redirectURL: URL
    private let state: String
    private var browser: ASWebAuthenticationSession?
    private(set) var pickedFileIDs: [String] = []

    init(anchor: ASPresentationAnchor, redirectURL: URL, state: String) {
        self.anchor = anchor; self.redirectURL = redirectURL; self.state = state
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        guard browser == nil else { return false }
        let browser = ASWebAuthenticationSession(url: request.externalUserAgentRequestURL(), callbackURLScheme: redirectURL.scheme) { [weak self] url, error in
            Task { @MainActor in
                guard let self, self.browser != nil else { return }
                guard let url else {
                    session.failExternalUserAgentFlowWithError((error ?? CloudProviderError.authenticationCancelled) as NSError)
                    return
                }
                do {
                    self.pickedFileIDs = try GoogleDriveCallback.pickedIDs(url: url, redirectURL: self.redirectURL, state: self.state)
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
