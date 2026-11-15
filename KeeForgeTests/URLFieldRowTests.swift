#if os(iOS)
import XCTest
@testable import KeeForge

/// The iOS entry detail's URL rows offer Open only for an `http` or `https` URL; Copy stays.
@MainActor
final class URLFieldRowTests: XCTestCase {
    func testOnlyHTTPAndHTTPSURLsOpen() {
        XCTAssertEqual(URLFieldRow(url: "https://example.com/login").link, URL(string: "https://example.com/login"))
        XCTAssertEqual(URLFieldRow(url: "example.com").link, URL(string: "https://example.com"))
        for refused in ["file:///etc/hosts", "javascript:alert(1)", "ssh://host.example", "myapp://open", "https:"] {
            XCTAssertNil(URLFieldRow(url: refused, label: "URL 2").link, refused)
        }
    }
}
#endif
