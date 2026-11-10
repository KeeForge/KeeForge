import Foundation
import RemoteFileTransports
import XCTest
@testable import KeeForge

/// The provider errors and messages the app gives `WebDAVError`. The package
/// tests which `WebDAVError` a status or `URLError` becomes; these pin what the
/// user then reads and what counts as offline.
final class WebDAVErrorMessageTests: XCTestCase {
    // MARK: - HTTP status mapping

    func testMapHTTPStatusTable() {
        XCTAssertEqual(CloudProviderError.webDAVStatus(401), .notAuthenticated)

        // 403 maps to .unknown (access denied), NOT .writeScopeRequired.
        guard case .unknown(let denied)? = CloudProviderError.webDAVStatus(403) else {
            return XCTFail("403 should map to .unknown")
        }
        XCTAssertTrue(denied.lowercased().contains("denied"))
        XCTAssertNotEqual(CloudProviderError.webDAVStatus(403), .writeScopeRequired)

        XCTAssertEqual(CloudProviderError.webDAVStatus(404), .fileNotFound)
        XCTAssertEqual(CloudProviderError.webDAVStatus(410), .fileNotFound)

        // 405 on PROPFIND: "not a WebDAV server".
        guard case .unknown(let propfind405)? = CloudProviderError.webDAVStatus(405, isPropfind: true) else {
            return XCTFail("405 PROPFIND should map to .unknown")
        }
        XCTAssertTrue(propfind405.lowercased().contains("webdav"))

        // 405 generic: different message, no WebDAV mention.
        guard case .unknown(let generic405)? = CloudProviderError.webDAVStatus(405, isPropfind: false) else {
            return XCTFail("405 generic should map to .unknown")
        }
        XCTAssertFalse(generic405.lowercased().contains("webdav server"))

        XCTAssertEqual(CloudProviderError.webDAVStatus(412), .conflict(remoteRev: nil))

        for storageCode in [413, 507] {
            guard case .unknown? = CloudProviderError.webDAVStatus(storageCode) else {
                return XCTFail("\(storageCode) should map to .unknown")
            }
        }

        guard case .unknown(let locked)? = CloudProviderError.webDAVStatus(423) else {
            return XCTFail("423 should map to .unknown")
        }
        XCTAssertTrue(locked.lowercased().contains("locked"))

        // Gateway / maintenance statuses read as "server unreachable" so an
        // open takes the calm cached-copy path.
        for unreachableCode in [502, 503, 504] {
            let mapped = CloudProviderError.webDAVStatus(unreachableCode)
            XCTAssertEqual(mapped, .serviceUnavailable)
            if let mapped {
                XCTAssertTrue(
                    CloudProviderError.isLikelyOffline(mapped),
                    "\(unreachableCode) must count as offline for the cache fallback"
                )
            }
        }

        for serverCode in [500, 501, 508] {
            guard case .unknown? = CloudProviderError.webDAVStatus(serverCode) else {
                return XCTFail("\(serverCode) should map to .unknown")
            }
        }

        // 2xx → nil (no error).
        XCTAssertNil(CloudProviderError.webDAVStatus(200))
        XCTAssertNil(CloudProviderError.webDAVStatus(207))
        XCTAssertNil(CloudProviderError.webDAVStatus(204))
    }

    // MARK: - URLError mapping

    func testMapURLErrorOfflineFamily() {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .internationalRoamingOff,
            .dataNotAllowed,
        ]
        for code in offlineCodes {
            XCTAssertEqual(
                mapURLError(URLError(code)),
                .networkUnavailable,
                "Expected \(code) → .networkUnavailable"
            )
        }
    }

    func testMapURLErrorTLSAndATSMapToSecureConnectionNotOffline() {
        // (code, required message fragment). Each TLS/ATS family gets its own
        // actionable message: a handshake failure must point at the server's
        // TLS configuration — NOT the certificate, which may be valid (e.g. a
        // server offering only cipher suites this device does not implement).
        let tlsCases: [(Int, String)] = [
            (NSURLErrorSecureConnectionFailed, "tls settings"),            // -1200
            (NSURLErrorServerCertificateHasBadDate, "certificate"),        // -1201
            (NSURLErrorServerCertificateUntrusted, "certificate"),         // -1202
            (NSURLErrorServerCertificateHasUnknownRoot, "certificate"),    // -1203
            (NSURLErrorServerCertificateNotYetValid, "certificate"),       // -1204
            (NSURLErrorClientCertificateRejected, "client certificate"),   // -1205
            (NSURLErrorClientCertificateRequired, "client certificate"),   // -1206
            (NSURLErrorAppTransportSecurityRequiresSecureConnection, "https://"), // -1022
        ]
        for (raw, fragment) in tlsCases {
            let error = URLError(URLError.Code(rawValue: raw))
            let mapped = mapURLError(error)
            guard case .unknown(let message) = mapped else {
                XCTFail("Expected \(raw) → .unknown secure-connection message, got \(mapped)")
                continue
            }
            XCTAssertTrue(message.lowercased().contains("secure"), "Code \(raw) message must mention the secure connection")
            XCTAssertTrue(
                message.lowercased().contains(fragment),
                "Code \(raw) message must contain \"\(fragment)\", got: \(message)"
            )
            XCTAssertNotEqual(mapped, .networkUnavailable, "TLS code \(raw) must NOT be .networkUnavailable")
        }

        // A handshake failure must not blame the certificate.
        if case .unknown(let handshakeMessage) = mapURLError(
            URLError(URLError.Code(rawValue: NSURLErrorSecureConnectionFailed))
        ) {
            XCTAssertFalse(handshakeMessage.lowercased().contains("certificate"))
        }
    }

    func testMapURLErrorUserCancelledAuthentication() {
        let error = URLError(URLError.Code(rawValue: NSURLErrorUserCancelledAuthentication))
        XCTAssertEqual(mapURLError(error), .notAuthenticated)
    }

    func testEveryMessageMatchesItsCatalogKey() throws {
        // Running in the source locale, each message must be the catalog's
        // English text verbatim: a changed literal would be a new key.
        let expected: [(WebDAVError, String)] = [
            (.forbidden, "The server denied access. Check that this account has permission for this file or folder."),
            (.notWebDAVServer(statusCode: 405), "This server does not look like a WebDAV server (HTTP 405). Check the server address."),
            (.methodRejected(statusCode: 501), "The server rejected this request (HTTP 501)."),
            (.locked, "The remote database is locked by another client. Try again shortly."),
            (.payloadTooLarge, "The database is too large for this server (HTTP 413)."),
            (.insufficientStorage, "The server is out of storage space (HTTP 507)."),
            (.serverError(statusCode: 500), "The server reported an error (HTTP 500). Try again shortly."),
            (.unexpectedStatus(statusCode: 302), "The server returned an unexpected response (HTTP 302)."),
            (
                .tlsHandshakeFailed(.secureConnectionFailed),
                "Could not establish a secure connection. The server's TLS settings are likely outdated or incompatible with this device. Ask the server operator to enable TLS 1.3, or TLS 1.2 with modern (ECDHE + AES-GCM) cipher suites."
            ),
            (
                .serverCertificateInvalid(.serverCertificateUntrusted),
                "Could not establish a secure connection because the server's certificate is invalid, expired, or untrusted."
            ),
            (
                .clientCertificateRequired(.clientCertificateRequired),
                "Could not establish a secure connection. The server requires a client certificate, which KeeForge does not support."
            ),
            (
                .secureConnectionRequired(.appTransportSecurityRequiresSecureConnection),
                "Could not establish a secure connection. This device requires an https:// server address."
            ),
            (.responseTooLarge, "The server returned an unexpectedly large response. The transfer was stopped to protect memory."),
            (.invalidResponse, "The server returned an unexpected response."),
        ]
        guard Locale.current.language.languageCode?.identifier == "en" else {
            throw XCTSkip("Messages are compared in English")
        }
        for (error, message) in expected {
            XCTAssertEqual(CloudProviderError(error), .unknown(message))
        }
    }

    func testUnclassifiedErrorsKeepTheirOwnDescription() {
        let urlError = URLError(.badServerResponse)
        XCTAssertEqual(CloudProviderError(WebDAVError(urlError)), .unknown(urlError.localizedDescription))
        XCTAssertEqual(
            CloudProviderError.webDAVTransport(CancellationError()),
            .unknown(CancellationError().localizedDescription)
        )
        XCTAssertEqual(CloudProviderError.webDAVTransport(CloudProviderError.rateLimited), .rateLimited)
        XCTAssertEqual(
            CloudProviderError.webDAVTransport(WebDAVError.offline(.timedOut)),
            .networkUnavailable
        )
    }

    private func mapURLError(_ error: URLError) -> CloudProviderError {
        CloudProviderError(WebDAVError(error))
    }
}
