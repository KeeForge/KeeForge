import AuthenticationServices
import XCTest
#if canImport(AppAuthCore)
@preconcurrency import AppAuthCore
#endif
@testable import KeeForge

final class GoogleDriveAuthorizationTests: XCTestCase {
    private let clientID = "123-test.apps.googleusercontent.com"
    private let callback = "com.googleusercontent.apps.123-test:/oauthredirect"

    func testMissingOrPlaceholderOrMismatchedPlatformConfigurationFailsClosed() {
        XCTAssertNil(GoogleDriveConfiguration(clientID: nil, redirectURI: callback))
        XCTAssertNil(GoogleDriveConfiguration(clientID: clientID, redirectURI: nil))
        XCTAssertNil(GoogleDriveConfiguration(clientID: "$(GOOGLE_CLIENT_ID)", redirectURI: callback))
        XCTAssertNil(GoogleDriveConfiguration(clientID: clientID, redirectURI: "com.googleusercontent.apps.other:/oauthredirect"))
        XCTAssertNil(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback + "?unexpected=true"))
        XCTAssertNil(GoogleDriveConfiguration(clientID: clientID, redirectURI: "https://example.com/callback"))
        XCTAssertNotNil(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback))
    }

    @MainActor
    func testMissingConfigurationNeverActivatesAuthentication() async throws {
        let auth = GoogleDriveAuthorization(configuration: nil)
        XCTAssertFalse(auth.isConfigured)
        do {
            _ = try await auth.accessToken(accountID: "not-a-real-account")
            XCTFail("Missing configuration cannot activate OAuth")
        } catch { XCTAssertEqual(error as? CloudProviderError, .invalidConfiguration) }
        auth.cancel()
    }

    func testPickerCallbackRequiresExactCallbackStateCodeAndExplicitFileGrant() throws {
        let redirect = try XCTUnwrap(URL(string: callback))
        let url = try XCTUnwrap(URL(string: callback + "?state=secure-state&code=authorization-code&picked_file_ids=file_A,file_B"))
        XCTAssertEqual(try GoogleDriveCallback.pickedIDs(url: url, redirectURL: redirect, state: "secure-state"), ["file_A", "file_B"])
        for invalid in [
            callback + "?state=other&code=code&picked_file_ids=file_A",
            callback + "?state=secure-state&state=secure-state&code=code&picked_file_ids=file_A",
            callback + "?state=secure-state&code=code",
            callback + "?state=secure-state&picked_file_ids=file_A",
            callback + "?state=secure-state&code=code&picked_file_ids=file_A,",
            callback + "?state=secure-state&code=code&picked_file_ids=../bad",
            callback + "?state=secure-state&code=code&picked_file_ids=file_A#fragment",
            callback.replacingOccurrences(of: "/oauthredirect", with: "/oauthredirect/other") + "?state=secure-state&code=code&picked_file_ids=file_A",
            callback + "?state=secure-state&code=code&picked_file_ids=file_A&scope=https://www.googleapis.com/auth/drive"
        ] {
            XCTAssertThrowsError(try GoogleDriveCallback.pickedIDs(url: XCTUnwrap(URL(string: invalid)), redirectURL: redirect, state: "secure-state"), invalid)
        }
    }

    func testAccountCallbackDoesNotRequirePickerIDsButKeepsExactStateAndDuplicateChecks() throws {
        let redirect = try XCTUnwrap(URL(string: callback))
        let accountURL = try XCTUnwrap(URL(string: callback + "?state=account-state&code=code"))
        XCTAssertEqual(try GoogleDriveCallback.validate(url: accountURL, redirectURL: redirect, state: "account-state", purpose: .account), [])
        XCTAssertThrowsError(try GoogleDriveCallback.pickedIDs(url: accountURL, redirectURL: redirect, state: "account-state"))
        for invalid in [
            callback + "?state=other&code=code",
            callback + "?state=account-state&code=code&code=replayed",
            callback + "?state=account-state&code=code#fragment",
            callback + "?state=account-state&code=code&scope=https://www.googleapis.com/auth/drive",
            callback + "?state=account-state"
        ] {
            XCTAssertThrowsError(try GoogleDriveCallback.validate(url: XCTUnwrap(URL(string: invalid)), redirectURL: redirect, state: "account-state", purpose: .account))
        }
    }

    func testPickerCancellationAndAccountMismatchAreActionableAndNeverRebind() throws {
        let redirect = try XCTUnwrap(URL(string: callback))
        XCTAssertThrowsError(try GoogleDriveCallback.pickedIDs(url: XCTUnwrap(URL(string: callback + "?state=s&error=access_denied")), redirectURL: redirect, state: "s")) {
            XCTAssertEqual($0 as? CloudProviderError, .authenticationCancelled)
        }
        XCTAssertNoThrow(try GoogleDriveAuthorization.checkAccount("permission-123", expected: "permission-123"))
        XCTAssertThrowsError(try GoogleDriveAuthorization.checkAccount("permission-other", expected: "permission-123")) {
            XCTAssertEqual($0 as? CloudProviderError, .permissionDenied)
        }
        XCTAssertThrowsError(try GoogleDriveAuthorization.checkAccount("", expected: nil))
    }

    func testSignOutFencesRefreshSerializationWithoutTouchingRealKeychain() throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "account-A", generation: 0))
        XCTAssertTrue(credentials.save(Data("other".utf8), accountID: "account-B", generation: 0))
        let inFlight = credentials.snapshot("account-A")
        credentials.remove("account-A")
        XCTAssertFalse(credentials.save(Data("refreshed".utf8), accountID: "account-A", generation: inFlight.generation))
        XCTAssertNil(credentials.snapshot("account-A").data)
        XCTAssertEqual(credentials.snapshot("account-B").data, Data("other".utf8))
    }

    func testCredentialSaveAdvancesGenerationAndRejectsStaleRefreshArchive() {
        let storage = GoogleDriveTestCredentialStorage()
        let store = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(store.save(Data("old".utf8), accountID: "A", generation: 0))
        let snapshot = store.snapshot("A")
        XCTAssertTrue(store.save(Data("new".utf8), accountID: "A", generation: snapshot.generation))
        XCTAssertFalse(store.save(Data("stale".utf8), accountID: "A", generation: snapshot.generation))
        XCTAssertEqual(store.snapshot("A").data, Data("new".utf8))
    }

    func testFailedKeychainDeletionWritesPersistentTombstone() {
        let storage = GoogleDriveTestCredentialStorage()
        let makeStore = { GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { _ in false }) }
        let store = makeStore()
        XCTAssertTrue(store.save(Data("old".utf8), accountID: "A", generation: 0))
        XCTAssertTrue(store.remove("A"))
        XCTAssertNil(store.snapshot("A").data)
        XCTAssertNil(makeStore().snapshot("A").data)
    }

    func testBothKeychainFailuresRemainFencedInProcessAndReportFailure() {
        let old = Data("retained-archive".utf8)
        let store = GoogleDriveCredentialStore(read: { _ in old }, write: { _, _ in false }, delete: { _ in false })
        XCTAssertNotNil(store.snapshot("A").data)
        XCTAssertFalse(store.remove("A"))
        XCTAssertNil(store.snapshot("A").data)
    }

    #if canImport(AppAuthCore)
    @MainActor
    func testConcurrentRefreshWaitersShareOneArchiveAndCancellationDoesNotPoisonOthers() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "A", generation: 0))
        let gate = GoogleDriveTestRefreshGate()
        let auth = GoogleDriveAuthorization(configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials, refresh: { data, _ in try await gate.run(data) })
        let firstStarted = GoogleDriveTestSignal()
        let secondStarted = GoogleDriveTestSignal()
        let first = Task { @MainActor in firstStarted.signal(); return try await auth.accessToken(accountID: "A") }
        let second = Task { @MainActor in secondStarted.signal(); return try await auth.accessToken(accountID: "A") }
        await firstStarted.wait()
        await secondStarted.wait()
        await gate.entered.wait()
        first.cancel()
        gate.finish()
        do { _ = try await first.value; XCTFail("Cancelled waiter must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        let token = try await second.value
        XCTAssertEqual(token, "fresh-token")
        XCTAssertEqual(gate.calls, 1)
        XCTAssertEqual(gate.inputs, [Data("old".utf8)])
        XCTAssertEqual(credentials.snapshot("A").data, Data("fresh-archive".utf8))
    }

    @MainActor
    func testSignOutWhileRefreshIsInFlightCannotRestoreCredential() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "A", generation: 0))
        let gate = GoogleDriveTestRefreshGate()
        let auth = GoogleDriveAuthorization(configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials, refresh: { data, _ in try await gate.run(data) })
        let task = Task { @MainActor in try await auth.accessToken(accountID: "A") }
        await gate.entered.wait()
        auth.remove(accountID: "A")
        gate.finish()
        do { _ = try await task.value; XCTFail("Signout must fence refresh") }
        catch { XCTAssertEqual(error as? CloudProviderError, .notAuthenticated) }
        XCTAssertNil(credentials.snapshot("A").data)
        XCTAssertFalse(auth.contains(accountID: "A"))
    }

    @MainActor
    func testRefreshCannotOverwriteCredentialReplacedByReconnect() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "A", generation: 0))
        let gate = GoogleDriveTestRefreshGate()
        let auth = GoogleDriveAuthorization(configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials, refresh: { data, _ in try await gate.run(data) })
        let task = Task { @MainActor in try await auth.accessToken(accountID: "A") }
        await gate.entered.wait()
        let snapshot = credentials.snapshot("A")
        XCTAssertTrue(credentials.saveAuthorization(Data("reconnected".utf8), accountID: "A", expectedLifetime: snapshot.lifetime, authorizationGeneration: credentials.authorizationGeneration))
        gate.finish()
        do { _ = try await task.value; XCTFail("Older refresh must lose to reconnect") }
        catch { XCTAssertEqual(error as? CloudProviderError, .notAuthenticated) }
        XCTAssertEqual(credentials.snapshot("A").data, Data("reconnected".utf8))
    }

    @MainActor
    func testReconnectPausedAtAboutSurvivesOrdinaryBackgroundRefresh() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "permission-A", generation: 0))
        let initial = credentials.snapshot("permission-A")
        let transport = GoogleDriveTestAboutGate()
        let auth = GoogleDriveAuthorization(
            configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials,
            transport: transport,
            refresh: { _, _ in GoogleDriveRefreshedCredential(accessToken: "background-token", archive: Data("background-archive".utf8)) },
            interactiveAuthorization: { _, _ in GoogleDriveInteractiveCredential(accessToken: "interactive-token", archive: Data("interactive-archive".utf8), pickedFileIDs: ["file_A"]) }
        )
        let reconnect = Task { @MainActor in try await auth.authorize(from: ASPresentationAnchor(), expectedAccountID: "permission-A") }
        await transport.waitUntilRequested()
        let token = try await auth.accessToken(accountID: "permission-A")
        XCTAssertEqual(token, "background-token")
        XCTAssertEqual(credentials.snapshot("permission-A").lifetime, initial.lifetime)
        XCTAssertGreaterThan(credentials.snapshot("permission-A").generation, initial.generation)
        await transport.finish()
        let grant = try await reconnect.value
        XCTAssertEqual(grant.account.id, "permission-A")
        XCTAssertEqual(credentials.snapshot("permission-A").data, Data("interactive-archive".utf8))
        XCTAssertNotEqual(credentials.snapshot("permission-A").lifetime, initial.lifetime)
    }

    @MainActor
    func testNewerReconnectFencesOlderPausedReconnect() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "permission-A", generation: 0))
        let configuration = try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback))
        let earlierTransport = GoogleDriveTestAboutGate()
        let laterTransport = GoogleDriveTestAboutGate()
        let earlierAuth = GoogleDriveAuthorization(
            configuration: configuration, credentials: credentials, transport: earlierTransport,
            interactiveAuthorization: { _, _ in GoogleDriveInteractiveCredential(accessToken: "earlier", archive: Data("earlier".utf8), pickedFileIDs: ["file_A"]) }
        )
        let laterAuth = GoogleDriveAuthorization(
            configuration: configuration, credentials: credentials, transport: laterTransport,
            interactiveAuthorization: { _, _ in GoogleDriveInteractiveCredential(accessToken: "later", archive: Data("later".utf8), pickedFileIDs: ["file_A"]) }
        )
        let earlier = Task { @MainActor in try await earlierAuth.authorize(from: ASPresentationAnchor(), expectedAccountID: "permission-A") }
        await earlierTransport.waitUntilRequested()
        let later = Task { @MainActor in try await laterAuth.authorize(from: ASPresentationAnchor(), expectedAccountID: "permission-A") }
        await laterTransport.waitUntilRequested()
        await laterTransport.finish()
        _ = try await later.value
        await earlierTransport.finish()
        do { _ = try await earlier.value; XCTFail("Earlier reconnect must not overwrite later authorization") }
        catch { XCTAssertEqual(error as? CloudProviderError, .notAuthenticated) }
        XCTAssertEqual(credentials.snapshot("permission-A").data, Data("later".utf8))
    }

    @MainActor
    func testLateTokenWaiterSurvivesNextSuccessfulRefreshOfSameAuthorization() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "A", generation: 0))
        let delivery = GoogleDriveTestDeliveryGate()
        let auth = GoogleDriveAuthorization(
            configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials,
            refresh: { data, _ in GoogleDriveRefreshedCredential(accessToken: String(decoding: data, as: UTF8.self) + "-token", archive: data + Data("-refreshed".utf8)) },
            tokenDeliveryBarrier: { await delivery.pauseFirst() }
        )
        let late = Task { @MainActor in try await auth.accessToken(accountID: "A") }
        await delivery.entered.wait()
        let firstRevision = credentials.snapshot("A").generation
        let next = try await auth.accessToken(accountID: "A")
        XCTAssertEqual(next, "old-refreshed-token")
        XCTAssertGreaterThan(credentials.snapshot("A").generation, firstRevision)
        delivery.release.signal()
        let earlier = try await late.value
        XCTAssertEqual(earlier, "old-token")
        XCTAssertEqual(credentials.snapshot("A").data, Data("old-refreshed-refreshed".utf8))
    }

    @MainActor
    func testLateTokenDeliveryIsFencedBySignOutOrAnotherReconnect() async throws {
        for reconnect in [false, true] {
            let storage = GoogleDriveTestCredentialStorage()
            let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
            XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "A", generation: 0))
            let delivery = GoogleDriveTestDeliveryGate()
            let auth = GoogleDriveAuthorization(
                configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials,
                refresh: { _, _ in GoogleDriveRefreshedCredential(accessToken: "old-token", archive: Data("refreshed".utf8)) },
                tokenDeliveryBarrier: { await delivery.pauseFirst() }
            )
            let late = Task { @MainActor in try await auth.accessToken(accountID: "A") }
            await delivery.entered.wait()
            if reconnect {
                let current = credentials.snapshot("A")
                XCTAssertTrue(credentials.saveAuthorization(Data("reconnected".utf8), accountID: "A", expectedLifetime: current.lifetime, authorizationGeneration: credentials.authorizationGeneration))
            } else { auth.remove(accountID: "A") }
            delivery.release.signal()
            do { _ = try await late.value; XCTFail("Old authorization lifetime must not deliver") }
            catch { XCTAssertEqual(error as? CloudProviderError, .notAuthenticated) }
            XCTAssertEqual(credentials.snapshot("A").data, reconnect ? Data("reconnected".utf8) : nil)
        }
    }

    @MainActor
    func testWrappedOfflineAnd503RetainRefreshArchiveButProvenInvalidGrantDeletesIt() async throws {
        let offline = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.networkError.rawValue, userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        let unavailable = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.serverError.rawValue, userInfo: [NSUnderlyingErrorKey: NSError(domain: OIDHTTPErrorDomain, code: 503)])
        let invalidGrant = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.tokenRefreshError.rawValue, userInfo: [NSUnderlyingErrorKey: NSError(domain: OIDOAuthTokenErrorDomain, code: OIDErrorCodeOAuthToken.invalidGrant.rawValue)])
        for (failure, expected, retained) in [(offline, CloudProviderError.networkUnavailable, true), (unavailable, .serviceUnavailable, true), (invalidGrant, .notAuthenticated, false)] {
            let storage = GoogleDriveTestCredentialStorage()
            let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
            XCTAssertTrue(credentials.save(Data("old".utf8), accountID: "A", generation: 0))
            let auth = GoogleDriveAuthorization(configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials, refresh: { _, _ in throw failure })
            do { _ = try await auth.accessToken(accountID: "A"); XCTFail("Injected refresh must fail") }
            catch { XCTAssertEqual(error as? CloudProviderError, expected) }
            XCTAssertEqual(credentials.snapshot("A").data, retained ? Data("old".utf8) : nil)
        }
    }

    @MainActor
    func testUnknownAccountAuthorizationCannotUndoSignOutDuringAboutRequestOrCancellation() async throws {
        for cancel in [false, true] {
            let storage = GoogleDriveTestCredentialStorage()
            let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
            let transport = GoogleDriveTestAboutGate()
            let auth = GoogleDriveAuthorization(
                configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials,
                transport: transport, interactiveAuthorization: { _, _ in GoogleDriveInteractiveCredential(accessToken: "test", archive: Data("new".utf8), pickedFileIDs: ["file_A"]) }
            )
            let task = Task { @MainActor in try await auth.authorize(from: ASPresentationAnchor(), expectedAccountID: nil) }
            await transport.waitUntilRequested()
            if cancel { auth.cancel() } else { auth.remove(accountID: "permission-A") }
            await transport.finish()
            do { _ = try await task.value; XCTFail("Late about response must not reconnect") }
            catch { XCTAssertEqual(error as? CloudProviderError, cancel ? .authenticationCancelled : .notAuthenticated) }
            XCTAssertNil(credentials.snapshot("permission-A").data)
        }
    }

    @MainActor
    func testAccountOnlyAuthorizationConnectsEmptyDriveWithoutSelectingFiles() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        let transport = GoogleDriveTestAboutGate()
        let auth = GoogleDriveAuthorization(
            configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)),
            credentials: credentials, transport: transport,
            interactiveAuthorization: { _, _ in throw CloudProviderError.permissionDenied },
            accountAuthorization: { _, _ in GoogleDriveInteractiveCredential(accessToken: "account-token", archive: Data("account-archive".utf8), pickedFileIDs: []) }
        )
        let task = Task { try await auth.authorizeAccount(from: ASPresentationAnchor(), expectedAccountID: nil) }
        await transport.waitUntilRequested()
        await transport.finish()
        let account = try await task.value
        XCTAssertEqual(account.id, "permission-A")
        XCTAssertEqual(credentials.snapshot(account.id).data, Data("account-archive".utf8))
    }

    @MainActor
    func testAccountOnlyAuthorizationCannotRebindOrRestoreAfterCancelAndSignout() async throws {
        for action in ["mismatch", "cancel", "signout"] {
            let storage = GoogleDriveTestCredentialStorage()
            let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
            let transport = GoogleDriveTestAboutGate()
            let auth = GoogleDriveAuthorization(
                configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)),
                credentials: credentials, transport: transport,
                accountAuthorization: { _, _ in GoogleDriveInteractiveCredential(accessToken: "account-token", archive: Data("archive".utf8), pickedFileIDs: []) }
            )
            let task = Task { try await auth.authorizeAccount(from: ASPresentationAnchor(), expectedAccountID: action == "mismatch" ? "other-account" : "permission-A") }
            await transport.waitUntilRequested()
            if action == "cancel" { auth.cancel() }
            if action == "signout" { auth.remove(accountID: "permission-A") }
            await transport.finish()
            do { _ = try await task.value; XCTFail("Stale or mismatched account flow must fail") }
            catch { XCTAssertEqual(error as? CloudProviderError, action == "cancel" ? .authenticationCancelled : action == "signout" ? .notAuthenticated : .permissionDenied) }
            XCTAssertNil(credentials.snapshot("permission-A").data)
        }
    }

    @MainActor
    func testPickerAuthorizationStillRejectsEmptyExplicitGrantBeforeCredentialPersistence() async throws {
        let storage = GoogleDriveTestCredentialStorage()
        let credentials = GoogleDriveCredentialStore(read: { storage.read($0) }, write: { storage.write($0, account: $1) }, delete: { storage.delete($0) })
        let auth = GoogleDriveAuthorization(
            configuration: try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback)), credentials: credentials,
            interactiveAuthorization: { _, _ in GoogleDriveInteractiveCredential(accessToken: "test", archive: Data("archive".utf8), pickedFileIDs: []) }
        )
        do { _ = try await auth.authorize(from: ASPresentationAnchor(), expectedAccountID: nil); XCTFail("Picker requires IDs") }
        catch { XCTAssertEqual(error as? CloudProviderError, .permissionDenied) }
        XCTAssertNil(credentials.snapshot("permission-A").data)
    }

    func testAccountRequestUsesSameSDKPKCEWithoutTriggeringPicker() throws {
        let configuration = try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback))
        let request = try GoogleDriveAuthorization.authorizationRequest(configuration: configuration, purpose: .account)
        XCTAssertNil(request.additionalParameters?["trigger_onepick"])
        XCTAssertEqual(request.scope, GoogleDriveCallback.scope)
        XCTAssertEqual(request.codeChallengeMethod, "S256")
        XCTAssertNotNil(request.codeVerifier)
        XCTAssertGreaterThan(request.state?.count ?? 0, 20)
        XCTAssertNil(request.clientSecret)
    }

    func testAppAuthRequestUsesSDKGeneratedS256StateAndNativePickerParameters() throws {
        let configuration = try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback))
        let first = try GoogleDriveAuthorization.authorizationRequest(configuration: configuration)
        let second = try GoogleDriveAuthorization.authorizationRequest(configuration: configuration)
        XCTAssertEqual(first.codeChallengeMethod, "S256")
        XCTAssertNotNil(first.codeVerifier)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
        XCTAssertGreaterThan(first.state?.count ?? 0, 20)
        XCTAssertNil(first.clientSecret)
        XCTAssertEqual(first.scope, GoogleDriveCallback.scope)
        XCTAssertEqual(first.responseType, "code")
        XCTAssertEqual(first.redirectURL, configuration.redirectURL)
        XCTAssertEqual(first.additionalParameters?["trigger_onepick"], "true")
        XCTAssertEqual(first.additionalParameters?["prompt"], "consent")
        XCTAssertEqual(first.additionalParameters?["access_type"], "offline")
    }

    func testAppAuthSecureArchivePreservesRefreshStateAndPickerResponse() throws {
        let configuration = try XCTUnwrap(GoogleDriveConfiguration(clientID: clientID, redirectURI: callback))
        let request = try GoogleDriveAuthorization.authorizationRequest(configuration: configuration)
        let response = OIDAuthorizationResponse(request: request, parameters: ["code": "test-code" as NSString, "state": request.state! as NSString, "picked_file_ids": "file_A" as NSString])
        let state = OIDAuthState(authorizationResponse: response)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive))
        XCTAssertEqual(restored.lastAuthorizationResponse.request.clientID, clientID)
        XCTAssertEqual(restored.lastAuthorizationResponse.request.codeVerifier, request.codeVerifier)
        XCTAssertEqual(restored.lastAuthorizationResponse.additionalParameters?["picked_file_ids"] as? String, "file_A")
    }
    #endif
}

private final class GoogleDriveTestCredentialStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func read(_ account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return data[account] }
    func write(_ value: Data, account: String) -> Bool { lock.lock(); defer { lock.unlock() }; data[account] = value; return true }
    func delete(_ account: String) -> Bool { lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: account); return true }
}

@MainActor
private final class GoogleDriveTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { signalled = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func wait() async { if signalled { return }; await withCheckedContinuation { waiters.append($0) } }
}

@MainActor
private final class GoogleDriveTestRefreshGate {
    let entered = GoogleDriveTestSignal()
    private(set) var calls = 0
    private(set) var inputs: [Data] = []
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func run(_ data: Data) async throws -> GoogleDriveRefreshedCredential {
        calls += 1
        inputs.append(data)
        entered.signal()
        if !completed { await withCheckedContinuation { waiters.append($0) } }
        return GoogleDriveRefreshedCredential(accessToken: "fresh-token", archive: Data("fresh-archive".utf8))
    }
    func finish() { completed = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor GoogleDriveTestAboutGate: GoogleDriveTransport {
    private var requested = false
    private var started: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Never>?
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { response?.resume(); response = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requested = true
        started?.resume()
        started = nil
        await withCheckedContinuation { response = $0 }
        return (Data(#"{"user":{"permissionId":"permission-A","displayName":"Test"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor
private final class GoogleDriveTestDeliveryGate {
    let entered = GoogleDriveTestSignal()
    let release = GoogleDriveTestSignal()
    private var arrivals = 0
    func pauseFirst() async {
        arrivals += 1
        if arrivals == 1 { entered.signal(); await release.wait() }
    }
}
