import XCTest
@testable import SiteMatching

final class SiteHostTests: XCTestCase {

    // MARK: - Parsing

    func testParsesURLsAndBareHosts() {
        let cases: [(input: String, host: String)] = [
            ("https://github.com/login", "github.com"),
            ("http://example.org/page", "example.org"),
            ("https://example.com:8443/path", "example.com"),
            ("https://example.com/path?q=1#section", "example.com"),
            ("https://accounts.google.com", "accounts.google.com"),
            ("http://account:secret@wiki.example.com:8443/login?token=abc#top", "wiki.example.com"),
            ("example.com", "example.com"),
            ("example.com/login", "example.com"),
            ("example.com:8080", "example.com"),
            ("HTTPS://One.Sitio.COM./", "one.sitio.com"),
            ("https://中国.cn", "xn--fiqs8s.cn"),
            ("otpauth://totp/x", "totp"),
            ("https://[::1]:8080/", "::1"),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(testCase.input)?.name, testCase.host, testCase.input)
        }
    }

    func testRejectsInputWithNoHost() {
        for input in ["", "   ", "https://."] {
            XCTAssertNil(SiteHost(input), input.debugDescription)
        }
    }

    /// `URL(string:)` rejects these, and the `https://` retry reads the
    /// original scheme as the host. Pinned as found; the result is a single
    /// label and never publishable.
    func testUnparsableURLFallsBackToItsSchemeAsHost() {
        XCTAssertEqual(SiteHost("http://ho st/")?.name, "http")
        XCTAssertEqual(SiteHost("http://ho st/")?.isPublishable, false)
        XCTAssertEqual(SiteHost("https://")?.name, "https")
        XCTAssertEqual(SiteHost.parse("https://."), "")
    }

    func testDropsWWWOnlyAboveARegistrableDomain() {
        let cases: [(input: String, host: String)] = [
            ("https://www.facebook.com", "facebook.com"),
            ("www.facebook.com", "facebook.com"),
            ("https://www.example.co.uk/login", "example.co.uk"),
            ("https://www.co.uk/login", "www.co.uk"),
            ("https://www.com", "www.com"),
            ("WWW.com.", "www.com"),
            // `!www.ck` is an exception to the `*.ck` wildcard rule.
            ("https://www.ck", "www.ck"),
            ("https://www.www.co.uk", "www.co.uk"),
            ("https://www.www.example.com", "www.example.com"),
            ("https://www.localhost", "www.localhost"),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(testCase.input)?.name, testCase.host, testCase.input)
        }
    }

    func testDescriptionIsTheName() {
        XCTAssertEqual(SiteHost("https://Example.com")?.description, "example.com")
    }

    // MARK: - Publishable

    func testPublishableHostsKeepTheirSubdomain() {
        let cases: [(input: String, host: String)] = [
            ("https://login.facebook.com/path", "login.facebook.com"),
            ("https://news.bbc.co.uk", "news.bbc.co.uk"),
            ("https://www.bbc.co.uk", "bbc.co.uk"),
            ("https://login.mybank.com.pl", "login.mybank.com.pl"),
            ("https://account.example.github.io", "account.example.github.io"),
            ("https://www.co.uk/login", "www.co.uk"),
            ("https://www.ck", "www.ck"),
        ]
        for testCase in cases {
            XCTAssertEqual(publishedHost(testCase.input), testCase.host, testCase.input)
        }
    }

    func testHostsWithoutARegistrableDomainAreNotPublishable() {
        for input in [
            "https://192.168.1.1/path", "http://localhost:8080", "https://intranet",
            "https://co.uk", "https://github.io", "https://com", "https://[::1]/", "https://[2001:db8::1]/",
        ] {
            XCTAssertNil(publishedHost(input), input)
        }
    }

    func testPublishableWebURLKeepsTheExactHost() {
        let cases: [(input: String, host: String?)] = [
            ("https://vt.example.com/login", "vt.example.com"),
            ("vt.example.com/login", "vt.example.com"),
            ("vt.example.com:8443/otp", "vt.example.com"),
            ("https://WWW.Example.com./login", "example.com"),
            ("  https://VT.EXAMPLE.COM/duplicate  ", "vt.example.com"),
            ("https://www.co.uk/otp", "www.co.uk"),
            ("otpauth://totp/example:user?secret=JBSWY3DPEHPK3PXP", nil),
            ("ftp://example.com/otp", nil),
            ("https://localhost:8080/otp", nil),
            ("https://192.168.1.1/otp", nil),
            ("https://co.uk", nil),
            ("", nil),
            ("   ", nil),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(publishableWebURL: testCase.input)?.name, testCase.host, testCase.input)
        }
    }

    /// The web-URL check runs before the `www` rule and `isPublishable` after
    /// it. They disagree only where stripping `www` leaves all-numeric labels.
    /// Pinned as found.
    func testPublishableChecksDisagreeOnWWWBeforeNumericLabels() {
        XCTAssertEqual(SiteHost(publishableWebURL: "https://www.1.1")?.name, "1.1")
        XCTAssertNil(publishedHost("https://www.1.1"))
    }

    // MARK: - Shared registrable domain

    func testSharesRegistrableDomain() throws {
        let login = try XCTUnwrap(SiteHost("login.example.com"))
        XCTAssertTrue(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("https://www.example.com/account"))))
        XCTAssertTrue(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("example.com"))))
        XCTAssertFalse(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("examp1e.com"))))
        XCTAssertFalse(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("example.com.evil.test"))))
    }

    func testHostWithoutADomainSharesOnlyWithItself() throws {
        let localhost = try XCTUnwrap(SiteHost("http://localhost:8080"))
        XCTAssertTrue(localhost.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("localhost"))))
        XCTAssertFalse(localhost.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("example.com"))))
    }

    /// No IP checks here, unlike `isPublishable`. Pinned as found.
    func testIPv4AddressesSharingTheLastTwoOctetsShareADomain() throws {
        let address = try XCTUnwrap(SiteHost("https://192.168.1.1"))
        XCTAssertTrue(address.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("https://10.0.1.1"))))
    }

    // MARK: - Relying-party key

    func testRelyingPartyKey() {
        XCTAssertEqual(SiteHost.relyingPartyKey(" https://WWW.Example.com/path "), "example.com")
        XCTAssertEqual(SiteHost.relyingPartyKey("Login.Example.com"), "login.example.com")
        XCTAssertEqual(SiteHost.relyingPartyKey(""), "")
        XCTAssertEqual(SiteHost.relyingPartyKey("   "), "")
        XCTAssertEqual(SiteHost.relyingPartyKey("http://ho st"), "http", "Falls back like SiteHost parsing")
        XCTAssertEqual(SiteHost.relyingPartyKey("WWW.A B"), "a b", "Unparsable input is compared lowercased as given")
    }

    /// The relying-party key drops `www.` unconditionally; `SiteHost` keeps it
    /// when it is the registrable label. Pinned as found.
    func testRelyingPartyKeyDropsWWWWhereSiteHostKeepsIt() {
        XCTAssertEqual(SiteHost.relyingPartyKey("www.co.uk"), "co.uk")
        XCTAssertEqual(SiteHost("www.co.uk")?.name, "www.co.uk")
        XCTAssertEqual(SiteHost.relyingPartyKey("www.localhost"), "localhost")
        XCTAssertEqual(SiteHost.relyingPartyKey("www.www.example.com"), "example.com")
    }

    // MARK: - Helpers

    /// What a password identity publishes for a URL field.
    private func publishedHost(_ url: String) -> String? {
        SiteHost(url).flatMap { $0.isPublishable ? $0.name : nil }
    }
}
