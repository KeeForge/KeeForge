@preconcurrency import SwiftyDropbox
import XCTest
@testable import KeeForge

final class DropboxCloudProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    func testAuthenticateRequestsWriteScope() {
        let scopeRequest = DropboxCloudProvider.makeScopeRequest()

        XCTAssertEqual(scopeRequest.scopes, DropboxCloudProvider.requestedScopes)
        XCTAssertTrue(scopeRequest.scopes.contains("files.content.write"))
        XCTAssertEqual(scopeRequest.includeGrantedScopes, false)
    }

    // MARK: - Sign-out

    /// Disconnecting from Settings can be the first Dropbox call of the session,
    /// so sign-out must clear the refresh token whether or not the SDK ever got
    /// configured.
    func testSignOutRemovesStoredRefreshToken() throws {
        let providerID = CloudProviderKind.dropbox.rawValue
        let accountID = "unit-dropbox-signout"

        guard CloudTokenStore.setTokenData(Data("refresh-token".utf8), provider: providerID, accountId: accountID) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        defer { _ = CloudTokenStore.deleteToken(provider: providerID, accountId: accountID) }

        DropboxCloudProvider.shared.signOut(accountId: accountID)

        XCTAssertNil(CloudTokenStore.tokenData(provider: providerID, accountId: accountID))
        XCTAssertFalse(DropboxCloudProvider.shared.isAuthenticated(accountId: accountID))
    }

    // MARK: - Offline and auth classification

    /// Airplane-mode shape: only the refresh token is persisted, so the call
    /// fails while refreshing, and SwiftyDropbox has already flattened the
    /// transport cause into `OAuth2Error.unknown` by the time we see it.
    func testOAuthRefreshTransportFailureMapsToNetworkUnavailable() {
        let error = CallError<Files.DownloadError>.clientError(.oauthError(OAuth2Error.unknown))

        XCTAssertEqual(mapped(error), .networkUnavailable)
    }

    func testOAuthRefreshInvalidGrantMapsToNotAuthenticated() {
        let error = CallError<Files.DownloadError>.clientError(.oauthError(OAuth2Error.invalidGrant))

        XCTAssertEqual(mapped(error), .notAuthenticated)
    }

    func testOAuthRefreshServerErrorMapsToServiceUnavailable() {
        let error = CallError<Files.DownloadError>.clientError(.oauthError(OAuth2Error.temporarilyUnavailable))

        XCTAssertEqual(mapped(error), .serviceUnavailable)
    }

    func testURLSessionOfflineErrorMapsToNetworkUnavailable() {
        let error = CallError<Files.DownloadError>.clientError(.urlSessionError(URLError(.notConnectedToInternet)))

        XCTAssertEqual(mapped(error), .networkUnavailable)
    }

    /// A TLS failure is a real error, not "you are offline": it must not send
    /// the caller down the cached-copy path.
    func testTLSFailureDoesNotMapToOffline() {
        let error = CallError<Files.DownloadError>.clientError(.urlSessionError(URLError(.secureConnectionFailed)))

        XCTAssertNotEqual(mapped(error), .networkUnavailable)
    }

    func testInternalServerErrorIsTransientAndMapsToServiceUnavailable() {
        let error = CallError<Files.UploadError>.internalServerError(503, nil, nil)

        let failure = DropboxCloudProvider.mapGenericDropboxError(error) as? DropboxCloudProvider.TransientFailure
        XCTAssertEqual(failure?.kind, .serverError)
        XCTAssertEqual(failure?.mapped, .serviceUnavailable)
    }

    func testServerErrorRetryDelayBacksOffAndExhausts() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .serverError, attempt: 1), 1)
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .serverError, attempt: 2), 2)
        XCTAssertNil(DropboxCloudProvider.retryDelay(for: .serverError, attempt: DropboxCloudProvider.maxAttempts))
    }

    func testExpiredAccessTokenStillMapsToNotAuthenticated() {
        let error = CallError<Files.UploadError>.authError(.expiredAccessToken, nil, nil, nil)

        XCTAssertEqual(mapped(error), .notAuthenticated)
    }

    func testMissingScopeStillMapsToWriteScopeRequired() {
        let error = CallError<Files.UploadError>.authError(
            .missingScope(Auth.TokenScopeError(requiredScope: "files.content.write")),
            nil,
            nil,
            nil
        )

        XCTAssertEqual(mapped(error), .writeScopeRequired)
    }

    // MARK: - Rate limiting

    func testRateLimitErrorIsRetryableAndReportsRateLimited() {
        let error = CallError<Files.UploadError>.rateLimitError(
            Auth.RateLimitError(reason: .tooManyRequests, retryAfter: 4),
            nil,
            nil,
            nil
        )

        let failure = DropboxCloudProvider.mapGenericDropboxError(error) as? DropboxCloudProvider.TransientFailure
        XCTAssertEqual(failure?.kind, .rateLimited(retryAfter: 4))
        XCTAssertEqual(failure?.mapped, .rateLimited)
    }

    func testTooManyWriteOperationsIsRetryable() {
        let failure = DropboxCloudProvider.mapWriteError(.tooManyWriteOperations) as? DropboxCloudProvider.TransientFailure

        XCTAssertEqual(failure?.kind, .tooManyWriteOperations)
        XCTAssertEqual(failure?.mapped, .rateLimited)
    }

    /// The transient wrapper is unwrapped by the retry loop, but if one ever
    /// escaped it must still read as the localized rate-limit message.
    func testTransientFailureCarriesLocalizedDescription() {
        let failure = DropboxCloudProvider.TransientFailure(kind: .tooManyWriteOperations, mapped: .rateLimited)

        XCTAssertEqual(failure.errorDescription, CloudProviderError.rateLimited.errorDescription)
    }

    // MARK: - Retry delays

    func testRateLimitDelayHonoursRetryAfter() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 3), attempt: 1), 3)
    }

    func testRateLimitDelayIsClampedToTheCeiling() {
        XCTAssertEqual(
            DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 600), attempt: 1),
            DropboxCloudProvider.maxRetryDelay
        )
    }

    func testRateLimitDelayHasAFloorOfOneSecond() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 0), attempt: 1), 1)
    }

    func testWriteBackoffGrowsBetweenAttempts() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .tooManyWriteOperations, attempt: 1), 1)
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .tooManyWriteOperations, attempt: 2), 2)
    }

    func testRetryStopsOnceTheAttemptBudgetIsSpent() {
        let lastAttempt = DropboxCloudProvider.maxAttempts

        XCTAssertNil(DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 1), attempt: lastAttempt))
        XCTAssertNil(DropboxCloudProvider.retryDelay(for: .tooManyWriteOperations, attempt: lastAttempt))
    }

    // MARK: - Typed write errors

    func testWriteErrorsMapToActionableCases() {
        XCTAssertEqual(writeError(.insufficientSpace), .insufficientSpace)
        XCTAssertEqual(writeError(.noWritePermission), .permissionDenied)
        XCTAssertEqual(writeError(.teamFolder), .permissionDenied)
        XCTAssertEqual(writeError(.disallowedName), .invalidName)
        XCTAssertEqual(writeError(.malformedPath(nil)), .invalidName)
        XCTAssertEqual(writeError(.conflict(.file)), .conflict(remoteRev: nil))
    }

    func testUnspecifiedWriteErrorFallsBackToTheGenericMapping() {
        XCTAssertNil(DropboxCloudProvider.mapWriteError(.other))
    }

    func testUploadRouteErrorUnwrapsTheWriteFailure() {
        let uploadError = Files.UploadError.path(
            Files.UploadWriteFailed(reason: .insufficientSpace, uploadSessionId: "unit-session")
        )

        XCTAssertEqual(DropboxCloudProvider.mapUploadRouteError(uploadError) as? CloudProviderError, .insufficientSpace)
    }

    func testUploadRouteErrorWithoutAPathFailureIsNotMapped() {
        XCTAssertNil(DropboxCloudProvider.mapUploadRouteError(.payloadTooLarge))
    }

    // MARK: - Helpers

    private func mapped<E>(_ error: CallError<E>) -> CloudProviderError? {
        DropboxCloudProvider.mapGenericDropboxError(error) as? CloudProviderError
    }

    private func writeError(_ error: Files.WriteError) -> CloudProviderError? {
        DropboxCloudProvider.mapWriteError(error) as? CloudProviderError
    }
}
