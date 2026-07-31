import XCTest
@testable import KeeForge

/// Pure-seam coverage for the OneDrive provider: Graph URL construction, the
/// small-file upload split, the retry/backoff policy, upload-session
/// resumption, and error mapping. No network, no MSAL — every assertion
/// targets a `static` helper.
final class OneDriveCloudProviderTests: XCTestCase {
    private let graphBase = "https://graph.microsoft.com/v1.0"

    // MARK: - Graph URL construction

    // Regression: the path arrives already percent-encoded, and
    // `appendingPathComponent` used to encode it a second time
    // (`My%20Vault.kdbx` -> `My%2520Vault.kdbx`), so a database in a folder with
    // a space could neither be opened nor saved.

    func testContentURLKeepsSingleEncodingForSpace() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.contentPath(for: "/Apps/My Vault.kdbx")
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/Apps/My%20Vault.kdbx:/content"
        )
        XCTAssertFalse(url.absoluteString.contains("%25"))
    }

    func testUploadSessionURLKeepsSingleEncodingForHashAndAmpersand() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.uploadSessionPath(for: "/My files/pass#1&2.kdbx")
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/My%20files/pass%231%262.kdbx:/createUploadSession"
        )
        XCTAssertFalse(url.absoluteString.contains("%25"))
    }

    func testItemURLKeepsSingleEncodingForNonASCII() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.itemPath(for: "/Ünïcode/Käse.kdbx"),
            queryItems: [URLQueryItem(name: "$select", value: "id,name,size,eTag,cTag")]
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/%C3%9Cn%C3%AFcode/K%C3%A4se.kdbx:?$select=id,name,size,eTag,cTag"
        )
        XCTAssertFalse(url.absoluteString.contains("%25"))
    }

    func testPlainASCIIPathIsUnchanged() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.contentPath(for: "/Vaults/personal.kdbx")
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/Vaults/personal.kdbx:/content"
        )
    }

    func testListChildrenURLPreservesSelectQueryItems() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.listChildrenPath(for: "/My files"),
            queryItems: [
                URLQueryItem(name: "$top", value: "200"),
                URLQueryItem(name: "$select", value: "id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"),
            ]
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/My%20files:/children"
                + "?$top=200"
                + "&$select=id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "$top" })?.value, "200")
    }

    func testDriveRootListingHasNoPathSegment() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.listChildrenPath(for: nil)
        )

        XCTAssertEqual(url.absoluteString, "\(graphBase)/me/drive/root/children")
    }

    // MARK: - Post-upload metadata re-read

    // Upload responses come in a different shape than the `$select`ed metadata
    // GET and can omit cTag/eTag/hashes, so `upload`/`createFile` re-read the
    // committed item and only fall back to the upload response when the
    // re-read fails (the upload has already committed by then).

    func testItemIdURLCarriesTheSharedMetadataSelectList() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.itemIdPath(for: "01BYE5RZ6QN3ZWBTUFOFD3GSPGOHDJD36K"),
            queryItems: [URLQueryItem(name: "$select", value: OneDriveCloudProvider.metadataSelectList)]
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/items/01BYE5RZ6QN3ZWBTUFOFD3GSPGOHDJD36K"
                + "?$select=id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"
        )
    }

    func testItemIdURLAcceptsPersonalDriveIdsContainingBang() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.itemIdPath(for: "F5E2A6C4D1B3!114")
        )

        XCTAssertEqual(url.absoluteString, "\(graphBase)/me/drive/items/F5E2A6C4D1B3!114")
    }

    func testResolveUploadMetadataReturnsTheAuthoritativeReRead() async {
        let fallback = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 100),
            contentHash: nil,
            size: 64,
            rev: nil
        )
        let authoritative = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 200),
            contentHash: "quickXor:full-hash",
            size: 64,
            rev: "cTag-full"
        )

        let resolved = await OneDriveCloudProvider.resolveUploadMetadata(fallback: fallback) {
            authoritative
        }

        XCTAssertEqual(resolved, authoritative)
    }

    func testResolveUploadMetadataFallsBackWhenTheReReadFails() async {
        // The upload already committed, so a failed re-read must not fail the
        // save; the upload response's metadata is returned instead.
        let fallback = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 100),
            contentHash: nil,
            size: 64,
            rev: "cTag-upload"
        )

        let resolved = await OneDriveCloudProvider.resolveUploadMetadata(fallback: fallback) {
            throw CloudProviderError.serviceUnavailable
        }

        XCTAssertEqual(resolved, fallback)
    }

    // MARK: - Content-hash tagging

    func testTaggedContentHashPrefersQuickXorAndTagsTheAlgorithm() {
        // quickXorHash is the only hash Graph guarantees on both Personal and
        // Business drives; the tag keeps two algorithms from comparing equal.
        XCTAssertEqual(
            OneDriveCloudProvider.taggedContentHash(quickXorHash: "QX==", sha1Hash: "SHA1HEX"),
            "quickXor:QX=="
        )
        XCTAssertEqual(
            OneDriveCloudProvider.taggedContentHash(quickXorHash: nil, sha1Hash: "SHA1HEX"),
            "sha1:SHA1HEX"
        )
        XCTAssertNil(OneDriveCloudProvider.taggedContentHash(quickXorHash: nil, sha1Hash: nil))
    }

    // MARK: - Simple-upload threshold

    func testSimpleUploadUsedJustBelowLimit() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldUseSimpleUpload(
                byteCount: OneDriveCloudProvider.simpleUploadByteLimit - 1
            )
        )
    }

    func testSimpleUploadUsedExactlyAtLimit() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldUseSimpleUpload(
                byteCount: OneDriveCloudProvider.simpleUploadByteLimit
            )
        )
    }

    func testSimpleUploadNotUsedJustAboveLimit() {
        XCTAssertFalse(
            OneDriveCloudProvider.shouldUseSimpleUpload(
                byteCount: OneDriveCloudProvider.simpleUploadByteLimit + 1
            )
        )
    }

    func testSimpleUploadLimitIsFourMebibytes() {
        XCTAssertEqual(OneDriveCloudProvider.simpleUploadByteLimit, 4 * 1_024 * 1_024)
    }

    // MARK: - Upload-session retry policy

    func testRetriesSpuriousInvalidRequest() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: 1
            )
        )
        // Graph is inconsistent about casing on this code.
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidrequest",
                attempt: 1
            )
        )
    }

    func testDoesNotRetryOtherBadRequests() {
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "quotaLimitReached",
                attempt: 1
            )
        )
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: nil,
                attempt: 1
            )
        )
    }

    func testRetriesThrottlingAndServerErrors() {
        for statusCode in [429, 500, 502, 503, 504, 599] {
            XCTAssertTrue(
                OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                    statusCode: statusCode,
                    errorCode: nil,
                    attempt: 1
                ),
                "HTTP \(statusCode) should be retried"
            )
        }
    }

    func testNeverRetriesDeterministicFailures() {
        for statusCode in [401, 403, 404, 409, 412] {
            XCTAssertFalse(
                OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                    statusCode: statusCode,
                    errorCode: "invalidRequest",
                    attempt: 1
                ),
                "HTTP \(statusCode) must surface immediately"
            )
        }
    }

    func testAttemptCapStopsAtThreeTotalAttempts() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: 1
            )
        )
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: 2
            )
        )
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: OneDriveCloudProvider.uploadSessionCreationMaxAttempts
            )
        )
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 503,
                errorCode: nil,
                attempt: OneDriveCloudProvider.uploadSessionCreationMaxAttempts + 1
            )
        )
    }

    // MARK: - General request retry policy

    // Every operation, not just `createUploadSession`, now retries the
    // transient set. A single 503 used to fail a whole save.

    func testGeneralRequestsRetryThrottlingAndServerErrors() {
        for statusCode in [429, 500, 502, 503, 504] {
            XCTAssertTrue(
                OneDriveCloudProvider.shouldRetryRequest(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) should be retried"
            )
        }
    }

    func testGeneralRequestsNeverRetryDeterministicFailures() {
        // Includes 412: retrying a precondition failure would paper over a
        // genuine remote change instead of surfacing the conflict.
        for statusCode in [400, 401, 403, 404, 409, 412, 416] {
            XCTAssertFalse(
                OneDriveCloudProvider.shouldRetryRequest(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) must surface immediately"
            )
        }
    }

    func testGeneralRequestsStopAtThreeTotalAttempts() {
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryRequest(statusCode: 503, attempt: 1))
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryRequest(statusCode: 503, attempt: 2))
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryRequest(
                statusCode: 503,
                attempt: OneDriveCloudProvider.requestMaxAttempts
            )
        )
    }

    func testSessionCreationRetryReusesTheGeneralPolicyOutsideBadRequests() {
        // The spurious-400 rule is the only difference between the two.
        for statusCode in [401, 403, 404, 409, 412, 429, 500, 503] {
            XCTAssertEqual(
                OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                    statusCode: statusCode,
                    errorCode: "invalidRequest",
                    attempt: 1
                ),
                OneDriveCloudProvider.shouldRetryRequest(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) should follow the shared policy"
            )
        }
    }

    // MARK: - Chunk retry policy

    func testChunkRetriesRangeAlreadySatisfied() {
        // 416 means the service already holds those bytes: resync the offset,
        // do not fail the save.
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: 416, attempt: 1))
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: 416, attempt: 2))
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadChunk(
                statusCode: 416,
                attempt: OneDriveCloudProvider.requestMaxAttempts
            )
        )
    }

    func testChunkRetriesTransientAndNotDeterministicFailures() {
        for statusCode in [429, 500, 503, 504] {
            XCTAssertTrue(
                OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) should be retried"
            )
        }
        for statusCode in [401, 403, 404, 409, 412] {
            XCTAssertFalse(
                OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) must surface immediately"
            )
        }
    }

    // MARK: - Resume offset from nextExpectedRanges

    func testResumeOffsetReadsOpenEndedRange() {
        XCTAssertEqual(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["26-"],
                totalBytes: 128
            ),
            26
        )
    }

    func testResumeOffsetTakesLowestOfSeveralGaps() {
        // Graph does not promise to list every missing range, so the only safe
        // restart point is the lowest byte it admits to missing.
        XCTAssertEqual(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["77829-99375", "12345-55232"],
                totalBytes: 100_000
            ),
            12_345
        )
    }

    func testResumeOffsetIgnoresOutOfBoundsAndGarbageRanges() {
        XCTAssertNil(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["512-", "nonsense", "-"],
                totalBytes: 512
            )
        )
        XCTAssertEqual(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["nonsense", "300-511"],
                totalBytes: 512
            ),
            300
        )
    }

    func testResumeOffsetIsNilWhenNothingIsMissing() {
        // An empty list means the payload is fully received; the caller keeps
        // its own offset rather than rewinding to zero.
        XCTAssertNil(
            OneDriveCloudProvider.resumeOffset(fromNextExpectedRanges: [], totalBytes: 128)
        )
    }

    // MARK: - Backoff

    func testBackoffGrowsBetweenAttempts() {
        let first = OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: nil)
        let second = OneDriveCloudProvider.retryDelay(forAttempt: 2, retryAfter: nil)

        XCTAssertEqual(first, .milliseconds(500))
        XCTAssertEqual(second, .milliseconds(1_500))
        XCTAssertLessThan(first, second)
    }

    func testRetryAfterHeaderWinsAndIsClamped() {
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: "2"),
            .seconds(2)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: "3600"),
            .seconds(10)
        )
    }

    func testUnparsableRetryAfterFallsBackToBackoff() {
        // HTTP-date form and garbage both fall back to the computed backoff.
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(
                forAttempt: 2,
                retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"
            ),
            .milliseconds(1_500)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: "-5"),
            .milliseconds(500)
        )
    }

    // MARK: - Graph error mapping

    // Regression: 403 used to always mean "reconnect for write scope", which
    // sends the user through a sign-in that fixes nothing when the real cause
    // is a permission on the item.

    func testAccessDeniedIsAPermissionProblemNotAScopeProblem() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 403,
                errorCode: "accessDenied",
                message: "Access denied."
            ),
            .permissionDenied
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 403, errorCode: nil, message: nil),
            .permissionDenied
        )
    }

    func testScopeAndAuthFailuresKeepTheirRemedies() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 403,
                errorCode: "authorizationRequestDenied",
                message: "Insufficient privileges."
            ),
            .writeScopeRequired
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 401,
                errorCode: "InvalidAuthenticationToken",
                message: "Access token has expired."
            ),
            .notAuthenticated
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 401, errorCode: nil, message: nil),
            .notAuthenticated
        )
    }

    func testQuotaFailuresMapToInsufficientSpace() {
        // Docs use HTTP 507 and the `quotaLimitReached` code; the old check
        // looked for the English word "quota" inside a 400 message.
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 507, errorCode: nil, message: nil),
            .insufficientSpace
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 400,
                errorCode: "quotaLimitReached",
                message: "The user has reached their quota limit."
            ),
            .insufficientSpace
        )
    }

    func testThrottlingAndServerErrorsMapToTypedCases() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 429, errorCode: nil, message: nil),
            .rateLimited
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 429,
                errorCode: "activityLimitReached",
                message: "Throttled."
            ),
            .rateLimited
        )
        for statusCode in [500, 502, 503, 504] {
            XCTAssertEqual(
                OneDriveCloudProvider.mapGraphError(statusCode: statusCode, errorCode: nil, message: nil),
                .serviceUnavailable,
                "HTTP \(statusCode) should be a service outage"
            )
        }
    }

    func testNameConflictOnCreateStaysAConflict() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 409,
                errorCode: "nameAlreadyExists",
                message: "Another file exists with the same name."
            ),
            .conflict(remoteRev: nil)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 412, errorCode: nil, message: nil),
            .conflict(remoteRev: nil)
        )
    }

    func testNameShapedBadRequestMapsToInvalidName() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 400,
                errorCode: "invalidRequest",
                message: "The file name contains invalid characters."
            ),
            .invalidName
        )
    }

    func testUnclassifiedBadRequestKeepsTheServerMessage() {
        // The spurious `invalidRequest` has nothing to do with the name, so it
        // must not be relabeled once retries are exhausted.
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 400,
                errorCode: "invalidRequest",
                message: "The request is malformed or incorrect."
            ),
            .unknown("The request is malformed or incorrect.")
        )
        XCTAssertFalse(OneDriveCloudProvider.isNameShapedFailure(message: nil))
        XCTAssertFalse(
            OneDriveCloudProvider.isNameShapedFailure(message: "The request is malformed or incorrect.")
        )
    }

    func testItemNotFoundMapsToFileNotFound() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 404,
                errorCode: "itemNotFound",
                message: "Item does not exist."
            ),
            .fileNotFound
        )
    }

    // MARK: - Transport error mapping

    // Regression: the whole of NSURLErrorDomain used to collapse to "offline",
    // so a TLS failure told the user they had no network and quietly fell back
    // to the cached copy.

    func testConnectivityErrorsAreOffline() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost] {
            let mapped = OneDriveCloudProvider.mapGenericError(
                NSError(domain: NSURLErrorDomain, code: code)
            )
            XCTAssertEqual(mapped as? CloudProviderError, .networkUnavailable, "code \(code)")
        }
    }

    func testTLSAndCancellationErrorsSurfaceAsThemselves() {
        for code in [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorCancelled] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            let mapped = OneDriveCloudProvider.mapGenericError(error)
            XCTAssertNotEqual(mapped as? CloudProviderError, .networkUnavailable, "code \(code)")
            XCTAssertEqual(
                mapped as? CloudProviderError,
                .unknown(error.localizedDescription),
                "code \(code)"
            )
        }
    }

    func testNonURLErrorsKeepTheirDescription() {
        let error = NSError(
            domain: "com.example.Test",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Disk is on fire."]
        )

        XCTAssertEqual(
            OneDriveCloudProvider.mapGenericError(error) as? CloudProviderError,
            .unknown("Disk is on fire.")
        )
    }
}
