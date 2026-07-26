import XCTest
@testable import KeeForge

/// Pure-seam coverage for the OneDrive provider: Graph URL construction, the
/// small-file upload split, and the `createUploadSession` retry policy. No
/// network, no MSAL — every assertion targets a `static` helper.
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

    // MARK: - Backoff

    func testBackoffGrowsBetweenAttempts() {
        let first = OneDriveCloudProvider.uploadSessionRetryDelay(forAttempt: 1, retryAfter: nil)
        let second = OneDriveCloudProvider.uploadSessionRetryDelay(forAttempt: 2, retryAfter: nil)

        XCTAssertEqual(first, .milliseconds(500))
        XCTAssertEqual(second, .milliseconds(1_500))
        XCTAssertLessThan(first, second)
    }

    func testRetryAfterHeaderWinsAndIsClamped() {
        XCTAssertEqual(
            OneDriveCloudProvider.uploadSessionRetryDelay(forAttempt: 1, retryAfter: "2"),
            .seconds(2)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.uploadSessionRetryDelay(forAttempt: 1, retryAfter: "3600"),
            .seconds(10)
        )
    }

    func testUnparsableRetryAfterFallsBackToBackoff() {
        // HTTP-date form and garbage both fall back to the computed backoff.
        XCTAssertEqual(
            OneDriveCloudProvider.uploadSessionRetryDelay(
                forAttempt: 2,
                retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"
            ),
            .milliseconds(1_500)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.uploadSessionRetryDelay(forAttempt: 1, retryAfter: "-5"),
            .milliseconds(500)
        )
    }
}
