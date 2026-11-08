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

    #if canImport(AppAuthCore)
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
