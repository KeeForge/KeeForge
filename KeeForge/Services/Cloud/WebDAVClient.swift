import Foundation

/// Thin, `Sendable` WebDAV transport. All HTTP work funnels through an
/// injectable transport closure so tests can stub responses without a live
/// network. The live transport uses an ephemeral `URLSession` with no cache,
/// no cookies, and no credential storage; the `Authorization` header is built
/// preemptively (Basic) and never re-sent across a cross-host redirect.
struct WebDAVClient: Sendable {
    /// The transport contract: given a request, return body + HTTP response, or
    /// throw a `URLError` (or already-mapped `CloudProviderError`).
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    /// A response captured from a WebDAV request, exposing the headers callers
    /// need without leaking `URLResponse` details.
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
        let eTag: String?
        let ocETag: String?
        let lastModified: String?
        let contentLength: Int64?
    }

    // MARK: - Operations

    /// PROPFIND with `Depth: 1` — lists the immediate children of a collection.
    func propfindList(url: URL, credential: WebDAVCredential) async throws -> Response {
        try await send(
            method: "PROPFIND",
            url: url,
            credential: credential,
            headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )
    }

    /// PROPFIND with `Depth: 0` — used to probe a single resource / server root.
    func probe(url: URL, credential: WebDAVCredential) async throws -> Response {
        try await send(
            method: "PROPFIND",
            url: url,
            credential: credential,
            headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )
    }

    func head(url: URL, credential: WebDAVCredential) async throws -> Response {
        try await send(method: "HEAD", url: url, credential: credential)
    }

    func get(url: URL, credential: WebDAVCredential) async throws -> Response {
        try await send(method: "GET", url: url, credential: credential)
    }

    /// PUT a body, optionally conditioned on `If-Match` (strong ETag) or
    /// `If-None-Match` (`*` for create-only semantics).
    func put(
        url: URL,
        credential: WebDAVCredential,
        data: Data,
        ifMatch: String? = nil,
        ifNoneMatch: String? = nil
    ) async throws -> Response {
        var headers = ["Content-Type": "application/octet-stream"]
        if let ifMatch { headers["If-Match"] = ifMatch }
        if let ifNoneMatch { headers["If-None-Match"] = ifNoneMatch }
        return try await send(
            method: "PUT",
            url: url,
            credential: credential,
            headers: headers,
            body: data
        )
    }

    // MARK: - Core send

    private func send(
        method: String,
        url: URL,
        credential: WebDAVCredential,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let authorization = Self.basicAuthorizationHeader(
            username: credential.username,
            password: credential.password
        ) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, httpResponse) = try await transport(request)
            return Self.makeResponse(data: data, httpResponse: httpResponse)
        } catch let error as CloudProviderError {
            throw error
        } catch let urlError as URLError {
            throw Self.mapURLError(urlError)
        } catch {
            throw CloudProviderError.unknown(error.localizedDescription)
        }
    }

    private static func makeResponse(data: Data, httpResponse: HTTPURLResponse) -> Response {
        let headers = httpResponse.allHeaderFields
        let eTag = header(headers, "ETag")
        let ocETag = header(headers, "OC-ETag")
        let lastModified = header(headers, "Last-Modified")
        let contentLength = header(headers, "Content-Length").flatMap { Int64($0) }
        return Response(
            statusCode: httpResponse.statusCode,
            data: data,
            eTag: eTag,
            ocETag: ocETag,
            lastModified: lastModified,
            contentLength: contentLength
        )
    }

    private static func header(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        for (key, value) in headers {
            if let keyString = key as? String,
               keyString.caseInsensitiveCompare(name) == .orderedSame,
               let stringValue = value as? String {
                return stringValue
            }
        }
        return nil
    }

    // MARK: - Authorization

    /// Builds a preemptive HTTP Basic `Authorization` header value. Never logged.
    static func basicAuthorizationHeader(username: String, password: String) -> String? {
        let raw = "\(username):\(password)"
        guard let encoded = raw.data(using: .utf8)?.base64EncodedString() else {
            return nil
        }
        return "Basic \(encoded)"
    }

    // MARK: - Error mapping

    /// Maps an HTTP status to a `CloudProviderError`, or `nil` for 2xx success.
    ///
    /// - Parameter isPropfind: PROPFIND-specific handling for 405/501 (server is
    ///   not WebDAV-capable) vs. the generic method-not-allowed path.
    static func mapHTTPStatus(
        _ statusCode: Int,
        isPropfind: Bool = false,
        responseBody: Data? = nil
    ) -> CloudProviderError? {
        if (200..<300).contains(statusCode) { return nil }

        switch statusCode {
        case 401:
            return .notAuthenticated
        case 403:
            // Not .writeScopeRequired: its message ("Reconnect this cloud
            // account") is wrong advice for a WebDAV permission denial.
            return .unknown(String(localized: "The server denied access. Check that this account has permission for this file or folder."))
        case 404, 410:
            return .fileNotFound
        case 405, 501:
            if isPropfind {
                return .unknown(String(localized: "This server does not look like a WebDAV server (HTTP \(statusCode)). Check the server address."))
            }
            return .unknown(String(localized: "The server rejected this request (HTTP \(statusCode))."))
        case 412:
            return .conflict(remoteRev: nil)
        case 423:
            return .unknown(String(localized: "The remote database is locked by another client. Try again shortly."))
        case 413:
            return .unknown(String(localized: "The database is too large for this server (HTTP 413)."))
        case 507:
            return .unknown(String(localized: "The server is out of storage space (HTTP 507)."))
        case 502, 503, 504:
            // A gateway that cannot reach its backend, or a server in
            // maintenance: unreachable for our purposes, so an open falls
            // back to the cache the same way an offline device does.
            return .serviceUnavailable
        case 500...599:
            return .unknown(String(localized: "The server reported an error (HTTP \(statusCode)). Try again shortly."))
        default:
            return .unknown(String(localized: "The server returned an unexpected response (HTTP \(statusCode))."))
        }
    }

    /// Maps a `URLError` to a `CloudProviderError`. Offline-family errors map to
    /// `.networkUnavailable`; TLS/ATS failures map to explicit `.unknown`
    /// messages so they are never mislabeled as "offline".
    static func mapURLError(_ error: URLError) -> CloudProviderError {
        switch error.code.rawValue {
        // TLS / App Transport Security failures. These MUST NOT be treated as
        // "offline" — surface an explicit secure-connection message instead.

        // Handshake failure: the certificate may be perfectly valid here (a
        // server offering no cipher suites this device implements fails the
        // same way), so blame the server's TLS configuration, not the cert.
        case NSURLErrorSecureConnectionFailed:        // -1200
            return .unknown(String(localized: "Could not establish a secure connection. The server's TLS settings are likely outdated or incompatible with this device. Ask the server operator to enable TLS 1.3, or TLS 1.2 with modern (ECDHE + AES-GCM) cipher suites."))

        case NSURLErrorServerCertificateHasBadDate,   // -1201
             NSURLErrorServerCertificateUntrusted,    // -1202
             NSURLErrorServerCertificateHasUnknownRoot, // -1203
             NSURLErrorServerCertificateNotYetValid:  // -1204
            return .unknown(String(localized: "Could not establish a secure connection because the server's certificate is invalid, expired, or untrusted."))

        case NSURLErrorClientCertificateRejected,     // -1205
             NSURLErrorClientCertificateRequired:     // -1206
            return .unknown(String(localized: "Could not establish a secure connection. The server requires a client certificate, which KeeForge does not support."))

        case NSURLErrorAppTransportSecurityRequiresSecureConnection: // -1022
            return .unknown(String(localized: "Could not establish a secure connection. This device requires an https:// server address."))

        // Offline / reachability family.
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed:
            return .networkUnavailable

        case NSURLErrorUserCancelledAuthentication:
            return .notAuthenticated

        default:
            return .unknown(error.localizedDescription)
        }
    }

    // MARK: - Bodies

    private static let propfindBody: Data = {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength/>
            <D:getlastmodified/>
            <D:getetag/>
          </D:prop>
        </D:propfind>
        """
        return Data(xml.utf8)
    }()

    // MARK: - Response size limits

    /// Hard ceiling for PROPFIND multistatus XML. Directory listings are tiny in
    /// practice; anything approaching this is pathological.
    static let maxPropfindResponseBytes: Int64 = 64 * 1024 * 1024   // 64 MiB

    /// Hard ceiling for any other response body (notably a GET of the database).
    /// A KDBX file is typically well under this; the cap only exists to bound the
    /// amount an untrusted server can make us buffer.
    static let maxBodyResponseBytes: Int64 = 512 * 1024 * 1024       // 512 MiB

    /// The byte ceiling to enforce for a given request. Without a ceiling,
    /// `URLSession` buffers the entire response in memory (bounded only by the
    /// 300s resource timeout), so a malicious or misconfigured server could
    /// stream an unbounded body and trigger a jetsam memory kill.
    static func responseByteLimit(for request: URLRequest) -> Int64 {
        request.httpMethod == "PROPFIND" ? maxPropfindResponseBytes : maxBodyResponseBytes
    }

    static func responseTooLargeError() -> CloudProviderError {
        .unknown(String(localized: "The server returned an unexpectedly large response. The transfer was stopped to protect memory."))
    }

    // MARK: - Live transport

    /// Builds the production transport backed by an ephemeral `URLSession` that
    /// stores nothing and follows same-origin redirects only.
    static func liveTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300

        let delegate = WebDAVSessionDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        return { request in
            let byteLimit = Self.responseByteLimit(for: request)
            // Stream the response so the accumulated bytes can be capped; the
            // session delegate (same-origin redirect + Authorization stripping)
            // still applies because `bytes(for:)` uses the session's delegate.
            let (byteStream, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudProviderError.unknown(String(localized: "The server returned an unexpected response."))
            }
            // Reject an honestly-advertised over-limit body before downloading it.
            if httpResponse.expectedContentLength > byteLimit {
                throw Self.responseTooLargeError()
            }
            var data = Data()
            if httpResponse.expectedContentLength > 0 {
                data.reserveCapacity(Int(min(httpResponse.expectedContentLength, byteLimit)))
            }
            // Also cap the accumulated bytes: a server may omit or understate
            // Content-Length while streaming an unbounded body.
            for try await byte in byteStream {
                if Int64(data.count) >= byteLimit {
                    throw Self.responseTooLargeError()
                }
                data.append(byte)
            }
            return (data, httpResponse)
        }
    }
}

/// URLSession delegate that enforces a same-origin-only redirect policy and
/// strips the `Authorization` header from any cross-host redirect so credentials
/// are never leaked to an unexpected server.
private final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard
            let originalURL = task.originalRequest?.url,
            let newURL = request.url,
            sameOrigin(originalURL, newURL)
        else {
            // Refuse cross-host redirects entirely — never forward credentials.
            completionHandler(nil)
            return
        }

        // Same-origin: allow, but drop any Authorization the system may have
        // carried over (defense in depth; we re-set it per request anyway).
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            sanitized.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        completionHandler(sanitized)
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}
