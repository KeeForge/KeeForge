import XCTest
@testable import SiteMatching

final class SiteRequestTests: XCTestCase {

    func testSearchTerm() {
        XCTAssertEqual(SiteRequest.domain("GitHub.com.").searchTerm, "github.com")
        XCTAssertEqual(SiteRequest.domain("www.example.co.uk").searchTerm, "example.co.uk")
        XCTAssertEqual(SiteRequest.url("https://github.com/login").searchTerm, "github.com")
        XCTAssertEqual(SiteRequest.url("not a url").searchTerm, "not a url", "A URL with no host is matched as given")
        XCTAssertNil(SiteRequest.app("A1B2C3D4E5.com.mybank.app").searchTerm)
    }

    func testWebsiteKeepsOnlySchemeHostAndPort() {
        let cases: [(request: SiteRequest, host: String?, url: String?)] = [
            (.url("https://Login.Example.com/path?token=abc#frag"), "login.example.com", "https://login.example.com"),
            (.url("http://user:pw@intranet.local:8080/login"), "intranet.local:8080", "http://intranet.local:8080"),
            (.url("login.example.com/signin"), "login.example.com", "https://login.example.com"),
            (.url("ftp://files.example.com"), "files.example.com", "https://files.example.com"),
            (.url("  https://example.com  "), "example.com", "https://example.com"),
            (.domain("example.com."), "example.com", "https://example.com"),
            (.domain("www.example.com"), "www.example.com", "https://www.example.com"),
            (.url(""), nil, nil),
            (.url("https://."), nil, nil),
            (.url("a b"), nil, nil),
            (.app("A1B2C3D4E5.com.mybank.app"), nil, nil),
        ]
        for testCase in cases {
            XCTAssertEqual(testCase.request.website?.host, testCase.host, "\(testCase.request)")
            XCTAssertEqual(testCase.request.website?.url, testCase.url, "\(testCase.request)")
        }
    }
}
