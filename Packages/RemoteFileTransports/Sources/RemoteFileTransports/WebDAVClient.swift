import Foundation

/// Thin, `Sendable` WebDAV transport. All HTTP work funnels through an
/// injectable transport closure so tests can stub responses without a live
/// network. The live transport uses an ephemeral `URLSession` with no cache,
/// no cookies, and no credential storage; the `Authorization` header is built
/// preemptively (Basic) and never re-sent across a cross-host redirect.
///
/// Operations return any HTTP status as a `Response`; map it with
/// `WebDAVError(statusCode:isPropfind:)`. A transport failure throws
/// `WebDAVError` for a `URLError` and rethrows anything else unchanged.
public struct WebDAVClient: Sendable {
    /// Given a request, return the body and HTTP response, or throw. A
    /// `URLError` is classified into `WebDAVError`; other errors pass through.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// HTTP Basic credentials, sent preemptively on every request.
    public struct Credential: Hashable, Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    private let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    /// A response captured from a WebDAV request, exposing the headers callers
    /// need without leaking `URLResponse` details.
    public struct Response: Sendable {
        public let statusCode: Int
        public let data: Data
        public let eTag: String?
        public let ocETag: String?
        public let lastModified: String?
        public let contentLength: Int64?

        public init(
            statusCode: Int,
            data: Data,
            eTag: String?,
            ocETag: String?,
            lastModified: String?,
            contentLength: Int64?
        ) {
            self.statusCode = statusCode
            self.data = data
            self.eTag = eTag
            self.ocETag = ocETag
            self.lastModified = lastModified
            self.contentLength = contentLength
        }
    }

    // MARK: - Operations

    /// PROPFIND with `Depth: 1` — lists the immediate children of a collection.
    public func propfindList(url: URL, credential: Credential) async throws -> Response {
        try await send(
            method: "PROPFIND",
            url: url,
            credential: credential,
            headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )
    }

    /// PROPFIND with `Depth: 0` — used to probe a single resource / server root.
    public func probe(url: URL, credential: Credential) async throws -> Response {
        try await send(
            method: "PROPFIND",
            url: url,
            credential: credential,
            headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )
    }

    public func head(url: URL, credential: Credential) async throws -> Response {
        try await send(method: "HEAD", url: url, credential: credential)
    }

    public func get(url: URL, credential: Credential) async throws -> Response {
        try await send(method: "GET", url: url, credential: credential)
    }

    /// PUT a body, optionally conditioned on `If-Match` (strong ETag) or
    /// `If-None-Match` (`*` for create-only semantics).
    public func put(
        url: URL,
        credential: Credential,
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
        credential: Credential,
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
        } catch let urlError as URLError {
            throw WebDAVError(urlError)
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
    public static let maxPropfindResponseBytes: Int64 = 64 * 1024 * 1024   // 64 MiB

    /// Hard ceiling for any other response body (notably a GET of the database).
    /// A KDBX file is typically well under this; the cap only exists to bound the
    /// amount an untrusted server can make us buffer.
    public static let maxBodyResponseBytes: Int64 = 512 * 1024 * 1024       // 512 MiB

    /// The byte ceiling to enforce for a given request. Without a ceiling,
    /// `URLSession` buffers the entire response in memory (bounded only by the
    /// 300s resource timeout), so a malicious or misconfigured server could
    /// stream an unbounded body and trigger a jetsam memory kill.
    static func responseByteLimit(
        for request: URLRequest,
        propfind: Int64 = maxPropfindResponseBytes,
        body: Int64 = maxBodyResponseBytes
    ) -> Int64 {
        request.httpMethod == "PROPFIND" ? propfind : body
    }

    // MARK: - Live transport

    /// Builds the production transport backed by an ephemeral `URLSession` that
    /// stores nothing and follows same-origin redirects only.
    public static func liveTransport() -> Transport {
        liveTransport(
            maxPropfindResponseBytes: maxPropfindResponseBytes,
            maxBodyResponseBytes: maxBodyResponseBytes
        )
    }

    /// Tests lower the caps to exercise them without huge bodies.
    static func liveTransport(maxPropfindResponseBytes: Int64, maxBodyResponseBytes: Int64) -> Transport {
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
            let byteLimit = responseByteLimit(
                for: request,
                propfind: maxPropfindResponseBytes,
                body: maxBodyResponseBytes
            )
            // Stream the response so the accumulated bytes can be capped; the
            // session delegate (same-origin redirect + Authorization stripping)
            // still applies because `bytes(for:)` uses the session's delegate.
            let (byteStream, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebDAVError.invalidResponse
            }
            // Reject an honestly-advertised over-limit body before downloading it.
            if httpResponse.expectedContentLength > byteLimit {
                throw WebDAVError.responseTooLarge
            }
            var data = Data()
            if httpResponse.expectedContentLength > 0 {
                data.reserveCapacity(Int(min(httpResponse.expectedContentLength, byteLimit)))
            }
            // Also cap the accumulated bytes: a server may omit or understate
            // Content-Length while streaming an unbounded body.
            for try await byte in byteStream {
                if Int64(data.count) >= byteLimit {
                    throw WebDAVError.responseTooLarge
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
final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
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
            Self.sameOrigin(originalURL, newURL)
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

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}
