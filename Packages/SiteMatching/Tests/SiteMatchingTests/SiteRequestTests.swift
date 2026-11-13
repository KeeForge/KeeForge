import XCTest
@testable import SiteMatching

/// Requests R1–R3.
final class SiteRequestTests: XCTestCase {

    func testR1RequestHostIsNormalizedOnce() {
        XCTAssertEqual(SiteRequest.domain("GitHub.com.").host?.name, "github.com")
        XCTAssertEqual(SiteRequest.domain("www.example.co.uk").host?.name, "example.co.uk")
        XCTAssertEqual(SiteRequest.domain("www.www.example.com").host?.name, "www.example.com")
        XCTAssertEqual(SiteRequest.domain("中国.cn").host?.name, "xn--fiqs8s.cn")
        XCTAssertEqual(SiteRequest.url("https://github.com/login").host?.name, "github.com")
        XCTAssertEqual(SiteRequest.url("https://www.www.example.com/a").host?.name, "www.example.com")
        XCTAssertNil(SiteRequest.url("not a url").host)
        XCTAssertNil(SiteRequest.url("ftp://files.example.com").host)
        XCTAssertNil(SiteRequest.url("https://my site.com").host)
        XCTAssertNil(SiteRequest.domain("").host)
    }

    func testR2AppRequestHasNoHost() {
        XCTAssertNil(SiteRequest.app("A1B2C3D4E5.com.mybank.app").host)
    }

    func testR3WebsiteKeepsOnlySchemeHostAndPort() {
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
