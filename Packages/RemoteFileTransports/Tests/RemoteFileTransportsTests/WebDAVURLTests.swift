import Foundation
import XCTest
@testable import RemoteFileTransports

/// The pure URL rules for WebDAV accounts: normalization and display name.
final class WebDAVURLTests: XCTestCase {
    func testNormalizedBaseURLAddsTrailingSlash() throws {
        let url = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/remote.php/dav")
        XCTAssertEqual(url.absoluteString, "https://cloud.example.com/remote.php/dav/")
    }

    func testNormalizedBaseURLLowercasesSchemeAndHostPreservesPathCase() throws {
        let url = try WebDAVURL.normalizedBaseURL(from: "HTTPS://Cloud.EXAMPLE.com/Remote.PHP/DAV/Files/")
        XCTAssertEqual(url.absoluteString, "https://cloud.example.com/Remote.PHP/DAV/Files/")
    }

    func testNormalizedBaseURLDropsDefault443KeepsCustomPort() throws {
        let dropped = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com:443/dav")
        XCTAssertEqual(dropped.absoluteString, "https://cloud.example.com/dav/")

        let kept = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com:8443/dav")
        XCTAssertEqual(kept.absoluteString, "https://cloud.example.com:8443/dav/")
    }

    func testNormalizedBaseURLRejectsHTTP() {
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "http://cloud.example.com/dav")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .insecureScheme)
        }
    }

    func testNormalizedBaseURLAllowsHTTPOnlyWithExplicitOptIn() throws {
        let url = try WebDAVURL.normalizedBaseURL(
            from: "HTTP://Vault.Local:80/DAV",
            allowsUnencryptedHTTP: true
        )

        XCTAssertEqual(url.absoluteString, "http://vault.local/DAV/")
    }

    func testNormalizedBaseURLRejectsEmpty() {
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "   ")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .empty)
        }
    }

    func testNormalizedBaseURLRejectsGarbageAndMissingHost() {
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "not a url ::::")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .malformed)
        }
        // Scheme present but no host.
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "https:///dav")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .missingHost)
        }
    }

    func testNormalizedBaseURLDropsDefault80OnlyForHTTP() throws {
        XCTAssertEqual(
            try WebDAVURL.normalizedBaseURL(from: "http://vault.local:8080/", allowsUnencryptedHTTP: true).absoluteString,
            "http://vault.local:8080/"
        )
        XCTAssertEqual(try WebDAVURL.normalizedBaseURL(from: "https://vault.local:80").absoluteString, "https://vault.local:80/")
        XCTAssertEqual(try WebDAVURL.normalizedBaseURL(from: "https://vault.local").absoluteString, "https://vault.local/")
    }

    func testNormalizedBaseURLRequiresAScheme() {
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "cloud.example.com/dav")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .malformed)
        }
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "ftp://cloud.example.com/")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .insecureScheme)
        }
    }

    func testDisplayNameIsUserAtHostAndPath() throws {
        let nested = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/remote.php/dav/files/alice")
        XCTAssertEqual(
            WebDAVURL.displayName(normalizedBaseURL: nested, username: "alice"),
            "alice@cloud.example.com/remote.php/dav/files/alice"
        )
        let root = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com")
        XCTAssertEqual(WebDAVURL.displayName(normalizedBaseURL: root, username: "alice"), "alice@cloud.example.com")
    }
}
