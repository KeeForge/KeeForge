import AuthenticationServices
import SiteMatching
import XCTest
@testable import KeeForge

/// The bridge from service identifiers and entries to `SiteMatching`. The
/// matching rules themselves are tested in `Packages/SiteMatching`.
final class CredentialMatcherTests: XCTestCase {

    // MARK: - Conversions

    func testServiceIdentifiersBecomeRequests() throws {
        XCTAssertEqual(SiteRequest(ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)), .domain("github.com"))
        XCTAssertEqual(SiteRequest(ASCredentialServiceIdentifier(identifier: "https://github.com/login", type: .URL)), .url("https://github.com/login"))
        XCTAssertEqual(SiteRequest(try makeAppIdentifier()), .app("A1B2C3D4E5.com.mybank.app"))
    }

    func testCandidateCarriesEveryURLField() {
        let entry = makeEntry(title: "Work", url: "https://example.com", customFields: [
            "KP2A_URL_1": "https://intranet.example.com",
            "KP2A_URL_2": "A1B2C3D4E5.com.example.app",
        ])
        let candidate = CredentialMatcher.candidate(entry)
        XCTAssertEqual(candidate.id, entry.id)
        XCTAssertEqual(Set(candidate.urls), ["https://example.com", "https://intranet.example.com", "A1B2C3D4E5.com.example.app"])
        XCTAssertEqual(candidate.urls.first, "https://example.com")
    }

    func testWebURLsDropStoredAppIDs() {
        let entry = makeEntry(title: "MyBank", url: "A1B2C3D4E5.com.mybank.app", customFields: ["KP2A_URL_1": "https://mybank.app"])
        XCTAssertEqual(CredentialMatcher.webURLs(of: entry), ["https://mybank.app"])
    }

    func testMatchesMapBackToEntriesInOrder() {
        let parent = makeEntry(title: "Parent", url: "https://cvmd.com.ar")
        let sibling = makeEntry(title: "Sibling", url: "https://other.cvmd.com.ar")
        let exact = makeEntry(title: "Exact", url: "https://vt.cvmd.com.ar")
        let identifiers = ["vt.cvmd.com.ar", "cvmd.com.ar"].map { ASCredentialServiceIdentifier(identifier: $0, type: .domain) }

        XCTAssertEqual(CredentialMatcher.interactiveMatches(from: [parent, sibling, exact], for: identifiers).exact.map(\.id), [exact.id])
        let fallback = CredentialMatcher.interactiveMatches(from: [sibling, parent], for: identifiers)
        XCTAssertTrue(fallback.exact.isEmpty)
        XCTAssertEqual(fallback.possible.map(\.id), [parent.id, sibling.id])
        XCTAssertEqual(CredentialMatcher.strictMatchedEntries(from: [exact, parent, sibling], for: identifiers).map(\.id), [exact.id, parent.id, sibling.id])
        XCTAssertTrue(CredentialMatcher.hasWebHost(identifiers))
    }

    func testAppIdentifierHasNoWebHost() throws {
        let entries = [makeEntry(title: "Website", url: "https://mybank.app")]
        let app = try makeAppIdentifier()
        XCTAssertFalse(CredentialMatcher.hasWebHost([app]))
        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: entries, for: [app]).isEmpty)
        XCTAssertTrue(CredentialMatcher.interactiveMatches(from: entries, for: [app]).possible.isEmpty)
    }

    func testAppSaveDraftDoesNotStrictlyMatchWebsiteOfSameSuffix() throws {
        let draft = AutoFillSaveCoordinator.initialDraft(
            for: try makeAppIdentifier(),
            username: "alex",
            password: "secret"
        )
        let saved = makeEntry(title: draft.title, url: draft.url)
        let website = [ASCredentialServiceIdentifier(identifier: "mybank.app", type: .domain)]

        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: [saved], for: website).isEmpty)
        XCTAssertTrue(CredentialMatcher.interactiveMatches(from: [saved], for: website).possible.isEmpty)
    }

    // MARK: - Expiry

    func testExpiredEntriesNeverMatch() {
        let expired = makeEntry(title: "Expired", url: "https://vt.example.com", expired: true)
        let expiredSibling = makeEntry(title: "Expired sibling", url: "https://other.example.com", expired: true)
        let live = makeEntry(title: "Live", url: "https://mail.example.com")
        let request = [ASCredentialServiceIdentifier(identifier: "vt.example.com", type: .domain)]

        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: [expired], for: request).isEmpty)
        let matches = CredentialMatcher.interactiveMatches(from: [expired, expiredSibling, live], for: request)
        XCTAssertTrue(matches.exact.isEmpty, "An expired exact match does not hide the fallback")
        XCTAssertEqual(matches.possible.map(\.id), [live.id])
    }

    #if os(macOS)
    func testExpandedSearchOffersHostlessEntriesWithoutRepeatingPossibleMatches() {
        let sibling = makeEntry(title: "Sibling", url: "https://other.cvmd.com.ar")
        let hostless = makeEntry(title: "No URL", url: "")
        let corpus = [sibling, hostless]
        let initial = AutoFillSearchResults(entries: [], searchEntries: corpus, possibleEntries: [sibling], query: "", hasExpandedSearch: false)
        XCTAssertTrue(initial.entries.isEmpty)
        XCTAssertEqual(initial.possibleEntries.map(\.id), [sibling.id])
        XCTAssertTrue(initial.canShowAllEntries)

        let expanded = AutoFillSearchResults(entries: [], searchEntries: corpus, possibleEntries: [sibling], query: "", hasExpandedSearch: true)
        XCTAssertEqual(expanded.entries.map(\.id), corpus.map(\.id))
        XCTAssertTrue(expanded.possibleEntries.isEmpty)
        XCTAssertFalse(expanded.canShowAllEntries)

        let searched = AutoFillSearchResults(entries: [], searchEntries: corpus, possibleEntries: [sibling], query: "No URL", hasExpandedSearch: true)
        XCTAssertEqual(searched.entries.map(\.id), [hostless.id])
        XCTAssertTrue(searched.possibleEntries.isEmpty)
        XCTAssertTrue(searched.canShowAllEntries)
    }

    func testNoMatchesStillOffersExpansionAndSearchIncludesAdditionalURLs() {
        let entry = makeEntry(title: "Other", url: "https://unrelated.example",
                              customFields: ["KP2A_URL_1": "https://vt.cvmd.com.ar/login"])
        let empty = AutoFillSearchResults(entries: [], searchEntries: [entry], possibleEntries: [], query: "", hasExpandedSearch: false)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertTrue(empty.canShowAllEntries)
        let searched = AutoFillSearchResults(entries: [], searchEntries: [entry], possibleEntries: [], query: "vt.cvmd.com.ar", hasExpandedSearch: true)
        XCTAssertEqual(searched.entries.map(\.id), [entry.id])
    }
    #endif

    // MARK: - Helpers

    private func makeAppIdentifier() throws -> ASCredentialServiceIdentifier {
        guard #available(iOS 26.2, macOS 26.2, *) else {
            throw XCTSkip("App service identifiers require iOS 26.2 / macOS 26.2")
        }
        return ASCredentialServiceIdentifier(identifier: "A1B2C3D4E5.com.mybank.app", type: .app, displayName: "MyBank")
    }

    private func makeEntry(title: String, url: String, customFields: [String: String] = [:], expired: Bool = false) -> KPEntry {
        // A non-empty sentinel for hasPassword checks; nothing is decrypted here.
        KPEntry(
            title: title,
            username: "u",
            password: EncryptedValue(sealedData: Data([0]), hasValue: true),
            url: url,
            customFields: customFields,
            expires: expired,
            expiryTime: expired ? .distantPast : nil
        )
    }

    func testListsRequestedSiteIgnoresExpiry() {
        let expired = KPEntry(title: "Old", url: "https://github.com", expires: true, expiryTime: .distantPast)
        let github = [ASCredentialServiceIdentifier(identifier: "https://github.com", type: .URL)]
        XCTAssertTrue(CredentialMatcher.listsRequestedSite(expired, for: github))
        XCTAssertTrue(CredentialMatcher.strictMatchedEntries(from: [expired], for: github).isEmpty)
        XCTAssertFalse(CredentialMatcher.listsRequestedSite(
            expired, for: [ASCredentialServiceIdentifier(identifier: "gitlab.com", type: .domain)]
        ))
    }
}
