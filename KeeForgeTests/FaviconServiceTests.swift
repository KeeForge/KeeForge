import XCTest
@testable import KeeForge

final class FaviconServiceTests: XCTestCase {
    private let showWebsiteIconsKey = "KeeForge.showWebsiteIcons"

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: SharedVaultStore.appGroupID) ?? .standard
    }

    override func tearDown() {
        sharedDefaults.removeObject(forKey: showWebsiteIconsKey)
        FaviconService.clearCache()
        super.tearDown()
    }

    // MARK: - Domain Extraction

    func testExtractDomainFromHTTPS() {
        XCTAssertEqual(FaviconService.extractDomain(from: "https://www.google.com/search?q=test"), "www.google.com")
    }

    func testExtractDomainFromHTTP() {
        XCTAssertEqual(FaviconService.extractDomain(from: "http://example.org/path"), "example.org")
    }

    func testExtractDomainWithoutScheme() {
        XCTAssertEqual(FaviconService.extractDomain(from: "github.com/user/repo"), "github.com")
    }

    func testExtractDomainLowercased() {
        XCTAssertEqual(FaviconService.extractDomain(from: "https://GitHub.COM"), "github.com")
    }

    func testExtractDomainFromEmptyString() {
        XCTAssertNil(FaviconService.extractDomain(from: ""))
    }

    func testExtractDomainFromWhitespace() {
        XCTAssertNil(FaviconService.extractDomain(from: "   "))
    }

    func testExtractDomainRejectsLocalhost() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://localhost:8080"))
    }

    func testExtractDomainRejectsIPAddress() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://192.168.1.1"))
    }

    func testExtractDomainWithPort() {
        XCTAssertEqual(FaviconService.extractDomain(from: "https://example.com:443/path"), "example.com")
    }

    func testExtractDomainWithSubdomain() {
        XCTAssertEqual(FaviconService.extractDomain(from: "https://mail.google.com"), "mail.google.com")
    }

    // MARK: - Private Domain Filtering

    func testRejectsRFC1918_10() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://10.0.0.1"))
    }

    func testRejectsRFC1918_172() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://172.16.0.1"))
        XCTAssertNil(FaviconService.extractDomain(from: "http://172.31.255.255"))
    }

    func testRejectsRFC1918_192() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://192.168.1.1"))
        XCTAssertNil(FaviconService.extractDomain(from: "http://192.168.0.100"))
    }

    func testRejectsLinkLocal() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://169.254.1.1"))
    }

    func testRejectsLoopback127() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://127.0.0.1"))
        XCTAssertNil(FaviconService.extractDomain(from: "http://127.0.0.2"))
    }

    func testRejectsLocalTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://myserver.local"))
    }

    func testRejectsInternalTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://wiki.internal"))
    }

    func testRejectsLanTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://nas.lan"))
    }

    func testRejectsHomeTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://router.home"))
    }

    func testRejectsLocaldomainTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://printer.localdomain"))
    }

    func testRejectsCorpTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://jira.corp"))
    }

    func testRejectsIntranetTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://portal.intranet"))
    }

    func testRejectsArpaTLD() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://1.168.192.in-addr.arpa"))
    }

    func testRejectsSingleLabelHostname() {
        XCTAssertNil(FaviconService.extractDomain(from: "http://myserver"))
    }

    func testAllowsPublicDomains() {
        XCTAssertEqual(FaviconService.extractDomain(from: "https://github.com"), "github.com")
        XCTAssertEqual(FaviconService.extractDomain(from: "https://www.example.com"), "www.example.com")
        XCTAssertEqual(FaviconService.extractDomain(from: "https://app.notion.so"), "app.notion.so")
    }

    func testIsPrivateDomainDirectly() {
        XCTAssertTrue(FaviconService.isPrivateDomain("myserver"))
        XCTAssertTrue(FaviconService.isPrivateDomain("wiki.internal"))
        XCTAssertTrue(FaviconService.isPrivateDomain("10.0.0.1"))
        XCTAssertTrue(FaviconService.isPrivateDomain("172.20.0.1"))
        XCTAssertTrue(FaviconService.isPrivateDomain("192.168.1.1"))
        XCTAssertTrue(FaviconService.isPrivateDomain("169.254.0.1"))
        XCTAssertTrue(FaviconService.isPrivateDomain("::1"))
        XCTAssertTrue(FaviconService.isPrivateDomain("fe80::1"))
        XCTAssertFalse(FaviconService.isPrivateDomain("github.com"))
        XCTAssertFalse(FaviconService.isPrivateDomain("8.8.8.8"))
    }

    // MARK: - Cache Key

    func testCacheKeyIsSHA256Hex() {
        let key = FaviconService.cacheKey(for: "example.com")
        // SHA256 hex string is 64 characters
        XCTAssertEqual(key.count, 64)
        // All hex characters
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
    }

    func testCacheKeyDeterministic() {
        let key1 = FaviconService.cacheKey(for: "google.com")
        let key2 = FaviconService.cacheKey(for: "google.com")
        XCTAssertEqual(key1, key2)
    }

    func testCacheKeyDifferentDomains() {
        let key1 = FaviconService.cacheKey(for: "google.com")
        let key2 = FaviconService.cacheKey(for: "github.com")
        XCTAssertNotEqual(key1, key2)
    }

    // MARK: - Disk Cache

    func testCachedImageReturnsNilForMissing() {
        XCTAssertNil(FaviconService.cachedImage(for: "nonexistent.com"))
    }

    func testClearCacheRemovesDirectory() {
        // Create cache directory with a file
        let fm = FileManager.default
        let dir = FaviconService.cacheDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let testFile = dir.appendingPathComponent("test")
        try? Data("test".utf8).write(to: testFile)
        XCTAssertTrue(fm.fileExists(atPath: testFile.path))

        FaviconService.clearCache()
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
    }

    func testCacheDirectoryLocation() {
        let dir = FaviconService.cacheDirectory
        XCTAssertTrue(dir.path.contains("favicons"))

        let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID
        )

        #if os(macOS)
        // The Mac extension does not need the plaintext domain fingerprint,
        // so the cache must stay in the app's own sandbox container.
        if let groupURL {
            XCTAssertFalse(
                dir.path.hasPrefix(groupURL.path),
                "macOS favicon cache must not live inside the App Group container"
            )
        }
        XCTAssertFalse(
            dir.path.contains("Group Containers"),
            "macOS favicon cache must not live in a Group Container"
        )
        XCTAssertTrue(
            dir.path.contains("Application Support"),
            "macOS favicon cache should live in the app's Application Support directory"
        )
        #else
        // iOS keeps the cache in the App Group container so the AutoFill
        // extension can read it.
        if let groupURL {
            XCTAssertTrue(
                dir.path.hasPrefix(groupURL.path),
                "iOS favicon cache should live inside the App Group container"
            )
        }
        #endif
    }

    // MARK: - Session Configuration

    func testSessionConfigurationFailsFastOnStuckConnections() {
        // Guards the QUIC-hang fix: short timeouts and no connectivity wait,
        // so a stuck HTTP/3 handshake on networks dropping UDP 443 fails in
        // seconds (and gets a TCP retry) instead of hanging for a minute.
        let config = FaviconService.sessionConfiguration()
        XCTAssertEqual(config.timeoutIntervalForRequest, FaviconService.requestTimeout)
        XCTAssertEqual(config.timeoutIntervalForResource, FaviconService.resourceTimeout)
        XCTAssertLessThanOrEqual(FaviconService.requestTimeout, 10)
        XCTAssertLessThanOrEqual(FaviconService.resourceTimeout, 30)
        XCTAssertFalse(config.waitsForConnectivity)
    }

    // MARK: - Settings

    func testShowWebsiteIconsDefaultsToFalse() {
        sharedDefaults.removeObject(forKey: showWebsiteIconsKey)
        XCTAssertFalse(SettingsService.showWebsiteIcons)
    }

    func testShowWebsiteIconsPersists() {
        SettingsService.showWebsiteIcons = true
        XCTAssertTrue(SettingsService.showWebsiteIcons)

        SettingsService.showWebsiteIcons = false
        XCTAssertFalse(SettingsService.showWebsiteIcons)
    }
}
