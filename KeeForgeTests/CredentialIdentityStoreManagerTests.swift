import AuthenticationServices
import XCTest
@testable import KeeForge

final class CredentialIdentityStoreManagerTests: XCTestCase {

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
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.user, "octocat")
        XCTAssertEqual(identities.first?.serviceIdentifier.identifier, "github.com")
        XCTAssertEqual(identities.first?.serviceIdentifier.type, .domain)
    }

    func testIdentityRecordIdentifierIsEntryUUID() {
        let id = UUID()
        let entry = makeEntry(id: id, title: "Test", url: "https://example.com", username: "user", hasPassword: true)
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)

        XCTAssertEqual(identities.first?.recordIdentifier, id.uuidString)
    }

    // MARK: - passwordIdentities: username fallback to title

    func testIdentityFallsBackToTitleWhenUsernameEmpty() {
        let entry = makeEntry(title: "Work Account", url: "https://example.com", username: "", hasPassword: true)
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.user, "Work Account")
    }

    // MARK: - passwordIdentities: entries that should be skipped

    func testIdentityEmptyWhenNoUsernameAndNoTitle() {
        let entry = makeEntry(title: "", url: "https://example.com", username: "", hasPassword: true)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry).isEmpty)
    }

    func testIdentityEmptyWhenNoPassword() {
        let entry = makeEntry(title: "Test", url: "https://example.com", username: "user", hasPassword: false)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry).isEmpty)
    }

    func testIdentityEmptyWhenURLEmpty() {
        let entry = makeEntry(title: "No URL", url: "", username: "user", hasPassword: true)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry).isEmpty)
    }

    func testIdentityEmptyWhenURLWhitespace() {
        let entry = makeEntry(title: "Bad URL", url: "   ", username: "user", hasPassword: true)
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry).isEmpty)
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
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)
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
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)

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
        XCTAssertTrue(CredentialIdentityStoreManager.passwordIdentities(for: entry).isEmpty)
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
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.serviceIdentifier.identifier, "example.com")
    }

    // MARK: - passwordIdentities: bare domain URLs

    func testIdentityWithBareDomainURL() {
        let entry = makeEntry(title: "Bare", url: "example.com", username: "user", hasPassword: true)
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)

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
        let identities = CredentialIdentityStoreManager.passwordIdentities(for: entry)

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

    // MARK: - oneTimeCodeIdentity (iOS 18+)

    @available(iOS 18.0, macOS 15.0, *)
    func testOTCIdentityForEntryWithTOTP() {
        let id = UUID()
        let entry = makeEntry(
            id: id,
            title: "GitHub",
            url: "https://github.com",
            username: "octocat",
            hasPassword: false,
            hasTOTP: true
        )
        let identity = CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry)

        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.label, "GitHub")
        XCTAssertEqual(identity?.serviceIdentifier.identifier, "github.com")
        XCTAssertEqual(identity?.recordIdentifier, id.uuidString)
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testOTCIdentityUsesUsernameFallbackWhenTitleEmpty() {
        let entry = makeEntry(
            title: "",
            url: "https://example.com",
            username: "user@example.com",
            hasPassword: false,
            hasTOTP: true
        )
        let identity = CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry)

        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.label, "user@example.com")
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testOTCIdentityNilWhenNoTOTP() {
        let entry = makeEntry(
            title: "Test",
            url: "https://example.com",
            username: "user",
            hasPassword: true,
            hasTOTP: false
        )
        XCTAssertNil(CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry))
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testOTCIdentityNilWhenNoURL() {
        let entry = makeEntry(
            title: "Test",
            url: "",
            username: "user",
            hasPassword: false,
            hasTOTP: true
        )
        XCTAssertNil(CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry))
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testOTCIdentityNilWhenNoLabelOrUsername() {
        let entry = makeEntry(
            title: "",
            url: "https://example.com",
            username: "",
            hasPassword: false,
            hasTOTP: true
        )
        XCTAssertNil(CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry))
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testOTCIdentityUsesAdditionalURLWhenPrimaryEmpty() {
        let entry = makeEntry(
            title: "Fallback OTC",
            url: "",
            username: "user",
            hasPassword: false,
            hasTOTP: true,
            customFields: ["KP2A_URL_1": "https://backup.example.com"]
        )
        let identity = CredentialIdentityStoreManager.oneTimeCodeIdentity(for: entry)

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

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        title: String,
        url: String,
        username: String,
        hasPassword: Bool,
        hasTOTP: Bool = false,
        customFields: [String: String] = [:]
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
            totpConfig: totpConfig
        )
    }
}
