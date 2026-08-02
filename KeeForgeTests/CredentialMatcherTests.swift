import AuthenticationServices
import XCTest
@testable import KeeForge

final class CredentialMatcherTests: XCTestCase {

    // MARK: - hostFromURLString

    func testHostFromFullURL() {
        XCTAssertEqual(CredentialMatcher.hostFromURLString("https://github.com/login"), "github.com")
    }

    func testHostFromURLWithPort() {
        XCTAssertEqual(CredentialMatcher.hostFromURLString("https://example.com:8443/path"), "example.com")
    }

    func testHostFromBareDomain() {
        XCTAssertEqual(CredentialMatcher.hostFromURLString("example.com"), "example.com")
    }

    func testHostFromSubdomain() {
        XCTAssertEqual(CredentialMatcher.hostFromURLString("https://accounts.google.com"), "accounts.google.com")
    }

    func testHostFromEmptyString() {
        // Empty string may or may not parse; just ensure no crash
        _ = CredentialMatcher.hostFromURLString("")
    }

    func testHostFromHTTPURL() {
        XCTAssertEqual(CredentialMatcher.hostFromURLString("http://example.org/page"), "example.org")
    }

    // MARK: - searchTerm

    func testSearchTermDomainType() {
        let id = ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)
        XCTAssertEqual(CredentialMatcher.searchTerm(for: id), "github.com")
    }

    func testSearchTermURLType() {
        let id = ASCredentialServiceIdentifier(identifier: "https://github.com/login", type: .URL)
        XCTAssertEqual(CredentialMatcher.searchTerm(for: id), "github.com")
    }

    // MARK: - matchedEntries

    func testExactDomainMatch() {
        let entries = [makeEntry(title: "GitHub", url: "https://github.com/login", username: "user", password: "pass")]
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 1)
    }

    func testSubdomainMatch() {
        let entries = [makeEntry(title: "Google", url: "https://google.com", username: "user", password: "pass")]
        let ids = [ASCredentialServiceIdentifier(identifier: "https://accounts.google.com/signin", type: .URL)]
        // The search term is "accounts.google.com". Entry host is "google.com".
        // Entry host doesn't have suffix ".accounts.google.com", so host match fails.
        // But entryURL contains "google.com" which contains... let's check: term is "accounts.google.com", entryURL is "https://google.com"
        // entryURL.contains("accounts.google.com") = false. entryTitle.contains("accounts.google.com") = false.
        // So this won't match with current logic. Let me re-read the matching logic...
        // The logic checks if entryHost hasSuffix ".\(term)" — so entry "google.com" hasSuffix ".accounts.google.com"? No.
        // Actually the subdomain matching goes the OTHER way: if the ENTRY has a subdomain of the search term.
        // e.g., entry "accounts.google.com" matches search "google.com" because entryHost.hasSuffix(".google.com")
        // So let's test that direction instead.
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 0) // google.com entry does NOT match accounts.google.com search
    }

    func testEntrySubdomainMatchesParentDomainSearch() {
        // Entry with subdomain URL matches when searching for parent domain
        let entries = [makeEntry(title: "Google Accounts", url: "https://accounts.google.com/signin", username: "user", password: "pass")]
        let ids = [ASCredentialServiceIdentifier(identifier: "google.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 1)
    }

    func testURLTypeIdentifier() {
        let entries = [makeEntry(title: "GH", url: "https://github.com/settings", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "https://github.com/login", type: .URL)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 1)
    }

    func testNoMatches() {
        let entries = [makeEntry(title: "GitHub", url: "https://github.com", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "gitlab.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertTrue(matches.isEmpty)
    }

    func testMultipleMatches() {
        let entries = [
            makeEntry(title: "GH Work", url: "https://github.com/work", username: "work", password: "p1"),
            makeEntry(title: "GH Personal", url: "https://github.com/personal", username: "me", password: "p2"),
            makeEntry(title: "Other", url: "https://other.com", username: "x", password: "p3"),
        ]
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 2)
    }

    func testEmptyURL() {
        let entries = [makeEntry(title: "github.com", url: "", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        // Title contains "github.com" so it matches via title fallback
        XCTAssertEqual(matches.count, 1)
    }

    func testEmptyTitle() {
        let entries = [makeEntry(title: "", url: "https://github.com", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 1)
    }

    func testEmptyIdentifiersReturnsEmpty() {
        let entries = [
            makeEntry(title: "A", url: "https://a.com", username: "u", password: "p"),
            makeEntry(title: "B", url: "https://b.com", username: "u", password: "p"),
        ]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: [])
        XCTAssertTrue(matches.isEmpty)
    }

    func testCaseInsensitiveMatch() {
        let entries = [makeEntry(title: "GitHub", url: "https://GitHub.Com/login", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "GITHUB.COM", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 1)
    }

    func testExpiredEntryDoesNotMatchAutomatically() {
        let expiredEntry = KPEntry(
            title: "GitHub",
            username: "user",
            password: EncryptedValue(sealedData: Data([0]), hasValue: true),
            url: "https://github.com",
            expires: true,
            expiryTime: .distantPast
        )
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]

        XCTAssertTrue(CredentialMatcher.matchedEntries(from: [expiredEntry], for: ids).isEmpty)
    }

    // MARK: - Strict vs fuzzy tiering

    func testStrictDoesNotMatchHostSubstring() {
        // Requesting bank.com must NOT surface a stored mybank.com entry as a
        // strict (auto-fillable) match, even though "mybank.com" contains "bank.com".
        let entries = [makeEntry(title: "My Bank", url: "https://mybank.com/login", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "bank.com", type: .domain)]
        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: entries, for: ids).isEmpty)
        // The fuzzy tier may still surface it for an interactive picker.
        XCTAssertEqual(CredentialMatcher.matchedEntries(from: entries, for: ids).count, 1)
    }

    func testStrictDoesNotMatchPartialLabelSubstring() {
        // Requesting pal.com must not strictly match a stored paypal.com entry.
        let entries = [makeEntry(title: "PayPal", url: "https://paypal.com", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "pal.com", type: .domain)]
        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: entries, for: ids).isEmpty)
    }

    func testStrictMatchesExactHost() {
        let entries = [makeEntry(title: "PayPal", url: "https://paypal.com/signin", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "paypal.com", type: .domain)]
        XCTAssertEqual(CredentialMatcher.strictMatchedEntries(from: entries, for: ids).count, 1)
    }

    func testStrictMatchesDottedSubdomain() {
        let entries = [makeEntry(title: "PayPal", url: "https://login.paypal.com", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "paypal.com", type: .domain)]
        XCTAssertEqual(CredentialMatcher.strictMatchedEntries(from: entries, for: ids).count, 1)
    }

    func testOrderedStrictMatchesPreferExactHostBeforeChildSubdomain() {
        let child = makeEntry(title: "Child", url: "https://login.vt.example.com", username: "u", password: "p")
        let exact = makeEntry(title: "Exact", url: "https://vt.example.com", username: "u", password: "p")
        let ids = [ASCredentialServiceIdentifier(identifier: "vt.example.com", type: .domain)]

        let matches = CredentialMatcher.orderedStrictMatchedEntries(from: [child, exact], for: ids)

        XCTAssertEqual(matches.map(\.title), ["Exact", "Child"])
    }

    func testStrictDoesNotMatchTermInURLPath() {
        // A term appearing in the path of an unrelated host must not strictly match.
        let entries = [makeEntry(title: "Evil", url: "https://evil.example/bank.com/login", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "bank.com", type: .domain)]
        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: entries, for: ids).isEmpty)
        XCTAssertEqual(CredentialMatcher.matchedEntries(from: entries, for: ids).count, 1)
    }

    func testStrictDoesNotMatchTitleSubstring() {
        // Title-only signal is too weak for auto-fill; only the picker may use it.
        let entries = [makeEntry(title: "github.com backup codes", url: "", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]
        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: entries, for: ids).isEmpty)
        XCTAssertEqual(CredentialMatcher.matchedEntries(from: entries, for: ids).count, 1)
    }

    func testStrictMatchesAdditionalURLHost() {
        let entries = [makeEntry(title: "GitHub", url: "https://example.org", username: "u", password: "p",
                                 customFields: ["KP2A_URL_1": "https://gist.github.com"])]
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]
        XCTAssertEqual(CredentialMatcher.strictMatchedEntries(from: entries, for: ids).count, 1)
    }

    func testPossibleMatchesSiblingSubdomainOnly() {
        let entries = [
            makeEntry(title: "Sibling", url: "https://tro.sitio.com/login", username: "u", password: "p"),
            makeEntry(title: "Boundary", url: "https://otro-sitio.com", username: "u", password: "p")
        ]
        let ids = [ASCredentialServiceIdentifier(identifier: "https://acs.sitio.com", type: .URL)]
        let matches = CredentialMatcher.possibleMatchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.map(\.title), ["Sibling"])
    }

    func testPossibleMatchesSupportMultipleEntriesAndURLNormalization() {
        let entries = [
            makeEntry(title: "One", url: "HTTPS://one.sitio.com.", username: "u", password: "p"),
            makeEntry(title: "Two", url: "https://two.sitio.com/path", username: "u", password: "p")
        ]
        let ids = [ASCredentialServiceIdentifier(identifier: "https://acs.SITIO.com/path", type: .URL)]
        XCTAssertEqual(CredentialMatcher.possibleMatchedEntries(from: entries, for: ids).count, 2)
    }

    func testPossibleMatchesDoNotSuggestRegistrableDomainBoundary() {
        let entries = [makeEntry(title: "Other", url: "https://tro.otro-sitio.com", username: "u", password: "p")]
        let ids = [ASCredentialServiceIdentifier(identifier: "acs.sitio.com", type: .domain)]
        XCTAssertTrue(CredentialMatcher.possibleMatchedEntries(from: entries, for: ids).isEmpty)
    }

    func testPossibleMatchesUsePublicSuffixListForCoUK() {
        let entries = [
            makeEntry(title: "Sibling", url: "https://tro.example.co.uk", username: "u", password: "p"),
            makeEntry(title: "Unrelated", url: "https://tro.other.co.uk", username: "u", password: "p"),
            makeEntry(title: "BareSuffix", url: "https://tro.co.uk", username: "u", password: "p")
        ]
        let ids = [ASCredentialServiceIdentifier(identifier: "https://acs.example.co.uk", type: .URL)]
        XCTAssertEqual(
            CredentialMatcher.possibleMatchedEntries(from: entries, for: ids).map(\.title),
            ["Sibling"]
        )
    }

    func testStrictSkipsExpiredEntries() {
        let expiredEntry = KPEntry(
            title: "GitHub",
            username: "user",
            password: EncryptedValue(sealedData: Data([0]), hasValue: true),
            url: "https://github.com",
            expires: true,
            expiryTime: .distantPast
        )
        let ids = [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]
        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: [expiredEntry], for: ids).isEmpty)
    }

    func testStrictIsSubsetOfFuzzy() {
        let entries = [
            makeEntry(title: "PayPal", url: "https://paypal.com", username: "a", password: "p"),
            makeEntry(title: "My Bank", url: "https://mybank.com", username: "b", password: "p"),
            makeEntry(title: "paypal.com note", url: "", username: "c", password: "p"),
        ]
        let ids = [ASCredentialServiceIdentifier(identifier: "paypal.com", type: .domain)]
        let strict = CredentialMatcher.strictMatchedEntries(from: entries, for: ids)
        let fuzzy = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(strict.count, 1)
        XCTAssertEqual(strict.first?.username, "a")
        XCTAssertEqual(fuzzy.count, 2)
        for entry in strict {
            XCTAssertTrue(fuzzy.contains { $0.id == entry.id })
        }
    }

    // MARK: - Additional URL Matching

    func testMatchesOnAdditionalURL() {
        let entries = [makeEntry(title: "GitHub", url: "https://github.com", username: "u", password: "p",
                                 customFields: ["KP2A_URL_1": "https://gist.github.com"])]
        let ids = [ASCredentialServiceIdentifier(identifier: "gist.github.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 1)
    }

    func testNoMatchWhenAdditionalURLDoesNotMatch() {
        let entries = [makeEntry(title: "GitHub", url: "https://github.com", username: "u", password: "p",
                                 customFields: ["KP2A_URL_1": "https://gist.github.com"])]
        let ids = [ASCredentialServiceIdentifier(identifier: "gitlab.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertTrue(matches.isEmpty)
    }

    func testMatchesOnSecondAdditionalURL() {
        let entries = [makeEntry(title: "Work", url: "https://example.com", username: "u", password: "p",
                                 customFields: ["KP2A_URL_1": "https://intranet.example.com",
                                                "KP2A_URL_2": "https://vpn.example.com"])]
        let ids = [ASCredentialServiceIdentifier(identifier: "vpn.example.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertEqual(matches.count, 1)
    }

    func testEmptyKP2AURLsAreFiltered() {
        let entries = [makeEntry(title: "Test", url: "https://example.com", username: "u", password: "p",
                                 customFields: ["KP2A_URL_1": ""])]
        let ids = [ASCredentialServiceIdentifier(identifier: "somethingelse.com", type: .domain)]
        let matches = CredentialMatcher.matchedEntries(from: entries, for: ids)
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - Helpers

    private func makeEntry(title: String, url: String, username: String, password: String, customFields: [String: String] = [:]) -> KPEntry {
        // Use a non-empty sentinel for hasPassword checks; actual decryption is not tested here
        let encrypted: EncryptedValue = password.isEmpty ? .empty : EncryptedValue(sealedData: Data([0]), hasValue: true)
        return KPEntry(title: title, username: username, password: encrypted, url: url, customFields: customFields)
    }
}
