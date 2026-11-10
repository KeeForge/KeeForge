import XCTest
@testable import RemoteFileTransports

/// Tests for the thin WebDAV transport client, its PROPFIND multistatus parser,
/// request construction, response-header extraction, and error classification.
///
/// Every transport is a stub closure — these tests never touch the network.
final class WebDAVClientTests: XCTestCase {
    private let credential = WebDAVClient.Credential(username: "alice", password: "s3cr3t")

    // MARK: - PROPFIND parsing fixtures

    func testParseNextcloudSabreStyleIgnoresOCAndNCProps() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/alice/Vaults/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                <oc:fileid>12345</oc:fileid>
                <nc:has-preview>false</nc:has-preview>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/alice/Vaults/personal.kdbx</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <d:getcontentlength>2048</d:getcontentlength>
                <d:getetag>"abc123"</d:getetag>
                <d:getlastmodified>Tue, 01 Jul 2025 10:20:30 GMT</d:getlastmodified>
                <oc:size>2048</oc:size>
                <oc:permissions>RGDNVW</oc:permissions>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://cloud.example.com/remote.php/dav/files/alice/Vaults/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        // Self entry (Vaults/) is skipped; only the file remains.
        XCTAssertEqual(resources.count, 1)
        let file = try XCTUnwrap(resources.first)
        XCTAssertEqual(file.path, "/personal.kdbx")
        XCTAssertEqual(file.name, "personal.kdbx")
        XCTAssertFalse(file.isFolder)
        XCTAssertEqual(file.eTag, "\"abc123\"")
        XCTAssertEqual(file.contentLength, 2048)
        XCTAssertNotNil(file.lastModified)
    }

    func testParseApacheModDavUppercasePrefix() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/backup.kdbx</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>512</D:getcontentlength>
                <D:getetag>"apache-etag"</D:getetag>
                <D:getlastmodified>Wed, 02 Jul 2025 11:00:00 GMT</D:getlastmodified>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/subfolder/</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/dav/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        XCTAssertEqual(resources.count, 2)
        let file = try XCTUnwrap(resources.first(where: { !$0.isFolder }))
        XCTAssertEqual(file.name, "backup.kdbx")
        XCTAssertEqual(file.eTag, "\"apache-etag\"")
        XCTAssertEqual(file.contentLength, 512)
        let folder = try XCTUnwrap(resources.first(where: { $0.isFolder }))
        XCTAssertEqual(folder.name, "subfolder")
        XCTAssertTrue(folder.isFolder)
    }

    func testParsePropstat404BlockDoesNotLeakProps() throws {
        // Props live in a 404 propstat; the 200 propstat only carries resourcetype.
        // The failed-block props (etag/length/lastmod) must NOT appear on the resource.
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/secret.kdbx</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop>
                <d:getcontentlength>9999</d:getcontentlength>
                <d:getetag>"leaked-etag"</d:getetag>
                <d:getlastmodified>Thu, 03 Jul 2025 12:00:00 GMT</d:getlastmodified>
              </d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/dav/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        XCTAssertEqual(resources.count, 1)
        let file = try XCTUnwrap(resources.first)
        XCTAssertEqual(file.name, "secret.kdbx")
        XCTAssertFalse(file.isFolder)
        XCTAssertNil(file.eTag)
        XCTAssertNil(file.lastModified)
        XCTAssertNil(file.contentLength)
    }

    func testParseFolderVsFileDiscriminationViaResourceType() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/Documents/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/notes.txt</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/dav/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        XCTAssertEqual(resources.count, 2)
        let folder = try XCTUnwrap(resources.first(where: { $0.name == "Documents" }))
        XCTAssertTrue(folder.isFolder)
        let file = try XCTUnwrap(resources.first(where: { $0.name == "notes.txt" }))
        XCTAssertFalse(file.isFolder)
    }

    func testParsePercentEncodedHrefsWithSpacesAndUnicode() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/Vaults/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/Vaults/My%20Passw%C3%B6rter.kdbx</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <d:getcontentlength>100</d:getcontentlength>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/Vaults/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        XCTAssertEqual(resources.count, 1)
        let file = try XCTUnwrap(resources.first)
        XCTAssertEqual(file.path, "/My Passwörter.kdbx")
        XCTAssertEqual(file.name, "My Passwörter.kdbx")
    }

    func testParseLiteralPercentInBasePathDecodedExactlyOnce() throws {
        // A folder literally named "a%41b": on the wire each path segment is
        // percent-encoded once, so the "%" is sent as "%25" (i.e. "a%2541b").
        // Both the request URL path and the hrefs therefore decode EXACTLY ONCE
        // to "/a%41b/...". A second (buggy) decode would turn "%41" into "A",
        // breaking self-entry skipping and base-prefix stripping.
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/a%2541b/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/a%2541b/vault.kdbx</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <d:getcontentlength>10</d:getcontentlength>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/a%2541b/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        // The folder's own entry (decodes to "/a%41b/") is recognized as self and
        // skipped; only the file remains, with its base prefix correctly stripped.
        XCTAssertEqual(resources.count, 1)
        let file = try XCTUnwrap(resources.first)
        XCTAssertEqual(file.path, "/vault.kdbx")
        XCTAssertEqual(file.name, "vault.kdbx")
        XCTAssertFalse(file.isFolder)
    }

    func testParseAbsoluteURLHrefs() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>https://host.example.com/dav/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>https://host.example.com/dav/vault.kdbx</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <d:getetag>"abs-etag"</d:getetag>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/dav/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        XCTAssertEqual(resources.count, 1)
        let file = try XCTUnwrap(resources.first)
        XCTAssertEqual(file.path, "/vault.kdbx")
        XCTAssertEqual(file.name, "vault.kdbx")
        XCTAssertEqual(file.eTag, "\"abs-etag\"")
    }

    func testParseSelfEntrySkippedForDepth1() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/folder/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/dav/folder/"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL)

        // includeSelf defaults false, so the folder's own entry is dropped.
        XCTAssertTrue(resources.isEmpty)
    }

    func testParseIncludeSelfReturnsSingleFileFromDepth0Probe() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/vault.kdbx</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <d:getcontentlength>4096</d:getcontentlength>
                <d:getetag>"probe-etag"</d:getetag>
                <d:getlastmodified>Fri, 04 Jul 2025 09:00:00 GMT</d:getlastmodified>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let requestURL = try XCTUnwrap(URL(string: "https://host.example.com/dav/vault.kdbx"))
        let resources = try WebDAVPropfindParser.parse(data: Data(xml.utf8), requestURL: requestURL, includeSelf: true)

        XCTAssertEqual(resources.count, 1)
        let file = try XCTUnwrap(resources.first)
        XCTAssertEqual(file.path, "/")
        XCTAssertEqual(file.name, "vault.kdbx")
        XCTAssertFalse(file.isFolder)
        XCTAssertEqual(file.eTag, "\"probe-etag\"")
        XCTAssertEqual(file.contentLength, 4096)
        XCTAssertNotNil(file.lastModified)
    }

    // MARK: - Request construction

    func testBasicAuthorizationHeaderValue() {
        let header = WebDAVClient.basicAuthorizationHeader(username: "alice", password: "s3cr3t")
        // base64("alice:s3cr3t")
        let expected = Data("alice:s3cr3t".utf8).base64EncodedString()
        XCTAssertEqual(header, "Basic \(expected)")
    }

    func testPropfindListSendsDepth1AndAuthorizationAndValidBody() async throws {
        let recorder = RequestRecorder()
        let client = WebDAVClient(transport: recorder.transport(status: 207))
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/"))

        _ = try await client.propfindList(url: url, credential: credential)

        let captured = await recorder.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "PROPFIND")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("Basic "))

        let body = try XCTUnwrap(request.httpBody)
        let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(bodyString.contains("propfind"))
        XCTAssertTrue(bodyString.contains("resourcetype"))
        XCTAssertTrue(bodyString.contains("getcontentlength"))
        XCTAssertTrue(bodyString.contains("getlastmodified"))
        XCTAssertTrue(bodyString.contains("getetag"))

        // Body is well-formed XML.
        let parser = XMLParser(data: body)
        XCTAssertTrue(parser.parse())
    }

    func testProbeSendsDepth0() async throws {
        let recorder = RequestRecorder()
        let client = WebDAVClient(transport: recorder.transport(status: 207))
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/vault.kdbx"))

        _ = try await client.probe(url: url, credential: credential)

        let captured = await recorder.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "PROPFIND")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
    }

    func testPutAttachesBodyAndOmitsConditionalHeadersWhenNotPassed() async throws {
        let recorder = RequestRecorder()
        let client = WebDAVClient(transport: recorder.transport(status: 201))
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/vault.kdbx"))
        let payload = Data("kdbx-bytes".utf8)

        _ = try await client.put(url: url, credential: credential, data: payload)

        let captured = await recorder.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.httpBody, payload)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testPutSendsIfMatchWhenPassed() async throws {
        let recorder = RequestRecorder()
        let client = WebDAVClient(transport: recorder.transport(status: 204))
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/vault.kdbx"))

        _ = try await client.put(url: url, credential: credential, data: Data(), ifMatch: "\"strong-etag\"")

        let captured = await recorder.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"strong-etag\"")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testPutSendsIfNoneMatchWhenPassed() async throws {
        let recorder = RequestRecorder()
        let client = WebDAVClient(transport: recorder.transport(status: 201))
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/new.kdbx"))

        _ = try await client.put(url: url, credential: credential, data: Data(), ifNoneMatch: "*")

        let captured = await recorder.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
    }

    func testHeadSendsHeadMethod() async throws {
        let recorder = RequestRecorder()
        let client = WebDAVClient(transport: recorder.transport(status: 200))
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/vault.kdbx"))

        _ = try await client.head(url: url, credential: credential)

        let captured = await recorder.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "HEAD")
    }

    // MARK: - Response header extraction

    func testResponseExtractsHeadersCaseInsensitively() async throws {
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/vault.kdbx"))
        let transport: WebDAVClient.Transport = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "etag": "\"lower-etag\"",
                    "OC-ETag": "\"oc-value\"",
                    "last-modified": "Tue, 01 Jul 2025 10:20:30 GMT",
                    "Content-Length": "12345",
                ]
            )!
            return (Data(), response)
        }
        let client = WebDAVClient(transport: transport)

        let response = try await client.head(url: url, credential: credential)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.eTag, "\"lower-etag\"")
        XCTAssertEqual(response.ocETag, "\"oc-value\"")
        XCTAssertEqual(response.lastModified, "Tue, 01 Jul 2025 10:20:30 GMT")
        XCTAssertEqual(response.contentLength, 12345)
    }

    // MARK: - HTTP status classification

    func testStatusClassificationTable() {
        let cases: [(Int, Bool, WebDAVError?)] = [
            (200, false, nil),
            (204, false, nil),
            (207, true, nil),
            (299, false, nil),
            (401, false, .unauthorized),
            (403, false, .forbidden),
            (404, false, .notFound(statusCode: 404)),
            (410, false, .notFound(statusCode: 410)),
            (405, true, .notWebDAVServer(statusCode: 405)),
            (501, true, .notWebDAVServer(statusCode: 501)),
            (405, false, .methodRejected(statusCode: 405)),
            (501, false, .methodRejected(statusCode: 501)),
            (412, false, .preconditionFailed),
            (413, false, .payloadTooLarge),
            (423, false, .locked),
            (507, false, .insufficientStorage),
            (502, false, .serverUnavailable(statusCode: 502)),
            (503, true, .serverUnavailable(statusCode: 503)),
            (504, false, .serverUnavailable(statusCode: 504)),
            (500, false, .serverError(statusCode: 500)),
            (508, false, .serverError(statusCode: 508)),
            (599, false, .serverError(statusCode: 599)),
            (301, false, .unexpectedStatus(statusCode: 301)),
            (400, true, .unexpectedStatus(statusCode: 400)),
            (409, false, .unexpectedStatus(statusCode: 409)),
            (100, false, .unexpectedStatus(statusCode: 100)),
        ]
        for (status, isPropfind, expected) in cases {
            XCTAssertEqual(
                WebDAVError(statusCode: status, isPropfind: isPropfind),
                expected,
                "HTTP \(status), PROPFIND \(isPropfind)"
            )
        }
    }

    // MARK: - URLError classification

    func testURLErrorClassificationTable() {
        let cases: [(URLError.Code, WebDAVError)] = [
            (.notConnectedToInternet, .offline(.notConnectedToInternet)),
            (.networkConnectionLost, .offline(.networkConnectionLost)),
            (.timedOut, .offline(.timedOut)),
            (.cannotConnectToHost, .offline(.cannotConnectToHost)),
            (.cannotFindHost, .offline(.cannotFindHost)),
            (.dnsLookupFailed, .offline(.dnsLookupFailed)),
            (.internationalRoamingOff, .offline(.internationalRoamingOff)),
            (.dataNotAllowed, .offline(.dataNotAllowed)),
            (.secureConnectionFailed, .tlsHandshakeFailed(.secureConnectionFailed)),
            (.serverCertificateHasBadDate, .serverCertificateInvalid(.serverCertificateHasBadDate)),
            (.serverCertificateUntrusted, .serverCertificateInvalid(.serverCertificateUntrusted)),
            (.serverCertificateHasUnknownRoot, .serverCertificateInvalid(.serverCertificateHasUnknownRoot)),
            (.serverCertificateNotYetValid, .serverCertificateInvalid(.serverCertificateNotYetValid)),
            (.clientCertificateRejected, .clientCertificateRequired(.clientCertificateRejected)),
            (.clientCertificateRequired, .clientCertificateRequired(.clientCertificateRequired)),
            (
                .appTransportSecurityRequiresSecureConnection,
                .secureConnectionRequired(.appTransportSecurityRequiresSecureConnection)
            ),
            (.userCancelledAuthentication, .authenticationRejected(.userCancelledAuthentication)),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(WebDAVError(URLError(code)), expected, "\(code)")
        }
    }

    func testUnclassifiedURLErrorIsKeptWhole() {
        // CallIsActive counts as offline app-wide, but WebDAV never classified
        // it so; it keeps its own description.
        for code: URLError.Code in [.badURL, .cancelled, .callIsActive, .badServerResponse] {
            XCTAssertEqual(WebDAVError(URLError(code)), .transport(URLError(code)))
        }
    }

    func testSendClassifiesURLErrorAndPassesOtherErrorsThrough() async throws {
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/"))
        let offline = WebDAVClient { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await offline.get(url: url, credential: credential)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? WebDAVError, .offline(.notConnectedToInternet))
        }

        let refused = WebDAVClient { _ in throw WebDAVError.responseTooLarge }
        do {
            _ = try await refused.get(url: url, credential: credential)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? WebDAVError, .responseTooLarge)
        }

        let other = WebDAVClient { _ in throw CancellationError() }
        do {
            _ = try await other.get(url: url, credential: credential)
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNonSuccessStatusIsReturnedNotThrown() async throws {
        let client = WebDAVClient(transport: RequestRecorder().transport(status: 423))
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/vault.kdbx"))
        let response = try await client.put(url: url, credential: credential, data: Data([1]))
        XCTAssertEqual(response.statusCode, 423)
    }

    // MARK: - URL normalization

    func testNormalizedBaseURLEncodesSpacesAndNonASCIIInsteadOfFailing() throws {
        // A pasted address with a space and an umlaut must normalize (percent-
        // encoding the invalid characters) rather than throw .malformed.
        let url = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/Pässwörter/My Vaults")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "cloud.example.com")
        // ä→%C3%A4, ö→%C3%B6, space→%20, and exactly one trailing slash is added.
        XCTAssertEqual(
            url.absoluteString,
            "https://cloud.example.com/P%C3%A4ssw%C3%B6rter/My%20Vaults/"
        )
    }

    func testNormalizedBaseURLStillRejectsGarbageInput() {
        // Encoding invalid characters must not paper over genuinely unparseable
        // input; this still surfaces as .malformed.
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "not a url ::::")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .malformed)
        }
    }

    // MARK: - Response size limits

    func testResponseByteLimitDiffersForPropfindVersusDownload() throws {
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/vault.kdbx"))
        var propfind = URLRequest(url: url)
        propfind.httpMethod = "PROPFIND"
        var get = URLRequest(url: url)
        get.httpMethod = "GET"

        XCTAssertEqual(WebDAVClient.responseByteLimit(for: propfind), WebDAVClient.maxPropfindResponseBytes)
        XCTAssertEqual(WebDAVClient.responseByteLimit(for: get), WebDAVClient.maxBodyResponseBytes)
        XCTAssertLessThan(WebDAVClient.maxPropfindResponseBytes, WebDAVClient.maxBodyResponseBytes)
        XCTAssertGreaterThan(WebDAVClient.maxPropfindResponseBytes, 0)
    }
}

// MARK: - Test transport helper

/// Records the requests a stub transport receives so assertions can inspect
/// headers, method, and body after a client call.
private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func lastRequest() -> URLRequest? {
        requests.last
    }

    private func record(_ request: URLRequest) {
        requests.append(request)
    }

    /// Builds a transport that records the request and returns an empty body with
    /// the given status code.
    nonisolated func transport(status: Int, headers: [String: String] = [:]) -> WebDAVClient.Transport {
        return { [self] request in
            await self.record(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com/")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(), response)
        }
    }
}
