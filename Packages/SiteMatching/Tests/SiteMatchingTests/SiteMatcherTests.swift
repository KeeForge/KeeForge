import XCTest
@testable import SiteMatching

final class SiteMatcherTests: XCTestCase {

    // MARK: - Interactive tiers

    func testInteractiveMatchesUseFirstWebHostAndEveryURLField() {
        let parent = candidate("https://cvmd.com.ar")
        let sibling = candidate("https://other.cvmd.com.ar")
        let child = candidate("https://child.vt.cvmd.com.ar")
        let exact = candidate("https://vt.cvmd.com.ar")
        let additional = candidate("https://unrelated.example", "https://vt.cvmd.com.ar/login")

        let matches = SiteMatcher.interactiveMatches(
            [parent, sibling, child, exact, additional],
            for: [.domain("vt.cvmd.com.ar"), .domain("cvmd.com.ar")]
        )

        XCTAssertEqual(matches.exact, [exact.id, additional.id])
        XCTAssertTrue(matches.possible.isEmpty)
    }

    func testInteractiveFallbackDeduplicatesAndPrioritizes() {
        let sibling = candidate("https://other.cvmd.com.ar")
        let parent = candidate("https://cvmd.com.ar")
        let unrelated = candidate("https://cvmd.com.ar.evil.example")

        let matches = SiteMatcher.interactiveMatches(
            [sibling, unrelated, parent],
            for: [.domain("vt.cvmd.com.ar"), .domain("cvmd.com.ar")]
        )

        XCTAssertTrue(matches.exact.isEmpty)
        // `parent` is both a strict and a possible match; it appears once, ahead
        // of the sibling because it stores the second requested host itself.
        XCTAssertEqual(matches.possible, [parent.id, sibling.id])
    }

    func testInteractiveMatchesAreEmptyWithoutAWebHost() {
        let entry = candidate("https://mybank.app")
        XCTAssertEqual(
            SiteMatcher.interactiveMatches([entry], for: [.app("A1B2C3D4E5.com.mybank.app")]),
            SiteMatcher.InteractiveMatches(exact: [], possible: [])
        )
        XCTAssertEqual(SiteMatcher.interactiveMatches([entry], for: []).possible, [])
    }

    func testPrioritizesExactHostThenSubdomainInRequestOrder() {
        let sibling = candidate("https://other.example.com")
        let child = candidate("https://child.vt.example.com")
        let exact = candidate("https://vt.example.com")
        let secondSibling = candidate("https://mail.example.com")
        let none = candidate("https://unrelated.test")

        let sorted = SiteMatcher.prioritizing(
            [none, sibling, child, exact, secondSibling],
            for: [.domain("vt.example.com"), .domain("example.com")]
        )

        XCTAssertEqual(sorted.map(\.id), [exact.id, child.id, sibling.id, secondSibling.id, none.id])
    }

    func testFirstWebHostSkipsAppsAndUnparsableRequests() {
        XCTAssertNil(SiteMatcher.firstWebHost(for: []))
        XCTAssertNil(SiteMatcher.firstWebHost(for: [.app("A1B2C3D4E5.com.example.app"), .domain("")]))
        XCTAssertEqual(
            SiteMatcher.firstWebHost(for: [.app("A1B2C3D4E5.com.example.app"), .url("https://WWW.Example.com/a")])?.name,
            "example.com"
        )
    }

    // MARK: - Strict tier

    func testStrictMatchesExactHostAndDottedSubdomains() {
        let exact = candidate("https://paypal.com/signin")
        let login = candidate("https://login.paypal.com")
        let gist = candidate("https://example.org", "https://gist.paypal.com")

        XCTAssertEqual(SiteMatcher.strictMatches([exact, login, gist], for: [.domain("paypal.com")]), [exact.id, login.id, gist.id])
    }

    func testStrictRejectsSubstringsPathsAndParents() {
        let cases: [(stored: String, request: SiteRequest)] = [
            ("https://mybank.com/login", .domain("bank.com")),
            ("https://paypal.com", .domain("pal.com")),
            ("https://evil.example/bank.com/login", .domain("bank.com")),
            ("https://google.com", .url("https://accounts.google.com/signin")),
            ("https://github.com", .domain("gitlab.com")),
        ]
        for testCase in cases {
            XCTAssertTrue(
                SiteMatcher.strictMatches([candidate(testCase.stored)], for: [testCase.request]).isEmpty,
                "\(testCase.stored) for \(testCase.request)"
            )
        }
    }

    func testStrictMatchesURLRequestsCaseInsensitively() {
        let settings = candidate("https://GitHub.Com/settings")
        XCTAssertEqual(SiteMatcher.strictMatches([settings], for: [.url("https://github.com/login")]), [settings.id])
        XCTAssertEqual(SiteMatcher.strictMatches([settings], for: [.domain("GITHUB.COM")]), [settings.id])
    }

    func testStrictMatchesSeveralCandidatesAndSkipsEmptyFields() {
        let work = candidate("https://github.com/work")
        let personal = candidate("https://github.com/personal")
        let other = candidate("https://other.com", "")
        XCTAssertEqual(SiteMatcher.strictMatches([work, personal, other], for: [.domain("github.com")]), [work.id, personal.id])
        XCTAssertTrue(SiteMatcher.strictMatches([other], for: [.domain("somethingelse.com")]).isEmpty)
    }

    func testStrictMatchesNothingForNoRequests() {
        XCTAssertTrue(SiteMatcher.strictMatches([candidate("https://a.com")], for: []).isEmpty)
    }

    /// Reading a `www.co.uk` request as `co.uk` would make every entry under
    /// that public suffix a strict match.
    func testWWWAsRegistrableLabelDoesNotMatchAcrossItsPublicSuffix() {
        let own = candidate("https://www.co.uk/login")
        let other = candidate("https://bank.co.uk")
        for request in [SiteRequest.url("https://www.co.uk/login"), .domain("www.co.uk")] {
            XCTAssertEqual(SiteMatcher.strictMatches([own, other], for: [request]), [own.id], "\(request)")
        }
    }

    /// The request host is normalized twice, so a doubled `www` collapses to
    /// the registrable domain and its siblings match. Pinned as found.
    func testDoubledWWWRequestMatchesTheRegistrableDomain() {
        let sibling = candidate("https://other.example.com")
        XCTAssertEqual(SiteMatcher.strictMatches([sibling], for: [.domain("www.www.example.com")]), [sibling.id])
    }

    // MARK: - Possible tier

    func testPossibleMatchesSiblingSubdomainsOnly() {
        let sibling = candidate("https://tro.sitio.com/login")
        let boundary = candidate("https://otro-sitio.com")
        let otherDomain = candidate("https://tro.otro-sitio.com")
        XCTAssertEqual(SiteMatcher.possibleCandidates([sibling, boundary, otherDomain], for: [.url("https://acs.sitio.com")]).map(\.id), [sibling.id])
    }

    func testPossibleMatchesNormalizeStoredAndRequestedURLs() {
        let one = candidate("HTTPS://one.sitio.com.")
        let two = candidate("https://two.sitio.com/path")
        XCTAssertEqual(SiteMatcher.possibleCandidates([one, two], for: [.url("https://acs.SITIO.com/path")]).count, 2)
    }

    func testPossibleMatchesUseThePublicSuffixList() {
        let sibling = candidate("https://tro.example.co.uk")
        let unrelated = candidate("https://tro.other.co.uk")
        let bareSuffix = candidate("https://tro.co.uk")
        XCTAssertEqual(
            SiteMatcher.possibleCandidates([sibling, unrelated, bareSuffix], for: [.url("https://acs.example.co.uk")]).map(\.id),
            [sibling.id]
        )
    }

    func testPossibleMatchesNeedARequestedDomain() {
        XCTAssertTrue(SiteMatcher.possibleCandidates([candidate("https://a.example.com")], for: [.domain("localhost")]).isEmpty)
    }

    /// The possible tier uses the Public Suffix List's domain without IP
    /// checks, so two IPv4 addresses with the same last two octets are
    /// related. Pinned as found; `SiteHost.isPublishable` rejects both.
    func testPossibleMatchesRelateIPv4AddressesSharingTheLastTwoOctets() {
        let other = candidate("https://10.0.1.1")
        XCTAssertEqual(SiteMatcher.possibleCandidates([other], for: [.url("https://192.168.1.1")]).map(\.id), [other.id])
    }

    // MARK: - Apps and stored App IDs

    func testAppRequestIsNeverMatchedAsAHost() {
        let candidates = [
            candidate("https://mybank.app"),
            candidate("https://login.mybank.app"),
            candidate("A1B2C3D4E5.com.mybank.app"),
        ]
        let request = SiteRequest.app("A1B2C3D4E5.com.mybank.app")

        XCTAssertTrue(SiteMatcher.strictMatches(candidates, for: [request]).isEmpty)
        XCTAssertTrue(SiteMatcher.possibleCandidates(candidates, for: [request]).isEmpty)
    }

    func testAppRequestDoesNotHideADomainInTheSameRequest() {
        let github = candidate("https://github.com")
        XCTAssertEqual(SiteMatcher.strictMatches([github], for: [.app("A1B2C3D4E5.com.github.app"), .domain("github.com")]), [github.id])
    }

    /// Saves from app requests once stored the raw App ID as the entry URL;
    /// such a field must not count as the website it resembles.
    func testStoredAppIDFieldDoesNotMatchTheWebsiteOfTheSameSuffix() {
        let saved = candidate("A1B2C3D4E5.com.mybank.app")
        for request in [SiteRequest.domain("mybank.app"), .url("https://mybank.app/login"), .domain("login.mybank.app")] {
            XCTAssertTrue(SiteMatcher.strictMatches([saved], for: [request]).isEmpty, "\(request)")
            XCTAssertTrue(SiteMatcher.possibleCandidates([saved], for: [request]).isEmpty, "\(request)")
        }
    }

    func testStoredAppIDFieldDoesNotHideOtherWebsiteFields() {
        let entry = candidate("A1B2C3D4E5.com.mybank.app", "https://mybank.app")
        XCTAssertEqual(SiteMatcher.strictMatches([entry], for: [.domain("mybank.app")]), [entry.id])
    }

    func testHostsThatOnlyResembleAnAppIDStillMatch() {
        let candidates = [
            candidate("a1b2c3d4e5.mybank.app"),
            candidate("https://A1B2C3D4E5.mybank.app"),
            candidate("A1B2C3D4E5.mybank.app/login"),
        ]
        XCTAssertEqual(SiteMatcher.strictMatches(candidates, for: [.domain("mybank.app")]).count, 3)
    }

    func testIsStoredAppIdentifier() {
        XCTAssertTrue(SiteMatcher.isStoredAppIdentifier("A1B2C3D4E5.com.mybank.app"))
        XCTAssertTrue(SiteMatcher.isStoredAppIdentifier(" ABCDE12345.com.example.my-app "))
        XCTAssertFalse(SiteMatcher.isStoredAppIdentifier("a1b2c3d4e5.com.mybank.app"))
        XCTAssertFalse(SiteMatcher.isStoredAppIdentifier("https://A1B2C3D4E5.com.mybank.app"))
        XCTAssertFalse(SiteMatcher.isStoredAppIdentifier("A1B2C3D4E5.com.mybank.app/login"))
        XCTAssertFalse(SiteMatcher.isStoredAppIdentifier("A1B2C3D4E.com.mybank.app"))
        XCTAssertFalse(SiteMatcher.isStoredAppIdentifier("A1B2C3D4E5"))
        XCTAssertFalse(SiteMatcher.isStoredAppIdentifier("mybank.app"))
        XCTAssertFalse(SiteMatcher.isStoredAppIdentifier(""))
    }

    // MARK: - Helpers

    private func candidate(_ urls: String...) -> SiteCandidate {
        SiteCandidate(id: UUID(), urls: urls)
    }
}
