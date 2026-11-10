import Foundation
import RemoteFileTransports

extension CloudProviderError {
    /// The provider error and message for a WebDAV failure. Offline-family
    /// failures and 502/503/504 become `.networkUnavailable` and
    /// `.serviceUnavailable`, which `isLikelyOffline` relies on; TLS and ATS
    /// failures get explicit messages so they are never mislabeled offline.
    init(_ error: WebDAVError) {
        switch error {
        case .unauthorized, .authenticationRejected:
            self = .notAuthenticated
        case .forbidden:
            // Not .writeScopeRequired: its message ("Reconnect this cloud
            // account") is wrong advice for a WebDAV permission denial.
            self = .unknown(String(localized: "The server denied access. Check that this account has permission for this file or folder."))
        case .notFound:
            self = .fileNotFound
        case .notWebDAVServer(let statusCode):
            self = .unknown(String(localized: "This server does not look like a WebDAV server (HTTP \(statusCode)). Check the server address."))
        case .methodRejected(let statusCode):
            self = .unknown(String(localized: "The server rejected this request (HTTP \(statusCode))."))
        case .preconditionFailed:
            self = .conflict(remoteRev: nil)
        case .locked:
            self = .unknown(String(localized: "The remote database is locked by another client. Try again shortly."))
        case .payloadTooLarge:
            self = .unknown(String(localized: "The database is too large for this server (HTTP 413)."))
        case .insufficientStorage:
            self = .unknown(String(localized: "The server is out of storage space (HTTP 507)."))
        case .serverUnavailable:
            self = .serviceUnavailable
        case .serverError(let statusCode):
            self = .unknown(String(localized: "The server reported an error (HTTP \(statusCode)). Try again shortly."))
        case .unexpectedStatus(let statusCode):
            self = .unknown(String(localized: "The server returned an unexpected response (HTTP \(statusCode))."))
        case .offline:
            self = .networkUnavailable
        // The certificate may be valid here (a server offering no cipher
        // suites this device implements fails the same way), so blame the
        // server's TLS configuration, not the certificate.
        case .tlsHandshakeFailed:
            self = .unknown(String(localized: "Could not establish a secure connection. The server's TLS settings are likely outdated or incompatible with this device. Ask the server operator to enable TLS 1.3, or TLS 1.2 with modern (ECDHE + AES-GCM) cipher suites."))
        case .serverCertificateInvalid:
            self = .unknown(String(localized: "Could not establish a secure connection because the server's certificate is invalid, expired, or untrusted."))
        case .clientCertificateRequired:
            self = .unknown(String(localized: "Could not establish a secure connection. The server requires a client certificate, which KeeForge does not support."))
        case .secureConnectionRequired:
            self = .unknown(String(localized: "Could not establish a secure connection. This device requires an https:// server address."))
        case .transport(let urlError):
            self = .unknown(urlError.localizedDescription)
        case .responseTooLarge:
            self = .unknown(String(localized: "The server returned an unexpectedly large response. The transfer was stopped to protect memory."))
        case .invalidResponse:
            self = .unknown(String(localized: "The server returned an unexpected response."))
        }
    }

    /// The provider error for an HTTP status, or nil for 2xx.
    static func webDAVStatus(_ statusCode: Int, isPropfind: Bool = false) -> CloudProviderError? {
        WebDAVError(statusCode: statusCode, isPropfind: isPropfind).map(CloudProviderError.init)
    }

    /// The provider error for anything a `WebDAVClient` operation throws. An
    /// error the client did not classify keeps its own description.
    static func webDAVTransport(_ error: Error) -> CloudProviderError {
        switch error {
        case let error as WebDAVError: CloudProviderError(error)
        case let error as CloudProviderError: error
        default: .unknown(error.localizedDescription)
        }
    }
}
