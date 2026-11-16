#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

final class BrowserPairingStoreTests: XCTestCase {
    private var suite: String!
    private var keychain: FakeBrowserBridgeKeychain!

    override func setUp() {
        super.setUp()
        suite = "BrowserPairingStoreTests.\(UUID().uuidString)"
        keychain = FakeBrowserBridgeKeychain()
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        keychain = nil
        suite = nil
        super.tearDown()
    }

    private func store(now: @escaping @Sendable () -> Date = { Date() }) -> BrowserPairingStore {
        BrowserPairingStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain, now: now)
    }

    private func browser(_ name: String, byte: UInt8 = 1) -> PairedBrowser {
        let publicKey = Data(repeating: byte, count: 32)
        let clientID = SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
        return PairedBrowser(clientID: clientID, publicKey: publicKey, name: name,
                             pairedAt: Date(timeIntervalSince1970: 100), lastUsedAt: nil)
    }

    func testAddListLookupReplaceRemoveAndPersist() async throws {
        let store = store()
        let firefox = browser("Firefox")
        let chrome = browser("Chrome", byte: 2)
        try await store.addOrReplace(firefox)
        try await store.addOrReplace(chrome)
        let listed = try await store.list()
        XCTAssertEqual(listed, [chrome, firefox])
        let found = try await store.browser(clientID: firefox.clientID)
        XCTAssertEqual(found, firefox)
        let missing = try await store.browser(clientID: "unknown")
        XCTAssertNil(missing)
        let renamed = browser("Safari")
        try await store.addOrReplace(renamed)
        let reloaded = self.store()
        let persisted = try await reloaded.list()
        XCTAssertEqual(persisted, [chrome, renamed])
        try await reloaded.remove(clientID: chrome.clientID)
        try await reloaded.remove(clientID: "unknown")
        let remaining = try await self.store().list()
        XCTAssertEqual(remaining, [renamed])
    }

    func testSanitizesControlsAndCapsNamesByCharacter() async throws {
        let store = store()
        let input = "\u{0000}\n\t\u{007f}\u{0085}\u{202e}" + String(repeating: "👩🏽", count: 70)
        try await store.addOrReplace(browser(input))
        let saved = try await self.store().list()
        XCTAssertEqual(saved.first?.name, String(repeating: "👩🏽", count: 64))
    }

    func testRejectsNonRaw32BytePublicKeys() async throws {
        let store = store()
        let invalid = PairedBrowser(clientID: "bad", publicKey: Data(repeating: 0, count: 31),
                                    name: "Browser", pairedAt: Date(), lastUsedAt: nil)
        do {
            try await store.addOrReplace(invalid)
            XCTFail("Expected invalid key")
        } catch BrowserPairingStoreError.invalidPublicKey { }
        let saved = try await store.list()
        XCTAssertTrue(saved.isEmpty)
    }

    func testTouchCoalescesPerClientAcrossStoreInstances() async throws {
        let clock = PairingTestClock()
        let store = store(now: { clock.date })
        let first = browser("First")
        let second = browser("Second", byte: 2)
        try await store.addOrReplace(first)
        try await store.addOrReplace(second)
        try await store.touch(clientID: first.clientID)
        let defaults = UserDefaults(suiteName: suite)!
        let firstWrite = SettingsService.browserBridgePairings(in: defaults)
        clock.advance(59)
        let reloaded = self.store(now: { clock.date })
        try await reloaded.touch(clientID: first.clientID)
        XCTAssertEqual(SettingsService.browserBridgePairings(in: defaults), firstWrite)
        try await reloaded.touch(clientID: second.clientID)
        let secondTouched = try await reloaded.browser(clientID: second.clientID)
        XCTAssertEqual(secondTouched?.lastUsedAt, clock.date)
        clock.advance(1)
        try await reloaded.touch(clientID: first.clientID)
        let firstTouched = try await self.store().browser(clientID: first.clientID)
        XCTAssertEqual(firstTouched?.lastUsedAt, clock.date)
        let beforeUnknown = SettingsService.browserBridgePairings(in: defaults)
        try await reloaded.touch(clientID: "unknown")
        XCTAssertEqual(SettingsService.browserBridgePairings(in: defaults), beforeUnknown)
    }

    func testStaticKeyCreatedOnceAndSurvivesRemovingLastBrowser() async throws {
        let store = store()
        let first = try await store.staticPrivateKey().rawRepresentation
        let second = try await self.store().staticPrivateKey().rawRepresentation
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(first, second)
        XCTAssertEqual(keychain.creations, 1)
        let paired = browser("Browser")
        try await store.addOrReplace(paired)
        try await store.remove(clientID: paired.clientID)
        let afterRemoval = try await store.staticPrivateKey().rawRepresentation
        XCTAssertEqual(afterRemoval, first)
        XCTAssertEqual(keychain.deletions, 0)
    }

    func testResetDeletesPairingsAndStaticKey() async throws {
        let store = store()
        let original = try await store.staticPrivateKey().rawRepresentation
        try await store.addOrReplace(browser("Browser"))
        try await store.reset()
        let remaining = try await self.store().list()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(keychain.data)
        let replacement = try await store.staticPrivateKey().rawRepresentation
        XCTAssertNotEqual(replacement, original)
        XCTAssertEqual(keychain.creations, 2)
        XCTAssertEqual(keychain.deletions, 1)
    }

    func testKeychainFailuresDoNotRotateOrDiscardPairings() async throws {
        let store = store()
        try await store.addOrReplace(browser("Browser"))
        keychain.fails = true
        do {
            _ = try await store.staticPrivateKey()
            XCTFail("Expected read failure")
        } catch BrowserPairingStoreError.keychain { }
        XCTAssertEqual(keychain.creations, 0)
        do {
            try await store.reset()
            XCTFail("Expected delete failure")
        } catch BrowserPairingStoreError.keychain { }
        let remaining = try await store.list()
        XCTAssertEqual(remaining.count, 1)
    }

    func testEnabledDefaultsOff() {
        XCTAssertFalse(SettingsService.browserBridgeEnabled(in: UserDefaults(suiteName: suite)!))
    }
}

private final class PairingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

#endif
