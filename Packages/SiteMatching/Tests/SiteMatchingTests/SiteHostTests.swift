import XCTest
@testable import SiteMatching

/// Host rules H1–H7, relying-party keys K1–K2, and publishing P1 and P3.
final class SiteHostTests: XCTestCase {

    // MARK: - Hosts

    func testH1ParsesWebURLsAndBareHosts() {
        let cases: [(input: String, host: String)] = [
            ("https://github.com/login", "github.com"),
            ("https://example.com/path?q=1#section", "example.com"),
            ("https://accounts.google.com", "accounts.google.com"),
            ("http://account:secret@wiki.example.com/login?token=abc#top", "wiki.example.com"),
            ("example.com", "example.com"),
            ("example.com/login", "example.com"),
            ("example.com/redirect?to=https://other.example", "example.com"),
            ("1password.com/login?next=https://other.example", "1password.com"),
            ("localhost:3000", "localhost"),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(testCase.input)?.name, testCase.host, testCase.input)
        }
    }

    func testH1IgnoresSurroundingWhitespace() {
        for input in ["  https://github.com/login", "https://github.com/login  ", "\tgithub.com\n"] {
            XCTAssertEqual(SiteHost(input)?.name, "github.com", input.debugDescription)
        }
    }

    func testH1InputWithNoHostNamesNoSite() {
        for input in ["", "   ", "https://."] {
            XCTAssertNil(SiteHost(input), input.debugDescription)
        }
        XCTAssertEqual(SiteHost.parse("https://."), "")
    }

    /// Android KeePass clients store apps as `androidapp://<package>`, whose
    /// host would otherwise be a subdomain of an unrelated website.
    func testH1OtherSchemesNameNoSite() {
        for input in [
            "androidapp://com.mybank.app", "ftp://files.example.com", "ssh://server.example.com:22", "otpauth://totp/x",
            "file:///Users/x/notes.txt", "cmd://open https://example.com", "kdbx://other.kdbx",
        ] {
            XCTAssertNil(SiteHost(input), input)
        }
    }

    /// A value with a scheme is never parsed a second time, so a URL
    /// Foundation rejects is not read as a host named after its scheme.
    func testH1URLFoundationRejectsNamesNoSite() {
        for input in ["http://ho st/", "https://my site.com", "https://", "https://example\t.com"] {
            XCTAssertNil(SiteHost(input), input.debugDescription)
        }
    }

    func testH1BackslashIsReadAsASlashAsInBrowsers() {
        let cases: [(input: String, host: String)] = [
            ("https://example.com\\@evil.example", "example.com"),
            ("https:\\\\example.com\\login", "example.com"),
            ("example.com\\login", "example.com"),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(testCase.input)?.name, testCase.host, testCase.input)
        }
    }

    func testH2SchemesAndPortsDoNotSeparateHosts() {
        let hosts = [
            "https://example.com", "http://example.com", "https://example.com:8443/login",
            "example.com:8080", "http://example.com:80", "HTTPS://example.com",
        ].map { SiteHost($0) }
        XCTAssertEqual(Set(hosts), [SiteHost("example.com")])
    }

    func testH3LowercasesDropsTrailingDotsAndUsesPunycode() {
        let cases: [(input: String, host: String)] = [
            ("HTTPS://One.Sitio.COM./", "one.sitio.com"),
            ("https://example.com..", "example.com"),
            ("https://中国.cn", "xn--fiqs8s.cn"),
            ("https://xn--fiqs8s.cn", "xn--fiqs8s.cn"),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(testCase.input)?.name, testCase.host, testCase.input)
        }
        XCTAssertEqual(SiteHost("https://Example.com")?.description, "example.com")
    }

    func testH4DropsWWWOnlyAboveARegistrableDomain() {
        let cases: [(input: String, host: String)] = [
            ("https://www.facebook.com", "facebook.com"),
            ("www.facebook.com", "facebook.com"),
            ("https://www.example.co.uk/login", "example.co.uk"),
            ("https://www.co.uk/login", "www.co.uk"),
            ("https://www.com", "www.com"),
            ("WWW.com.", "www.com"),
            // `!www.ck` is an exception to the `*.ck` wildcard rule.
            ("https://www.ck", "www.ck"),
            ("https://www.localhost", "www.localhost"),
            ("https://www.1.1", "www.1.1"),
            ("https://www.192.168.1.1", "www.192.168.1.1"),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(testCase.input)?.name, testCase.host, testCase.input)
        }
    }

    func testH5RegistrableDomainComesFromThePublicSuffixList() {
        let cases: [(host: String, domain: String?)] = [
            ("login.example.com", "example.com"),
            ("news.bbc.co.uk", "bbc.co.uk"),
            ("account.example.github.io", "example.github.io"),
            ("www.co.uk", "www.co.uk"),
            ("co.uk", nil),
            ("github.io", nil),
            ("com", nil),
            ("localhost", nil),
            ("intranet", nil),
        ]
        for testCase in cases {
            XCTAssertEqual(SiteHost(testCase.host)?.registrableDomain, testCase.domain, testCase.host)
        }
    }

    func testH6IPAddressesHaveNoRegistrableDomain() {
        let addresses = [
            "192.168.1.1", "1.1", "256", "foo.1.2.3.4", "foo.09", "foo.0x4", "foo.0x", "0xc0a80001",
            "::1", "2001:db8::1",
        ]
        for address in addresses {
            XCTAssertTrue(SiteHost.isIPAddress(address), address)
            XCTAssertNil(SiteHost.registrableDomain(of: address), address)
        }
        for name in ["example.com", "1password.com", "example.0xz", "foo.1a", "example.com.", ""] {
            XCTAssertFalse(SiteHost.isIPAddress(name), name.debugDescription)
        }
    }

    func testH7HostsAreNormalizedOnce() {
        XCTAssertEqual(SiteHost("https://www.www.example.com")?.name, "www.example.com")
        XCTAssertEqual(SiteHost("https://www.www.co.uk")?.name, "www.co.uk")
        let host = SiteHost("https://www.www.example.com")
        XCTAssertEqual(host.flatMap { SiteHost($0.name) }, SiteHost("www.example.com"))
    }

    // MARK: - Related sites (T3)

    func testT3RelatedSitesShareARegistrableDomain() throws {
        let login = try XCTUnwrap(SiteHost("login.example.com"))
        XCTAssertTrue(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("https://www.example.com/account"))))
        XCTAssertTrue(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("example.com"))))
        XCTAssertFalse(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("examp1e.com"))))
        XCTAssertFalse(login.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost("example.com.evil.test"))))
    }

    func testT3HostWithoutARegistrableDomainIsRelatedOnlyToItself() throws {
        let pairs: [(host: String, same: String, other: String)] = [
            ("http://localhost:8080", "localhost", "app.localhost"),
            ("https://192.168.1.1", "192.168.1.1", "10.0.1.1"),
            ("https://co.uk", "co.uk", "bank.co.uk"),
            ("https://[::1]", "[::1]", "[::2]"),
        ]
        for pair in pairs {
            let host = try XCTUnwrap(SiteHost(pair.host), pair.host)
            XCTAssertTrue(host.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost(pair.same))), pair.host)
            XCTAssertFalse(host.sharesRegistrableDomain(with: try XCTUnwrap(SiteHost(pair.other))), pair.host)
            XCTAssertFalse(try XCTUnwrap(SiteHost(pair.other)).sharesRegistrableDomain(with: host), pair.host)
        }
    }

    func testT2SubdomainNeedsTheParentsRegistrableDomain() throws {
        func host(_ value: String) throws -> SiteHost { try XCTUnwrap(SiteHost(value), value) }
        XCTAssertTrue(try host("login.paypal.com").isSubdomain(of: host("paypal.com")))
        XCTAssertTrue(try host("a.b.example.co.uk").isSubdomain(of: host("b.example.co.uk")))
        XCTAssertFalse(try host("paypal.com").isSubdomain(of: host("paypal.com")))
        XCTAssertFalse(try host("mypaypal.com").isSubdomain(of: host("paypal.com")))
        XCTAssertFalse(try host("bank.co.uk").isSubdomain(of: host("co.uk")))
        XCTAssertFalse(try host("alice.github.io").isSubdomain(of: host("github.io")))
        XCTAssertFalse(try host("foo.1.2.3.4").isSubdomain(of: host("1.2.3.4")))
        XCTAssertFalse(try host("app.localhost").isSubdomain(of: host("localhost")))
        // `s3.amazonaws.com` is a public suffix, so a bucket under it is its
        // own site, not a subdomain of `amazonaws.com`.
        XCTAssertFalse(try host("bucket.s3.amazonaws.com").isSubdomain(of: host("amazonaws.com")))
    }

    // MARK: - Publishing

    func testP1PublishableHostsKeepTheirSubdomain() {
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

    func testP1HostsWithoutARegistrableDomainAreNotPublishable() {
        for input in [
            "https://192.168.1.1/path", "http://localhost:8080", "https://intranet", "https://co.uk", "https://github.io",
            "https://com", "https://[::1]/", "https://[2001:db8::1]/", "http://foo.1.2.3.4", "http://foo.0x4",
        ] {
            XCTAssertNil(publishedHost(input), input)
            XCTAssertNil(SiteHost(publishableWebURL: input), input)
        }
    }

    /// Both publishing paths check the host after H4, so `www.1.1`, whose
    /// `www` stays because `1.1` is an IP address, is published by neither.
    func testP1PublishabilityIsCheckedAfterTheWWWRule() {
        for input in ["https://www.1.1", "https://www.192.168.1.1"] {
            XCTAssertNil(SiteHost(publishableWebURL: input), input)
            XCTAssertNil(publishedHost(input), input)
        }
    }

    func testP2PasswordIdentityPublishesOnlyWebHosts() {
        let cases: [(input: String, host: String?)] = [
            ("https://login.example.com/a", "login.example.com"),
            ("http://login.example.com/a", "login.example.com"),
            ("login.example.com", "login.example.com"),
            ("ftp://files.example.com", nil),
            ("ssh://server.example.com:22", nil),
            ("androidapp://com.mybank.app", nil),
            ("otpauth://totp/example:user", nil),
            ("A1B2C3D4E5.com.mybank.app/login", "a1b2c3d4e5.com.mybank.app"),
        ]
        for testCase in cases {
            XCTAssertEqual(publishedHost(testCase.input), testCase.host, testCase.input)
        }
    }

    func testP3PublishableWebURLKeepsTheExactHost() {
        let cases: [(input: String, host: String?)] = [
            ("https://vt.example.com/login", "vt.example.com"),
            ("http://vt.example.com/login", "vt.example.com"),
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

    /// Whatever either publishing path publishes for a stored value is the
    /// host matching reads from that same value.
    func testP4PublishedHostEqualsTheMatchedHost() {
        let inputs = [
            "https://vt.example.com/login", "  https://VT.EXAMPLE.COM/a  ", "vt.example.com:8443/otp", "https://WWW.Example.com./x",
            "https://www.co.uk", "https://www.www.example.com", "https://中国.cn/login", "http://[google.com]",
            "ftp://files.example.com", "https://www.1.1", "http://foo.1.2.3.4", "otpauth://totp/x",
        ]
        for input in inputs {
            let matched = SiteHost(input)
            if let published = SiteHost(publishableWebURL: input) {
                XCTAssertEqual(published, matched, input)
            }
            if let published = publishedHost(input) {
                XCTAssertEqual(published, matched?.name, input)
            }
        }
    }

    // MARK: - Relying-party key

    func testK1RelyingPartyKeyFollowsTheHostRule() {
        XCTAssertEqual(SiteHost.relyingPartyKey(" https://WWW.Example.com/path "), "example.com")
        XCTAssertEqual(SiteHost.relyingPartyKey("www.example.com"), SiteHost.relyingPartyKey("example.com"))
        XCTAssertEqual(SiteHost.relyingPartyKey("Login.Example.com"), "login.example.com")
        XCTAssertNotEqual(SiteHost.relyingPartyKey("login.example.com"), SiteHost.relyingPartyKey("example.com"))
        XCTAssertEqual(SiteHost.relyingPartyKey(""), "")
        XCTAssertEqual(SiteHost.relyingPartyKey("   "), "")
    }

    func testK1RelyingPartyKeyKeepsWWWWhereTheHostRuleDoes() {
        XCTAssertEqual(SiteHost.relyingPartyKey("www.co.uk"), "www.co.uk")
        XCTAssertNotEqual(SiteHost.relyingPartyKey("www.co.uk"), SiteHost.relyingPartyKey("co.uk"))
        XCTAssertEqual(SiteHost.relyingPartyKey("www.localhost"), "www.localhost")
        XCTAssertEqual(SiteHost.relyingPartyKey("www.www.example.com"), "www.example.com")
        for value in ["www.co.uk", "www.localhost", "www.www.example.com", "https://www.example.com/a"] {
            XCTAssertEqual(SiteHost.relyingPartyKey(value), SiteHost(value)?.name, value)
        }
    }

    func testK2UnparsableRelyingPartyIsNormalizedAsGiven() {
        XCTAssertEqual(SiteHost.relyingPartyKey("http://ho st"), "http://ho st")
        XCTAssertEqual(SiteHost.relyingPartyKey("WWW.A B."), "www.a b")
        XCTAssertEqual(SiteHost.relyingPartyKey("A B"), "a b")
    }

    // MARK: - Helpers

    /// What a password identity publishes for a URL field (P2).
    private func publishedHost(_ url: String) -> String? {
        SiteHost(url).flatMap { $0.isPublishable ? $0.name : nil }
    }
}
