import XCTest
@testable import SiteMatching

/// Tiers T1–T5 and stored-URL rules S1–S2.
final class SiteMatcherTests: XCTestCase {

    // MARK: - Exact

    func testT1ExactMatchesTheFirstWebHostInEveryURLField() {
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

    func testT1ExactIsEmptyWithoutAWebHost() {
        let entry = candidate("https://mybank.app")
        XCTAssertEqual(
            SiteMatcher.interactiveMatches([entry], for: [.app("A1B2C3D4E5.com.mybank.app")]),
            SiteMatcher.InteractiveMatches(exact: [], possible: [])
        )
        XCTAssertEqual(SiteMatcher.interactiveMatches([entry], for: []).possible, [])
    }

    // MARK: - Strict

    func testT2StrictMatchesExactHostAndDottedSubdomains() {
        let exact = candidate("https://paypal.com/signin")
        let login = candidate("https://login.paypal.com")
        let gist = candidate("https://example.org", "https://gist.paypal.com")

        XCTAssertEqual(SiteMatcher.strictMatches([exact, login, gist], for: [.domain("paypal.com")]), [exact.id, login.id, gist.id])
    }

    func testT2StrictRejectsSubstringsPathsAndParents() {
        let cases: [(stored: String, request: SiteRequest)] = [
            ("https://mybank.com/login", .domain("bank.com")),
            ("https://paypal.com", .domain("pal.com")),
            ("https://evil.example/bank.com/login", .domain("bank.com")),
            ("https://google.com", .url("https://accounts.google.com/signin")),
            ("https://github.com", .domain("gitlab.com")),
            ("https://bucket.s3.amazonaws.com", .domain("amazonaws.com")),
        ]
        for testCase in cases {
            XCTAssertTrue(
                SiteMatcher.strictMatches([candidate(testCase.stored)], for: [testCase.request]).isEmpty,
                "\(testCase.stored) for \(testCase.request)"
            )
        }
    }

    func testT2StrictMatchesAcrossSchemesPortsAndCase() {
        let settings = candidate("https://GitHub.Com/settings")
        for request in [SiteRequest.url("https://github.com/login"), .url("http://github.com:8080"), .domain("GITHUB.COM.")] {
            XCTAssertEqual(SiteMatcher.strictMatches([settings], for: [request]), [settings.id], "\(request)")
        }
    }

    func testT2StrictMatchesSeveralCandidatesInCandidateOrder() {
        let work = candidate("https://github.com/work")
        let personal = candidate("https://github.com/personal")
        let other = candidate("https://other.com", "")
        XCTAssertEqual(SiteMatcher.strictMatches([work, personal, other], for: [.domain("github.com")]), [work.id, personal.id])
        XCTAssertTrue(SiteMatcher.strictMatches([candidate("https://a.com")], for: []).isEmpty)
    }

    /// Reading a `www.co.uk` request as `co.uk` would make every entry under
    /// that public suffix a strict match.
    func testT2WWWAsRegistrableLabelDoesNotMatchAcrossItsPublicSuffix() {
        let own = candidate("https://www.co.uk/login")
        let other = candidate("https://bank.co.uk")
        for request in [SiteRequest.url("https://www.co.uk/login"), .domain("www.co.uk")] {
            XCTAssertEqual(SiteMatcher.strictMatches([own, other], for: [request]), [own.id], "\(request)")
        }
    }

    // MARK: - Hosts without a registrable domain

    func testT3BarePublicSuffixRequestMatchesOnlyItself() {
        let own = candidate("https://github.io")
        let site = candidate("https://alice.github.io")
        let bank = candidate("https://bank.co.uk")
        for request in [SiteRequest.domain("github.io"), .domain("co.uk")] {
            XCTAssertEqual(
                SiteMatcher.strictMatches([own, site, bank], for: [request]),
                request == .domain("github.io") ? [own.id] : [],
                "\(request)"
            )
            XCTAssertTrue(SiteMatcher.possibleCandidates([site, bank], for: [request]).isEmpty, "\(request)")
        }
    }

    func testT3IPAddressesMatchOnlyExactly() {
        let router = candidate("https://192.168.1.1/admin")
        let other = candidate("https://10.0.1.1")
        let named = candidate("http://foo.192.168.1.1")
        let request = SiteRequest.url("https://192.168.1.1/login")

        XCTAssertEqual(SiteMatcher.strictMatches([router, other, named], for: [request]), [router.id])
        XCTAssertTrue(SiteMatcher.possibleCandidates([other, named], for: [request]).isEmpty)
        XCTAssertEqual(SiteMatcher.interactiveMatches([other, named], for: [request]), .init(exact: [], possible: []))
        XCTAssertEqual(SiteMatcher.interactiveMatches([router, other], for: [request]).exact, [router.id])
    }

    func testT3SingleLabelHostsMatchOnlyThemselves() {
        let local = candidate("http://localhost:8080")
        let app = candidate("http://app.localhost:3000")
        let request = SiteRequest.url("http://localhost:3000")
        XCTAssertEqual(SiteMatcher.strictMatches([local, app], for: [request]), [local.id])
        XCTAssertTrue(SiteMatcher.possibleCandidates([local, app], for: [request]).isEmpty)
    }

    // MARK: - Possible

    func testT4PossibleMatchesStoredHostsOnARequestedRegistrableDomain() {
        let sibling = candidate("https://tro.sitio.com/login")
        let parent = candidate("https://sitio.com")
        let boundary = candidate("https://otro-sitio.com")
        let otherDomain = candidate("https://tro.otro-sitio.com")
        XCTAssertEqual(
            SiteMatcher.possibleCandidates([sibling, parent, boundary, otherDomain], for: [.url("https://acs.sitio.com")]).map(\.id),
            [sibling.id, parent.id]
        )
    }

    func testT4PossibleMatchesNormalizeStoredAndRequestedURLs() {
        let one = candidate("HTTPS://one.sitio.com.")
        let two = candidate("https://two.sitio.com/path")
        XCTAssertEqual(SiteMatcher.possibleCandidates([one, two], for: [.url("https://acs.SITIO.com/path")]).count, 2)
    }

    func testT4PossibleMatchesUseThePublicSuffixList() {
        let sibling = candidate("https://tro.example.co.uk")
        let unrelated = candidate("https://tro.other.co.uk")
        let bareSuffix = candidate("https://co.uk")
        XCTAssertEqual(
            SiteMatcher.possibleCandidates([sibling, unrelated, bareSuffix], for: [.url("https://acs.example.co.uk")]).map(\.id),
            [sibling.id]
        )
    }

    func testT4PossibleAppearsOnlyWithoutAnExactMatch() {
        let sibling = candidate("https://other.example.com")
        let exact = candidate("https://login.example.com")
        let request = SiteRequest.url("https://login.example.com")
        XCTAssertEqual(SiteMatcher.interactiveMatches([sibling, exact], for: [request]), .init(exact: [exact.id], possible: []))
        XCTAssertEqual(SiteMatcher.interactiveMatches([sibling], for: [request]), .init(exact: [], possible: [sibling.id]))
    }

    // MARK: - Order

    func testT5PossibleMatchesAreDeduplicatedAndPrioritized() {
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

    func testT5PrioritizesExactHostThenSubdomainInRequestOrder() {
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

    // MARK: - One normalization (H7)

    /// A request host is normalized once, as stored hosts are, so a doubled
    /// `www` is a subdomain like any other.
    func testH7DoubledWWWRequestMatchesOnlyItsOwnHost() {
        let own = candidate("https://www.www.example.com")
        let child = candidate("https://login.www.example.com")
        let sibling = candidate("https://other.example.com")
        let parent = candidate("https://example.com")
        let request = SiteRequest.domain("www.www.example.com")

        XCTAssertEqual(SiteMatcher.firstWebHost(for: [request])?.name, "www.example.com")
        XCTAssertEqual(SiteMatcher.strictMatches([own, child, sibling, parent], for: [request]), [own.id, child.id])
        XCTAssertEqual(SiteMatcher.interactiveMatches([own, child, sibling, parent], for: [request]).exact, [own.id])
        XCTAssertEqual(
            SiteMatcher.interactiveMatches([child, sibling, parent], for: [request]).possible,
            [child.id, sibling.id, parent.id]
        )
    }

    // MARK: - Requests

    func testR1RequestWithoutAHostMatchesNothingAndHidesNothing() {
        let github = candidate("https://github.com")
        let garbage = candidate("not a url")
        XCTAssertTrue(SiteMatcher.strictMatches([github, garbage], for: [.url("not a url")]).isEmpty)
        XCTAssertNil(SiteMatcher.firstWebHost(for: [.domain(""), .url("")]))
        XCTAssertEqual(SiteMatcher.strictMatches([github], for: [.url("not a url"), .domain("github.com")]), [github.id])
        XCTAssertEqual(SiteMatcher.firstWebHost(for: [.domain(""), .url("https://WWW.Example.com/a")])?.name, "example.com")
    }

    func testR2AppRequestIsNeverMatchedAsAHost() {
        let candidates = [
            candidate("https://mybank.app"),
            candidate("https://login.mybank.app"),
            candidate("A1B2C3D4E5.com.mybank.app"),
        ]
        let request = SiteRequest.app("A1B2C3D4E5.com.mybank.app")

        XCTAssertTrue(SiteMatcher.strictMatches(candidates, for: [request]).isEmpty)
        XCTAssertTrue(SiteMatcher.possibleCandidates(candidates, for: [request]).isEmpty)
        XCTAssertNil(SiteMatcher.firstWebHost(for: [request]))
    }

    func testR2AppRequestDoesNotHideADomainInTheSameRequest() {
        let github = candidate("https://github.com")
        XCTAssertEqual(SiteMatcher.strictMatches([github], for: [.app("A1B2C3D4E5.com.github.app"), .domain("github.com")]), [github.id])
        XCTAssertEqual(SiteMatcher.firstWebHost(for: [.app("A1B2C3D4E5.com.example.app"), .domain("github.com")])?.name, "github.com")
    }

    // MARK: - Stored URLs

    func testS1EveryURLFieldIsMatchedAndEmptyFieldsAreSkipped() {
        let entry = candidate("", "https://unrelated.example", "   ", "https://login.example.com")
        XCTAssertEqual(SiteMatcher.hosts(of: entry).map(\.name), ["unrelated.example", "login.example.com"])
        XCTAssertEqual(SiteMatcher.strictMatches([entry], for: [.domain("example.com")]), [entry.id])
    }

    /// Saves from app requests once stored the raw App ID as the entry URL;
    /// such a field must not count as the website it resembles.
    func testS2StoredAppIDFieldDoesNotMatchTheWebsiteOfTheSameSuffix() {
        let saved = candidate("A1B2C3D4E5.com.mybank.app")
        for request in [SiteRequest.domain("mybank.app"), .url("https://mybank.app/login"), .domain("login.mybank.app"), .domain("com.mybank.app")] {
            XCTAssertTrue(SiteMatcher.strictMatches([saved], for: [request]).isEmpty, "\(request)")
            XCTAssertTrue(SiteMatcher.possibleCandidates([saved], for: [request]).isEmpty, "\(request)")
        }
    }

    func testS2StoredAppIDFieldDoesNotHideOtherWebsiteFields() {
        let entry = candidate("A1B2C3D4E5.com.mybank.app", "https://mybank.app")
        XCTAssertEqual(SiteMatcher.strictMatches([entry], for: [.domain("mybank.app")]), [entry.id])
    }

    func testS2HostsThatOnlyResembleAnAppIDStillMatch() {
        let candidates = [
            candidate("a1b2c3d4e5.mybank.app"),
            candidate("https://A1B2C3D4E5.mybank.app"),
            candidate("A1B2C3D4E5.mybank.app/login"),
        ]
        XCTAssertEqual(SiteMatcher.strictMatches(candidates, for: [.domain("mybank.app")]).count, 3)
    }

    func testS2IsStoredAppIdentifier() {
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
