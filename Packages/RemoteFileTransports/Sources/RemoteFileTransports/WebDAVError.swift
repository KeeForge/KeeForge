import Foundation

/// A WebDAV failure: a non-success HTTP status, a classified `URLError`, or a
/// response the live transport refused. Carries no text; callers word it.
public enum WebDAVError: Error, Equatable, Sendable {
    // MARK: HTTP status

    /// 401.
    case unauthorized
    /// 403.
    case forbidden
    /// 404 or 410.
    case notFound(statusCode: Int)
    /// 405 or 501 to a PROPFIND: the server does not speak WebDAV.
    case notWebDAVServer(statusCode: Int)
    /// 405 or 501 to any other method.
    case methodRejected(statusCode: Int)
    /// 412: an `If-Match` or `If-None-Match` precondition failed.
    case preconditionFailed
    /// 413.
    case payloadTooLarge
    /// 423.
    case locked
    /// 507.
    case insufficientStorage
    /// 502, 503, or 504: a gateway or a server in maintenance, so no working
    /// server is reachable.
    case serverUnavailable(statusCode: Int)
    /// Any other 5xx.
    case serverError(statusCode: Int)
    /// Any other non-2xx status.
    case unexpectedStatus(statusCode: Int)

    // MARK: Transport

    /// No connectivity: not connected, connection lost, timed out, host not
    /// found or refusing, DNS failure, roaming off, or data not allowed.
    case offline(URLError.Code)
    /// The TLS handshake failed (`secureConnectionFailed`).
    case tlsHandshakeFailed(URLError.Code)
    /// The server certificate is expired, not yet valid, untrusted, or has an
    /// unknown root.
    case serverCertificateInvalid(URLError.Code)
    /// The server rejected or demanded a client certificate.
    case clientCertificateRequired(URLError.Code)
    /// App Transport Security refused a plain `http` connection.
    case secureConnectionRequired(URLError.Code)
    /// `userCancelledAuthentication`: the system gave up on the credentials.
    case authenticationRejected(URLError.Code)
    /// Any other `URLError`, kept whole for its description.
    case transport(URLError)
    /// The live transport stopped a body over its size cap.
    case responseTooLarge
    /// The live transport got a response that is not HTTP.
    case invalidResponse

    /// The error for an HTTP status, or nil for 2xx.
    ///
    /// - Parameter isPropfind: a 405 or 501 to PROPFIND means the server is
    ///   not a WebDAV server rather than that one method was refused.
    public init?(statusCode: Int, isPropfind: Bool = false) {
        switch statusCode {
        case 200..<300: return nil
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404, 410: self = .notFound(statusCode: statusCode)
        case 405, 501:
            self = isPropfind ? .notWebDAVServer(statusCode: statusCode) : .methodRejected(statusCode: statusCode)
        case 412: self = .preconditionFailed
        case 413: self = .payloadTooLarge
        case 423: self = .locked
        case 507: self = .insufficientStorage
        case 502, 503, 504: self = .serverUnavailable(statusCode: statusCode)
        case 500...599: self = .serverError(statusCode: statusCode)
        default: self = .unexpectedStatus(statusCode: statusCode)
        }
    }

    /// Classifies a `URLError`. TLS and ATS failures are never `offline`.
    public init(_ error: URLError) {
        switch error.code {
        case .secureConnectionFailed:
            self = .tlsHandshakeFailed(error.code)
        case .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            self = .serverCertificateInvalid(error.code)
        case .clientCertificateRejected, .clientCertificateRequired:
            self = .clientCertificateRequired(error.code)
        case .appTransportSecurityRequiresSecureConnection:
            self = .secureConnectionRequired(error.code)
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed:
            self = .offline(error.code)
        case .userCancelledAuthentication:
            self = .authenticationRejected(error.code)
        default:
            self = .transport(error)
        }
    }
}
