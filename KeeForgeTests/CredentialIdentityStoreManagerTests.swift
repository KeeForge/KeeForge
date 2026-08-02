import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class CredentialIdentityStoreManagerTests: XCTestCase {
    /// Owning-database id passed to the identity builders; every produced
    /// identity's record identifier is tagged with it (slice 02).
    private let someDatabaseID = UUID()
    private let sessionKey = SymmetricKey(size: .bits256)

    private static let testPEM = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----"

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    // MARK: - domainFromURLString

    func testDomainFromFullHTTPSURL() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("https://github.com/login"), "github.com")
    }

    func testDomainFromHTTPURL() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("http://example.org/path"), "example.org")
    }

    func testDomainFromURLWithPort() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("https://example.com:8443/path"), "example.com")
    }

    func testDomainFromSubdomainURL() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("https://accounts.google.com/signin"), "google.com")
    }

    func testDomainFromBareDomainPrependsHTTPS() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("example.com"), "example.com")
    }

    func testDomainFromBareDomainWithPath() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("example.com/login"), "example.com")
    }

    func testDomainFromEmptyStringReturnsNil() {
        XCTAssertNil(CredentialIdentityStoreManager.domainFromURLString(""))
    }

    func testDomainFromWhitespaceOnlyReturnsNil() {
        // URL(string:) returns nil for whitespace-only strings
        XCTAssertNil(CredentialIdentityStoreManager.domainFromURLString("   "))
    }

    func testDomainFromURLWithQueryAndFragment() {
        XCTAssertEqual(
            CredentialIdentityStoreManager.domainFromURLString("https://example.com/path?q=1#section"),
            "example.com"
        )
    }

    // MARK: - passwordIdentities: basic identity creation

    func testIdentityWithUsernameAndURL() {
        let entry = makeEntry(title: "GitHub", url: "https://github.com", username: "octocat", hasPassword: true)
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.user, "octocat")
        XCTAssertEqual(identities.first?.serviceIdentifier.identifier, "github.com")
        XCTAssertEqual(identities.first?.serviceIdentifier.type, .domain)
    }

    func testIdentityRecordIdentifierIsTaggedDatabaseAndEntryEncoding() {
        let id = UUID()
        let entry = makeEntry(id: id, title: "Test", url: "https://example.com", username: "user", hasPassword: true)
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(
            identities.first?.recordIdentifier,
            CredentialRecordIdentifier(databaseID: someDatabaseID, entryID: id).encoded
        )
    }

    func testRecordIdentifierHelperReadsPublishedIdentitySafely() {
        let entry = makeEntry(title: "Test", url: "https://example.com", username: "user", hasPassword: true)
        let identity = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)[0]

        XCTAssertEqual(
            CredentialIdentityStoreManager.recordIdentifier(of: identity),
            identity.recordIdentifier
        )
    }

    func testRecordIdentifierHelperSkipsRuntimeObjectsWithoutAccessor() {
        let identity = IdentityWithoutRecordIdentifier()

        XCTAssertNil(CredentialIdentityStoreManager.recordIdentifier(of: identity))
    }

    // MARK: - passwordIdentities: username fallback to title

    func testIdentityFallsBackToTitleWhenUsernameEmpty() {
        let entry = makeEntry(title: "Work Account", url: "https://example.com", username: "", hasPassword: true)
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.user, "Work Account")
    }

    // MARK: - passwordIdentities: entries that should be skipped

    func testIdentityEmptyWhenNoUsernameAndNoTitle() {
        let entry = makeEntry(title: "", url: "https://example.com", username: "", hasPassword: true)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID).isEmpty)
    }

    func testIdentityEmptyWhenNoPassword() {
        let entry = makeEntry(title: "Test", url: "https://example.com", username: "user", hasPassword: false)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID).isEmpty)
    }

    func testIdentityEmptyWhenURLEmpty() {
        let entry = makeEntry(title: "No URL", url: "", username: "user", hasPassword: true)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID).isEmpty)
    }

    func testIdentityEmptyWhenURLWhitespace() {
        let entry = makeEntry(title: "Bad URL", url: "   ", username: "user", hasPassword: true)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID).isEmpty)
    }

    // MARK: - passwordIdentities: multiple URLs (additionalURLs via KP2A_URL_*)

    func testMultipleIdentitiesForMultipleURLs() {
        let entry = makeEntry(
            title: "Multi",
            url: "https://github.com",
            username: "user",
            hasPassword: true,
            customFields: ["KP2A_URL_1": "https://gitlab.com"]
        )
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)
        let domains = Set(identities.map { $0.serviceIdentifier.identifier })

        XCTAssertEqual(identities.count, 2)
        XCTAssertTrue(domains.contains("github.com"))
        XCTAssertTrue(domains.contains("gitlab.com"))
    }

    func testFallsBackToAdditionalURLWhenPrimaryInvalid() {
        let entry = makeEntry(
            title: "Fallback",
            url: "",
            username: "user",
            hasPassword: true,
            customFields: ["KP2A_URL_1": "https://backup.example.com"]
        )
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.serviceIdentifier.identifier, "example.com")
    }

    func testEmptyWhenAllURLsInvalid() {
        let entry = makeEntry(
            title: "No Valid URLs",
            url: "",
            username: "user",
            hasPassword: true,
            customFields: ["KP2A_URL_1": "", "KP2A_URL_2": ""]
        )
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID).isEmpty)
    }

    func testAdditionalURLsSkipsEmptyValues() {
        // KP2A_URL_1 is empty, KP2A_URL_2 has a valid domain — should use KP2A_URL_2
        let entry = makeEntry(
            title: "Sorted",
            url: "",
            username: "user",
            hasPassword: true,
            customFields: [
                "KP2A_URL_1": "",
                "KP2A_URL_2": "https://second.example.com",
            ]
        )
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.serviceIdentifier.identifier, "example.com")
    }

    // MARK: - passwordIdentities: bare domain URLs

    func testIdentityWithBareDomainURL() {
        let entry = makeEntry(title: "Bare", url: "example.com", username: "user", hasPassword: true)
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.serviceIdentifier.identifier, "example.com")
    }

    // MARK: - passwordIdentities: deduplication

    func testDeduplicatesIdenticalDomains() {
        // Primary and additional URL resolve to same domain
        let entry = makeEntry(
            title: "Dup",
            url: "https://example.com",
            username: "user",
            hasPassword: true,
            customFields: ["KP2A_URL_1": "https://www.example.com"]
        )
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.serviceIdentifier.identifier, "example.com")
    }

    // MARK: - domainFromURLString: www stripping and registered domain

    func testDomainStripsWWWPrefix() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("https://www.facebook.com"), "facebook.com")
    }

    func testDomainStripsWWWFromBareDomain() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("www.facebook.com"), "facebook.com")
    }

    func testDomainExtractsRegisteredDomainFromSubdomain() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("https://login.facebook.com/path"), "facebook.com")
    }

    func testDomainFromBareFacebookDomain() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("facebook.com"), "facebook.com")
    }

    func testDomainReturnsNilForIPv4Address() {
        XCTAssertNil(CredentialIdentityStoreManager.domainFromURLString("https://192.168.1.1/path"))
    }

    func testDomainReturnsNilForLocalhost() {
        XCTAssertNil(CredentialIdentityStoreManager.domainFromURLString("http://localhost:8080"))
    }

    func testDomainHandlesMultiPartTLD() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("https://www.bbc.co.uk"), "bbc.co.uk")
    }

    func testDomainExtractsRegisteredDomainFromMultiPartTLD() {
        XCTAssertEqual(CredentialIdentityStoreManager.domainFromURLString("https://news.bbc.co.uk"), "bbc.co.uk")
    }

    func testDomainReturnsNilForBareMultiPartTLD() {
        // "co.uk" alone is a TLD, not a registrable domain
        XCTAssertNil(CredentialIdentityStoreManager.domainFromURLString("https://co.uk"))
    }

    func testDomainUsesRegistrableDomainForUnlistedCountryCodeSuffix() {
        XCTAssertEqual(
            CredentialIdentityStoreManager.domainFromURLString("https://login.mybank.com.pl"),
            "mybank.com.pl"
        )
    }

    func testDomainKeepsPrivateSuffixTenantBoundary() {
        XCTAssertEqual(
            CredentialIdentityStoreManager.domainFromURLString("https://account.example.github.io"),
            "example.github.io"
        )
    }

    func testDomainReturnsNilForPublicSuffix() {
        XCTAssertNil(CredentialIdentityStoreManager.domainFromURLString("https://github.io"))
    }

    // MARK: - oneTimeCodeIdentity (iOS 18+)

    func testOTCIdentityForEntryWithTOTP() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time code identities require iOS 18 / macOS 15")
        }

        let id = UUID()
        let entry = makeEntry(
            id: id,
            title: "GitHub",
            url: "https://github.com",
            username: "octocat",
            hasPassword: false,
            hasTOTP: true
        )
        let identity = CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry, in: someDatabaseID)

        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.label, "GitHub")
        XCTAssertEqual(identity?.serviceIdentifier.identifier, "github.com")
        XCTAssertEqual(
            identity?.recordIdentifier,
            CredentialRecordIdentifier(databaseID: someDatabaseID, entryID: id).encoded
        )
    }

    func testOTCIdentityUsesUsernameFallbackWhenTitleEmpty() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time code identities require iOS 18 / macOS 15")
        }

        let entry = makeEntry(
            title: "",
            url: "https://example.com",
            username: "user@example.com",
            hasPassword: false,
            hasTOTP: true
        )
        let identity = CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry, in: someDatabaseID)

        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.label, "user@example.com")
    }

    func testOTCIdentityNilWhenNoTOTP() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time code identities require iOS 18 / macOS 15")
        }

        let entry = makeEntry(
            title: "Test",
            url: "https://example.com",
            username: "user",
            hasPassword: true,
            hasTOTP: false
        )
        XCTAssertNil(CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry, in: someDatabaseID))
    }

    func testOTCIdentityNilWhenNoURL() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time code identities require iOS 18 / macOS 15")
        }

        let entry = makeEntry(
            title: "Test",
            url: "",
            username: "user",
            hasPassword: false,
            hasTOTP: true
        )
        XCTAssertNil(CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry, in: someDatabaseID))
    }

    func testOTCIdentityNilWhenNoLabelOrUsername() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time code identities require iOS 18 / macOS 15")
        }

        let entry = makeEntry(
            title: "",
            url: "https://example.com",
            username: "",
            hasPassword: false,
            hasTOTP: true
        )
        XCTAssertNil(CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry, in: someDatabaseID))
    }

    func testOTCIdentityUsesAdditionalURLWhenPrimaryEmpty() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time code identities require iOS 18 / macOS 15")
        }

        let entry = makeEntry(
            title: "Fallback OTC",
            url: "",
            username: "user",
            hasPassword: false,
            hasTOTP: true,
            customFields: ["KP2A_URL_1": "https://backup.example.com"]
        )
        let identity = CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry, in: someDatabaseID)

        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.serviceIdentifier.identifier, "example.com")
    }

    // MARK: - hasTOTP

    func testHasTOTPTrueWhenConfigPresent() {
        let entry = makeEntry(
            title: "TOTP Entry",
            url: "https://example.com",
            username: "user",
            hasPassword: false,
            hasTOTP: true
        )
        XCTAssertTrue(entry.hasTOTP)
    }

    func testHasTOTPFalseWhenNoConfig() {
        let entry = makeEntry(
            title: "No TOTP",
            url: "https://example.com",
            username: "user",
            hasPassword: true,
            hasTOTP: false
        )
        XCTAssertFalse(entry.hasTOTP)
    }

    // MARK: - Entry filtering (TOTP-only entries included)

    func testTOTPOnlyEntryPassesAutoFillFilter() {
        let entry = makeEntry(
            title: "TOTP Only",
            url: "https://example.com",
            username: "user",
            hasPassword: false,
            hasTOTP: true
        )
        // Simulates the filter used in loadEntries
        let filtered = [entry].filter { $0.hasPassword || $0.hasPasskey || $0.hasTOTP }
        XCTAssertEqual(filtered.count, 1)
    }

    func testEntryWithNoCredentialsExcludedFromFilter() {
        let entry = makeEntry(
            title: "Empty",
            url: "https://example.com",
            username: "user",
            hasPassword: false,
            hasTOTP: false
        )
        let filtered = [entry].filter { $0.hasPassword || $0.hasPasskey || $0.hasTOTP }
        XCTAssertTrue(filtered.isEmpty)
    }

    func testExpiredEntryExcludedFromAutomaticAutoFillFilter() {
        let entry = KPEntry(
            title: "Expired",
            username: "user",
            password: EncryptedValue(sealedData: Data([0]), hasValue: true),
            url: "https://example.com",
            expires: true,
            expiryTime: .distantPast
        )

        let filtered = [entry].filter {
            !$0.isExpired() && ($0.hasPassword || $0.hasPasskey || $0.hasTOTP)
        }

        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - CredentialRecordIdentifier: wire format (slice 02)

    func testRecordIdentifierEncodedFormat() {
        let databaseID = UUID()
        let entryID = UUID()
        let identifier = CredentialRecordIdentifier(databaseID: databaseID, entryID: entryID)

        // The literal wire format — changing it must be a conscious act.
        XCTAssertEqual(identifier.encoded, "v2:\(databaseID.uuidString):\(entryID.uuidString)")
    }

    func testRecordIdentifierEncodeParseRoundTrip() {
        let identifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID())

        XCTAssertEqual(CredentialRecordIdentifier.parse(identifier.encoded), .current(identifier))
    }

    func testParseBareEntryUUIDClassifiesAsLegacy() {
        let entryID = UUID()

        XCTAssertEqual(CredentialRecordIdentifier.parse(entryID.uuidString), .legacy(entryID: entryID))
        // UUID(uuidString:) accepts lowercase, so lowercased pre-feature
        // identifiers resolve to the same entry.
        XCTAssertEqual(
            CredentialRecordIdentifier.parse(entryID.uuidString.lowercased()),
            .legacy(entryID: entryID)
        )
    }

    func testParseGarbageIsUnrecognized() {
        XCTAssertEqual(CredentialRecordIdentifier.parse("not-an-identifier"), .unrecognized)
        XCTAssertEqual(CredentialRecordIdentifier.parse(""), .unrecognized)
        XCTAssertEqual(CredentialRecordIdentifier.parse("::"), .unrecognized)
    }

    func testParseWrongVersionIsUnrecognized() {
        let databaseID = UUID().uuidString
        let entryID = UUID().uuidString

        XCTAssertEqual(CredentialRecordIdentifier.parse("v1:\(databaseID):\(entryID)"), .unrecognized)
        XCTAssertEqual(CredentialRecordIdentifier.parse("v3:\(databaseID):\(entryID)"), .unrecognized)
        // The version prefix is case-sensitive.
        XCTAssertEqual(CredentialRecordIdentifier.parse("V2:\(databaseID):\(entryID)"), .unrecognized)
    }

    func testParseTruncatedOrMalformedFieldsIsUnrecognized() {
        let databaseID = UUID().uuidString
        let entryID = UUID().uuidString

        XCTAssertEqual(CredentialRecordIdentifier.parse("v2:\(databaseID)"), .unrecognized)
        XCTAssertEqual(CredentialRecordIdentifier.parse("v2:\(databaseID):\(entryID):extra"), .unrecognized)
        XCTAssertEqual(CredentialRecordIdentifier.parse("v2:junk:\(entryID)"), .unrecognized)
        XCTAssertEqual(CredentialRecordIdentifier.parse("v2:\(databaseID):junk"), .unrecognized)
    }

    func testParseResultConveniences() {
        let identifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID())
        let current = CredentialRecordIdentifier.parse(identifier.encoded)
        XCTAssertEqual(current.entryID, identifier.entryID)
        XCTAssertEqual(current.databaseID, identifier.databaseID)

        let legacyEntryID = UUID()
        let legacy = CredentialRecordIdentifier.parse(legacyEntryID.uuidString)
        XCTAssertEqual(legacy.entryID, legacyEntryID)
        XCTAssertNil(legacy.databaseID, "Legacy identifiers carry no database attribution")

        let unrecognized = CredentialRecordIdentifier.parse("not-an-identifier")
        XCTAssertNil(unrecognized.entryID)
        XCTAssertNil(unrecognized.databaseID)
    }

    // MARK: - Identity tagging (slice 02)

    // Single-identity tagged-encoding equality is pinned by
    // testIdentityRecordIdentifierIsTaggedDatabaseAndEntryEncoding (password),
    // PasskeyTests.testPasskeyIdentityCreatedForPasskeyEntry (passkey), and
    // testOTCIdentityForEntryWithTOTP (one-time code) above.

    func testPasswordIdentitiesCarryTaggedRecordIdentifier() {
        // A multi-URL entry publishes several password identities that all
        // share one tagged record identifier — the property every removal
        // path (which keys on the identifier) relies on.
        let entry = makeEntry(
            title: "Multi",
            url: "https://github.com",
            username: "user",
            hasPassword: true,
            customFields: ["KP2A_URL_1": "https://gitlab.com"]
        )
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry, in: someDatabaseID)

        XCTAssertEqual(identities.count, 2)
        for identity in identities {
            XCTAssertEqual(
                CredentialRecordIdentifier.parse(identity.recordIdentifier ?? ""),
                .current(CredentialRecordIdentifier(databaseID: someDatabaseID, entryID: entry.id))
            )
        }
    }

    // MARK: - Manager operations against the fake store (slice 02)

    func testPopulateReplacesStoreWithTaggedIdentities() async {
        let fake = installFake()
        let databaseID = UUID()
        let first = makeEntry(title: "First", url: "https://first-site.com", username: "first", hasPassword: true)
        let second = makeEntry(title: "Second", url: "https://second-site.com", username: "second", hasPassword: true)

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.populate(with: [first, second], for: databaseID)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["replaceCredentialIdentities"])
        XCTAssertEqual(
            Set(fake.stored.map { CredentialRecordIdentifier.parse($0.recordIdentifier ?? "") }),
            [
                .current(CredentialRecordIdentifier(databaseID: databaseID, entryID: first.id)),
                .current(CredentialRecordIdentifier(databaseID: databaseID, entryID: second.id)),
            ]
        )
    }

    func testPopulateFiltersExpiredEntries() async {
        let fake = installFake()
        let databaseID = UUID()
        let live = makeEntry(title: "Live", url: "https://live-site.com", username: "live", hasPassword: true)
        let expired = makeEntry(
            title: "Expired",
            url: "https://expired-site.com",
            username: "expired",
            hasPassword: true,
            expires: true,
            expiryTime: .distantPast
        )

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.populate(with: [live, expired], for: databaseID)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(
            storedRecordIdentifiers(fake),
            [CredentialRecordIdentifier(databaseID: databaseID, entryID: live.id).encoded]
        )
    }

    func testPopulateWithNoEligibleEntriesEmptiesStore() async {
        let fake = installFake()

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.populate(with: [], for: UUID())
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeAllCredentialIdentities"])
        XCTAssertTrue(fake.stored.isEmpty)
    }

    func testTargetedRemovalRemovesOnlyTargetDatabase() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA1 = makeEntry(title: "A1", url: "https://a1-site.com", username: "a1", hasPassword: true)
        let entryA2 = makeEntry(title: "A2", url: "https://a2-site.com", username: "a2", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        let legacyIdentifier = UUID().uuidString
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entryA1, in: databaseA)
            + CredentialIdentityStoreManager.passwordIdentities(for: entryA2, in: databaseA)
            + CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)
            + [
                seededPasswordIdentity(recordIdentifier: legacyIdentifier),
                seededPasswordIdentity(recordIdentifier: "not-an-identifier", domain: "garbage-site.com"),
            ]

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.removeIdentities(forDatabase: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeCredentialIdentities"])
        XCTAssertEqual(
            Set(storedRecordIdentifiers(fake)),
            [
                CredentialRecordIdentifier(databaseID: databaseB, entryID: entryB.id).encoded,
                legacyIdentifier,
                "not-an-identifier",
            ]
        )
    }

    func testTargetedRemovalIncludingLegacySweepsLegacyIdentifiers() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entryA, in: databaseA)
            + CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)
            + [
                seededPasswordIdentity(recordIdentifier: UUID().uuidString),
                seededPasswordIdentity(recordIdentifier: "not-an-identifier", domain: "garbage-site.com"),
            ]

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.removeIdentities(forDatabase: databaseA, includingLegacyIdentifiers: true)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeCredentialIdentities"])
        XCTAssertEqual(
            Set(storedRecordIdentifiers(fake)),
            [
                CredentialRecordIdentifier(databaseID: databaseB, entryID: entryB.id).encoded,
                "not-an-identifier",
            ]
        )
    }

    func testTargetedRemovalWithNothingMatchingIsNoOp() async {
        let fake = installFake()
        let databaseB = UUID()
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)
        fake.onMutation = { XCTFail("Nothing matches the target database; no removal call expected") }

        CredentialIdentityStoreManager.removeIdentities(forDatabase: UUID())
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(fake.stored.count, 1)
    }

    func testTargetedRemovalNeedsNoEntryData() async {
        // Pins "works with every database locked": the seeded identities are
        // hand-made from identifier strings alone — no KPEntry in sight.
        let fake = installFake()
        let databaseA = UUID()
        let targetIdentifier = CredentialRecordIdentifier(databaseID: databaseA, entryID: UUID()).encoded
        let otherIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        fake.stored = [
            seededPasswordIdentity(recordIdentifier: targetIdentifier),
            seededPasswordIdentity(recordIdentifier: otherIdentifier, domain: "other-site.com"),
        ]

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.removeIdentities(forDatabase: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(storedRecordIdentifiers(fake), [otherIdentifier])
    }

    func testTargetedRemovalSkipsWhenEnumerationUnavailable() async {
        // macOS 14.0–14.3 contract: no enumeration API, so targeted removal
        // logs and removes nothing (callers fall back to clearStore()).
        let fake = installFake()
        fake.enumerationUnavailable = true
        let databaseA = UUID()
        fake.stored = [
            seededPasswordIdentity(
                recordIdentifier: CredentialRecordIdentifier(databaseID: databaseA, entryID: UUID()).encoded
            ),
        ]
        fake.onMutation = { XCTFail("Targeted removal must skip entirely when enumeration is unavailable") }

        CredentialIdentityStoreManager.removeIdentities(forDatabase: databaseA)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(fake.stored.count, 1)
    }

    func testRemoveIdentitiesForEntriesRebuildsTaggedIdentities() async throws {
        let fake = installFake()
        let databaseA = UUID()
        let passwordEntry = makeEntry(title: "PW", url: "https://pw-site.com", username: "pw", hasPassword: true)
        let passkeyEntry = try makePasskeyEntry(domain: "pk-site.com")
        var published: [any ASCredentialIdentity] =
            CredentialIdentityStoreManager.passwordIdentities(for: passwordEntry, in: databaseA)
        published.append(
            try XCTUnwrap(CredentialIdentityStoreManager.passkeyIdentity(for: passkeyEntry, in: databaseA))
        )
        // The same entry published under another database's tag must survive:
        // the rebuilt record identifier includes the owning database.
        let foreignTwinIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: passwordEntry.id).encoded
        fake.stored = published + [
            seededPasswordIdentity(recordIdentifier: foreignTwinIdentifier, domain: "pw-site.com", user: "pw"),
        ]

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.removeIdentities(for: [passwordEntry, passkeyEntry], in: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeCredentialIdentities"])
        XCTAssertEqual(storedRecordIdentifiers(fake), [foreignTwinIdentifier])
    }

    func testClearStoreEmptiesStore() async {
        let fake = installFake()
        fake.stored = [
            seededPasswordIdentity(
                recordIdentifier: CredentialRecordIdentifier(databaseID: someDatabaseID, entryID: UUID()).encoded
            ),
        ]

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.clearStore()
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeAllCredentialIdentities"])
        XCTAssertTrue(fake.stored.isEmpty)
    }

    func testDisabledStoreMakesEveryOperationANoOp() async {
        // System-settings-disabled edge: the OS already cleared the real
        // store, so every manager operation must gate on isEnabled().
        let fake = installFake()
        fake.isEnabledValue = false
        let seededIdentifier = CredentialRecordIdentifier(databaseID: someDatabaseID, entryID: UUID()).encoded
        fake.stored = [seededPasswordIdentity(recordIdentifier: seededIdentifier)]
        fake.onMutation = { XCTFail("A disabled store must never be mutated") }
        let entry = makeEntry(title: "Disabled", url: "https://disabled-site.com", username: "user", hasPassword: true)

        CredentialIdentityStoreManager.populate(with: [entry], for: someDatabaseID)
        CredentialIdentityStoreManager.clearStore()
        CredentialIdentityStoreManager.removeIdentities(for: [entry], in: someDatabaseID)
        CredentialIdentityStoreManager.removeIdentities(forDatabase: someDatabaseID)
        await CredentialIdentityStoreManager.waitForPendingMutations()

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(storedRecordIdentifiers(fake), [seededIdentifier])
    }

    func testRemoveDatabaseObserverReceivesDatabaseID() async {
        _ = installFake() // keep the fire-and-forget Task off the real system store
        let databaseID = UUID()

        let defaultFlag = expectation(description: "Observer fires with the default legacy flag")
        CredentialIdentityStoreManager.removeDatabaseObserver = { observedID, includingLegacyIdentifiers in
            XCTAssertEqual(observedID, databaseID)
            XCTAssertFalse(includingLegacyIdentifiers, "The includingLegacyIdentifiers default is false")
            defaultFlag.fulfill()
        }
        CredentialIdentityStoreManager.removeIdentities(forDatabase: databaseID)
        await fulfillment(of: [defaultFlag], timeout: 1)

        let sweepFlag = expectation(description: "Observer fires with includingLegacyIdentifiers")
        CredentialIdentityStoreManager.removeDatabaseObserver = { observedID, includingLegacyIdentifiers in
            XCTAssertEqual(observedID, databaseID)
            XCTAssertTrue(includingLegacyIdentifiers)
            sweepFlag.fulfill()
        }
        CredentialIdentityStoreManager.removeIdentities(forDatabase: databaseID, includingLegacyIdentifiers: true)
        await fulfillment(of: [sweepFlag], timeout: 1)
    }

    // MARK: - Single-identity removal (slice 03)

    func testRemoveIdentityWithRecordIdentifierRemovesAllTypesForThatIdentifierOnly() async throws {
        let fake = installFake()
        let databaseID = UUID()
        let entryA = try makeFullCredentialEntry(domain: "a-site.com")
        let entryB = try makeFullCredentialEntry(domain: "b-site.com")
        let aIdentifier = CredentialRecordIdentifier(databaseID: databaseID, entryID: entryA.id).encoded
        let bIdentifier = CredentialRecordIdentifier(databaseID: databaseID, entryID: entryB.id).encoded
        let aIdentities = publishedIdentities(for: entryA, in: databaseID)
        let bIdentities = publishedIdentities(for: entryB, in: databaseID)
        // Password + passkey at minimum (+ OTC on iOS 18) — "all types"
        // must be more than a single identity for the test to mean anything.
        XCTAssertGreaterThanOrEqual(aIdentities.count, 2)
        fake.stored = aIdentities + bIdentities

        let mutation = expectMutations(1, on: fake)
        CredentialIdentityStoreManager.removeIdentity(withRecordIdentifier: aIdentifier)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeCredentialIdentities"])
        XCTAssertEqual(fake.stored.count, bIdentities.count)
        XCTAssertEqual(Set(storedRecordIdentifiers(fake)), [bIdentifier])
    }

    func testRemoveIdentityWithRecordIdentifierNoMatchIsNoOp() async {
        let fake = installFake()
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: UUID())
        fake.onMutation = { XCTFail("An unknown identifier must not trigger a removal call") }

        CredentialIdentityStoreManager.removeIdentity(
            withRecordIdentifier: CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        )
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(fake.stored.count, 1)
    }

    func testRemoveIdentityWithRecordIdentifierSkipsWhenEnumerationUnavailable() async {
        let fake = installFake()
        fake.enumerationUnavailable = true
        let targetIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        fake.stored = [seededPasswordIdentity(recordIdentifier: targetIdentifier)]
        fake.onMutation = { XCTFail("Single-identity removal must skip when enumeration is unavailable") }

        CredentialIdentityStoreManager.removeIdentity(withRecordIdentifier: targetIdentifier)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(fake.stored.count, 1)
    }

    func testRemoveIdentityWithRecordIdentifierNoOpWhenStoreDisabled() async {
        let fake = installFake()
        fake.isEnabledValue = false
        let targetIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        fake.stored = [seededPasswordIdentity(recordIdentifier: targetIdentifier)]
        fake.onMutation = { XCTFail("A disabled store must never be mutated") }

        CredentialIdentityStoreManager.removeIdentity(withRecordIdentifier: targetIdentifier)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(fake.stored.count, 1)
    }

    func testRemoveIdentityObserverReceivesExactIdentifierString() async {
        _ = installFake()
        let identifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded

        let observed = expectation(description: "removeIdentityObserver fires with the exact identifier")
        CredentialIdentityStoreManager.removeIdentityObserver = { observedIdentifier in
            XCTAssertEqual(observedIdentifier, identifier)
            observed.fulfill()
        }
        CredentialIdentityStoreManager.removeIdentity(withRecordIdentifier: identifier)
        await fulfillment(of: [observed], timeout: 1)
    }

    // MARK: - Per-database refresh decision tree (slice 04)

    func testRefreshOfTwoDatabasesYieldsUnion() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a-user", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b-user", hasPassword: true)

        let firstRefresh = expectMutations(1, on: fake, description: "First refresh replaces the empty store")
        CredentialIdentityStoreManager.populate(with: [entryA], for: databaseA)
        await fulfillment(of: [firstRefresh], timeout: 1)

        let secondRefresh = expectMutations(1, on: fake, description: "Second refresh saves additively")
        CredentialIdentityStoreManager.populate(with: [entryB], for: databaseB)
        await fulfillment(of: [secondRefresh], timeout: 1)

        // The first refresh whole-replaces (no other publisher present); the
        // second detects A's tagged identities and goes additive — and since
        // B owns nothing stored yet, there is no removal call either.
        XCTAssertEqual(fake.calls, ["replaceCredentialIdentities", "saveCredentialIdentities"])
        XCTAssertEqual(
            Set(storedRecordIdentifiers(fake)),
            [
                CredentialRecordIdentifier(databaseID: databaseA, entryID: entryA.id).encoded,
                CredentialRecordIdentifier(databaseID: databaseB, entryID: entryB.id).encoded,
            ]
        )
    }

    func testRefreshUsesWholeStoreReplaceWhenNoOtherDatabasePresent() async {
        let fake = installFake()
        let databaseA = UUID()
        let entry1 = makeEntry(title: "One", url: "https://one-site.com", username: "one", hasPassword: true)
        let entry2 = makeEntry(title: "Two", url: "https://two-site.com", username: "two", hasPassword: true)

        // Empty store: whole replace.
        let firstRefresh = expectMutations(1, on: fake, description: "Refresh of the empty store")
        CredentialIdentityStoreManager.populate(with: [entry1], for: databaseA)
        await fulfillment(of: [firstRefresh], timeout: 1)
        XCTAssertEqual(fake.calls, ["replaceCredentialIdentities"])

        // Store holding only this database's own (now stale) identities:
        // still a whole replace, never save, and the stale set is purged.
        let secondRefresh = expectMutations(1, on: fake, description: "Refresh over own stale identities")
        CredentialIdentityStoreManager.populate(with: [entry2], for: databaseA)
        await fulfillment(of: [secondRefresh], timeout: 1)

        XCTAssertEqual(fake.calls, ["replaceCredentialIdentities", "replaceCredentialIdentities"])
        XCTAssertEqual(
            storedRecordIdentifiers(fake),
            [CredentialRecordIdentifier(databaseID: databaseA, entryID: entry2.id).encoded]
        )
    }

    func testRefreshAfterEntryDeletionRemovesOnlyThatEntrysIdentities() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let entry1 = makeEntry(title: "E1", url: "https://e1-site.com", username: "e1", hasPassword: true)
        let entry2 = makeEntry(title: "E2", url: "https://e2-site.com", username: "e2", hasPassword: true)
        let entry3 = makeEntry(title: "E3", url: "https://e3-site.com", username: "e3", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entry1, in: databaseA)
            + CredentialIdentityStoreManager.passwordIdentities(for: entry2, in: databaseA)
            + CredentialIdentityStoreManager.passwordIdentities(for: entry3, in: databaseB)

        // entry2 was deleted from A; the refresh publishes only entry1.
        let mutation = expectMutations(2, on: fake, description: "Additive refresh removes then saves")
        CredentialIdentityStoreManager.populate(with: [entry1], for: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeCredentialIdentities", "saveCredentialIdentities"])
        XCTAssertEqual(
            Set(storedRecordIdentifiers(fake)),
            [
                CredentialRecordIdentifier(databaseID: databaseA, entryID: entry1.id).encoded,
                CredentialRecordIdentifier(databaseID: databaseB, entryID: entry3.id).encoded,
            ]
        )
    }

    func testRefreshPurgesLegacyIdentifiers() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = [seededPasswordIdentity(recordIdentifier: UUID().uuidString)]
            + CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)

        let mutation = expectMutations(2, on: fake, description: "Refresh removes the legacy identity and saves")
        CredentialIdentityStoreManager.populate(with: [entryA], for: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeCredentialIdentities", "saveCredentialIdentities"])
        XCTAssertEqual(
            Set(storedRecordIdentifiers(fake)),
            [
                CredentialRecordIdentifier(databaseID: databaseA, entryID: entryA.id).encoded,
                CredentialRecordIdentifier(databaseID: databaseB, entryID: entryB.id).encoded,
            ]
        )
    }

    func testRefreshLeavesUnrecognizedIdentifiersInAdditiveMode() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = [seededPasswordIdentity(recordIdentifier: "not-an-identifier", domain: "garbage-site.com")]
            + CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)

        // A owns nothing stored and there is no legacy identity, so the
        // additive refresh saves without any removal call — and the garbage
        // identity survives (it dies only via whole replace or clearStore()).
        let mutation = expectMutations(1, on: fake, description: "Additive refresh saves only")
        CredentialIdentityStoreManager.populate(with: [entryA], for: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["saveCredentialIdentities"])
        XCTAssertEqual(
            Set(storedRecordIdentifiers(fake)),
            [
                "not-an-identifier",
                CredentialRecordIdentifier(databaseID: databaseA, entryID: entryA.id).encoded,
                CredentialRecordIdentifier(databaseID: databaseB, entryID: entryB.id).encoded,
            ]
        )
    }

    func testRefreshPreservesEnumeratedIdentityWithoutRecordIdentifier() async {
        let fake = installFake()
        let databaseID = UUID()
        let unknownIdentity = IdentityWithoutRecordIdentifier()
        let entry = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        fake.stored = [unknownIdentity]

        let mutation = expectMutations(1, on: fake, description: "Conservative additive refresh")
        CredentialIdentityStoreManager.populate(with: [entry], for: databaseID)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["saveCredentialIdentities"])
        XCTAssertEqual(fake.stored.count, 2)
        XCTAssertTrue(fake.stored.contains {
            CredentialIdentityStoreManager.recordIdentifier(of: $0) == nil
        })
    }

    func testRefreshWithNoEligibleEntriesRemovesOwnAndLegacyOnlyWhenOthersPresent() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entryA, in: databaseA)
            + CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)
            + [seededPasswordIdentity(recordIdentifier: UUID().uuidString)]

        // An emptied database removes only its own + legacy identities;
        // removeAllCredentialIdentities must never run on the additive branch.
        let mutation = expectMutations(1, on: fake, description: "Removal-only refresh")
        CredentialIdentityStoreManager.populate(with: [], for: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeCredentialIdentities"])
        XCTAssertEqual(
            storedRecordIdentifiers(fake),
            [CredentialRecordIdentifier(databaseID: databaseB, entryID: entryB.id).encoded]
        )
    }

    func testRefreshWithNoEligibleEntriesAndNoOthersEmptiesStore() async {
        let fake = installFake()
        let databaseA = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entryA, in: databaseA)

        let mutation = expectMutations(1, on: fake, description: "Whole-store clear")
        CredentialIdentityStoreManager.populate(with: [], for: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["removeAllCredentialIdentities"])
        XCTAssertTrue(fake.stored.isEmpty)
    }

    func testRefreshFallsBackToWholeReplaceWhenEnumerationUnavailable() async {
        // macOS 14.0–14.3 contract: without enumeration every refresh is a
        // full replace, so other databases' identities are wiped and
        // repopulate lazily on their next unlock.
        let fake = installFake()
        fake.enumerationUnavailable = true
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)

        let mutation = expectMutations(1, on: fake, description: "Whole-store replace fallback")
        CredentialIdentityStoreManager.populate(with: [entryA], for: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        XCTAssertEqual(fake.calls, ["replaceCredentialIdentities"])
        XCTAssertEqual(
            storedRecordIdentifiers(fake),
            [CredentialRecordIdentifier(databaseID: databaseA, entryID: entryA.id).encoded]
        )
    }

    func testRefreshSurvivesStoreClearedBetweenEnumerateAndMutate() async {
        let fake = installFake()
        let databaseA = UUID()
        let databaseB = UUID()
        let staleEntry = makeEntry(title: "Stale", url: "https://stale-site.com", username: "stale", hasPassword: true)
        let freshEntry = makeEntry(title: "Fresh", url: "https://fresh-site.com", username: "fresh", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: staleEntry, in: databaseA)
            + CredentialIdentityStoreManager.passwordIdentities(for: entryB, in: databaseB)
        // External clear right after the enumeration snapshot is taken: the
        // refresh decides "additive" on stale data (the accepted worst case).
        fake.onEnumerate = { fake.stored = [] }

        let mutation = expectMutations(2, on: fake, description: "Refresh completes against the cleared store")
        CredentialIdentityStoreManager.populate(with: [freshEntry], for: databaseA)
        await fulfillment(of: [mutation], timeout: 1)

        // The removal of A's stale subset acted on an already-empty store (a
        // no-op), the save still landed, and nothing crashed or threw. B's
        // externally cleared identities stay gone until B's next refresh.
        XCTAssertEqual(fake.calls, ["removeCredentialIdentities", "saveCredentialIdentities"])
        XCTAssertEqual(
            storedRecordIdentifiers(fake),
            [CredentialRecordIdentifier(databaseID: databaseA, entryID: freshEntry.id).encoded]
        )
    }

    func testDisabledStoreNoOpsRefresh() async {
        // Extends testDisabledStoreMakesEveryOperationANoOp to the additive
        // path: even with another database's identities seeded, a disabled
        // store is never enumerated into a mutation.
        let fake = installFake()
        fake.isEnabledValue = false
        let otherIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        fake.stored = [seededPasswordIdentity(recordIdentifier: otherIdentifier)]
        fake.onMutation = { XCTFail("Refresh must not touch a disabled store") }
        let entry = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)

        CredentialIdentityStoreManager.populate(with: [entry], for: UUID())
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(storedRecordIdentifiers(fake), [otherIdentifier])
    }

    func testConcurrentMutationsAreSerialized() async {
        let fake = installFake()
        fake.mutationDelayNanoseconds = 20_000_000
        let mutationCount = 8
        let mutationsFinished = expectation(description: "all queued mutations finish")
        mutationsFinished.expectedFulfillmentCount = mutationCount
        fake.onMutation = { mutationsFinished.fulfill() }

        for _ in 0..<mutationCount {
            CredentialIdentityStoreManager.clearStore()
        }

        await fulfillment(of: [mutationsFinished], timeout: 5)
        XCTAssertEqual(fake.maxConcurrentMutations, 1)
        XCTAssertEqual(fake.calls.count, mutationCount)
        XCTAssertTrue(fake.stored.isEmpty)
    }

    func testQueuedMutationCapturesStoreAtInvocation() async {
        let firstFake = installFake()
        firstFake.mutationDelayNanoseconds = 20_000_000

        CredentialIdentityStoreManager.clearStore()

        let secondFake = FakeCredentialIdentityStore()
        CredentialIdentityStoreManager.storeProviderOverride = secondFake
        CredentialIdentityStoreManager.clearStore()

        await CredentialIdentityStoreManager.waitForPendingMutations()

        XCTAssertEqual(firstFake.calls, ["removeAllCredentialIdentities"])
        XCTAssertEqual(secondFake.calls, ["removeAllCredentialIdentities"])
    }

    func testPendingObserverCallbackDrainsAfterObserverReset() async {
        _ = installFake()
        let callbackObserved = expectation(description: "Captured observer callback runs before the queue barrier returns")
        var callbackCount = 0
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            callbackCount += 1
            callbackObserved.fulfill()
        }

        CredentialIdentityStoreManager.populate(with: [], for: UUID())
        CredentialIdentityStoreManager.populateObserver = nil

        await CredentialIdentityStoreManager.waitForPendingMutations()
        await fulfillment(of: [callbackObserved], timeout: 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testMutationsPreserveSynchronousInvocationOrder() async {
        let fake = installFake()
        fake.mutationDelayNanoseconds = 20_000_000
        let databaseA = UUID()
        let databaseB = UUID()
        let entryA = makeEntry(title: "A", url: "https://a-site.com", username: "a", hasPassword: true)
        let entryB = makeEntry(title: "B", url: "https://b-site.com", username: "b", hasPassword: true)
        let mutationsFinished = expectation(description: "ordered mutations finish")
        mutationsFinished.expectedFulfillmentCount = 3
        fake.onMutation = { mutationsFinished.fulfill() }

        CredentialIdentityStoreManager.populate(with: [entryA], for: databaseA)
        CredentialIdentityStoreManager.clearStore()
        CredentialIdentityStoreManager.populate(with: [entryB], for: databaseB)

        await fulfillment(of: [mutationsFinished], timeout: 5)
        XCTAssertEqual(
            fake.calls,
            ["replaceCredentialIdentities", "removeAllCredentialIdentities", "replaceCredentialIdentities"]
        )
        XCTAssertEqual(
            storedRecordIdentifiers(fake),
            [CredentialRecordIdentifier(databaseID: databaseB, entryID: entryB.id).encoded]
        )
    }

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        title: String,
        url: String,
        username: String,
        hasPassword: Bool,
        hasTOTP: Bool = false,
        customFields: [String: String] = [:],
        expires: Bool = false,
        expiryTime: Date? = nil
    ) -> KPEntry {
        let encrypted: EncryptedValue = hasPassword
            ? EncryptedValue(sealedData: Data([0]), hasValue: true)
            : .empty
        let totpConfig: TOTPConfig? = hasTOTP
            ? TOTPConfig(secret: EncryptedValue(sealedData: Data([0]), hasValue: true))
            : nil
        return KPEntry(
            id: id,
            title: title,
            username: username,
            password: encrypted,
            url: url,
            customFields: customFields,
            totpConfig: totpConfig,
            expires: expires,
            expiryTime: expiryTime
        )
    }

    private func makeSealedKey() throws -> EncryptedValue {
        try EncryptedValue.encrypt(Self.testPEM, using: sessionKey)
    }

    private func passkeyFields(domain: String) -> [String: String] {
        [
            PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.relyingPartyKey: domain,
            PasskeyCredential.usernameKey: "alice@\(domain)",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
        ]
    }

    /// Entry carrying only a passkey credential (no password, no URL).
    private func makePasskeyEntry(id: UUID = UUID(), domain: String) throws -> KPEntry {
        KPEntry(
            id: id,
            title: "Passkey \(domain)",
            username: "",
            password: .empty,
            url: "",
            customFields: passkeyFields(domain: domain),
            passkeyPrivateKey: try makeSealedKey()
        )
    }

    /// Entry publishing every suggestion type: password, passkey, and (on
    /// iOS 18 / macOS 15) one-time code — all under one record identifier.
    private func makeFullCredentialEntry(id: UUID = UUID(), domain: String) throws -> KPEntry {
        KPEntry(
            id: id,
            title: "Full \(domain)",
            username: "user@\(domain)",
            password: EncryptedValue(sealedData: Data([0]), hasValue: true),
            url: "https://\(domain)",
            customFields: passkeyFields(domain: domain),
            passkeyPrivateKey: try makeSealedKey(),
            totpConfig: TOTPConfig(secret: EncryptedValue(sealedData: Data([0]), hasValue: true))
        )
    }

    /// Every identity `populate` would publish for `entry` (password +
    /// passkey, plus the one-time-code identity where available).
    private func publishedIdentities(for entry: KPEntry, in databaseID: UUID) -> [any ASCredentialIdentity] {
        var identities: [any ASCredentialIdentity] =
            CredentialIdentityStoreManager.passwordIdentities(for: entry, in: databaseID)
        if let passkey = CredentialIdentityStoreManager.passkeyIdentity(for: entry, in: databaseID) {
            identities.append(passkey)
        }
        if #available(iOS 18.0, macOS 15.0, *),
           let oneTimeCode = CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry, in: databaseID) {
            identities.append(oneTimeCode)
        }
        return identities
    }

    /// Hand-made identity for seeding the fake store with legacy, garbage,
    /// or foreign-database record identifiers (no KPEntry involved).
    private func seededPasswordIdentity(
        recordIdentifier: String?,
        domain: String = "seeded-site.com",
        user: String = "seeded-user"
    ) -> ASPasswordCredentialIdentity {
        ASPasswordCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
            user: user,
            recordIdentifier: recordIdentifier
        )
    }

    private func storedRecordIdentifiers(_ fake: FakeCredentialIdentityStore) -> [String] {
        fake.stored.compactMap(\.recordIdentifier)
    }

    private func installFake() -> FakeCredentialIdentityStore {
        let fake = FakeCredentialIdentityStore()
        CredentialIdentityStoreManager.storeProviderOverride = fake
        return fake
    }

    /// Expectation fulfilled from the fake's `onMutation` hook exactly
    /// `count` times — the await point for the manager's fire-and-forget
    /// store operations (over-fulfillment fails the test).
    private func expectMutations(
        _ count: Int,
        on fake: FakeCredentialIdentityStore,
        description: String = "Store mutation"
    ) -> XCTestExpectation {
        let mutationExpectation = expectation(description: description)
        mutationExpectation.expectedFulfillmentCount = count
        fake.onMutation = { mutationExpectation.fulfill() }
        return mutationExpectation
    }
}

private final class IdentityWithoutRecordIdentifier: NSObject, ASCredentialIdentity {
    let serviceIdentifier = ASCredentialServiceIdentifier(identifier: "example.com", type: .domain)
    let user = "user"
    let recordIdentifier: String? = "not-used"
    var rank = 0

    override func responds(to selector: Selector!) -> Bool {
        if selector == Selector(("recordIdentifier")) {
            return false
        }
        return super.responds(to: selector)
    }
}
