import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import KeeForge

final class QuickUnlockPasswordIntervalTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let databaseID = UUID()

    override func setUp() {
        super.setUp()
        suiteName = "QuickUnlockPasswordIntervalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppGroupContainer.defaults.removeObject(forKey: "KeeForge.quickUnlockPasswordInterval")
        KeychainService.deleteCompositeKey(for: databaseID)
        super.tearDown()
    }

    func testIntervalDefaultsToNeverAndRoundTrips() {
        AppGroupContainer.defaults.removeObject(forKey: "KeeForge.quickUnlockPasswordInterval")
        XCTAssertEqual(SettingsService.quickUnlockPasswordInterval, .never, "Existing quick unlock keeps working until the user opts in")

        SettingsService.quickUnlockPasswordInterval = .fourteenDays
        XCTAssertEqual(SettingsService.quickUnlockPasswordInterval, .fourteenDays)
        SettingsService.quickUnlockPasswordInterval = .thirtyDays
        XCTAssertEqual(SettingsService.quickUnlockPasswordInterval, .thirtyDays)
    }

    func testMasterKeyIsDueOnceTheIntervalHasPassed() {
        let now = Date.now
        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: now.addingTimeInterval(-14 * day), in: defaults)

        XCTAssertTrue(isDue(.fourteenDays, at: now))
        XCTAssertFalse(isDue(.fourteenDays, at: now.addingTimeInterval(-1)))
        XCTAssertFalse(isDue(.thirtyDays, at: now))
        XCTAssertTrue(isDue(.thirtyDays, at: now.addingTimeInterval(16 * day)))
        XCTAssertFalse(isDue(.never, at: now.addingTimeInterval(365 * day)))
    }

    /// Items stored before the interval existed have no entry; the next
    /// unlock starts their clock instead of locking everyone out at once.
    func testWithoutAnEntryNothingIsDueUntilAnUnlockStartsTheClock() {
        let now = Date.now
        XCTAssertFalse(isDue(.fourteenDays, at: now))

        QuickUnlockKeychain.recordMasterKeyEntry(
            for: databaseID, replacingExisting: false, at: now.addingTimeInterval(-20 * day), in: defaults
        )
        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, replacingExisting: false, at: now, in: defaults)
        XCTAssertTrue(isDue(.fourteenDays, at: now), "A quick unlock must not move an existing entry")

        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: now, in: defaults)
        XCTAssertFalse(isDue(.fourteenDays, at: now), "Entering the master key restarts the interval")
    }

    /// Always keeps no saved key, so it is due whether or not an unlock has
    /// ever recorded an entry.
    func testAlwaysIsDueWithAndWithoutAnEntry() {
        XCTAssertTrue(isDue(.always, at: .now))

        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: .now, in: defaults)
        XCTAssertTrue(isDue(.always, at: .now))
    }

    func testAClockSetBackPastTheIntervalCountsAsDue() {
        let now = Date.now
        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: now.addingTimeInterval(15 * day), in: defaults)

        XCTAssertTrue(isDue(.fourteenDays, at: now))
        XCTAssertFalse(isDue(.thirtyDays, at: now))
    }

    func testEntriesAreKeptPerDatabase() {
        let now = Date.now
        let otherID = UUID()
        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: now.addingTimeInterval(-20 * day), in: defaults)
        QuickUnlockKeychain.recordMasterKeyEntry(for: otherID, at: now, in: defaults)

        XCTAssertTrue(isDue(.fourteenDays, at: now))
        XCTAssertFalse(QuickUnlockKeychain.isMasterKeyDue(for: otherID, interval: .fourteenDays, now: now, in: defaults))
    }

    func testExpiryDeletesTheQuickUnlockAndExpressItems() throws {
        let reference = DatabaseReference(
            id: databaseID, nickname: nil, filename: "Expiry.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false,
            lastOpenedAt: nil, addedAt: .now, colorTag: nil, legacyKeychainFilename: nil
        )
        do {
            try KeychainService.storeCompositeKey(SymmetricKey(size: .bits256), for: databaseID)
            try KeychainService.storeExpressUnlockKey(Data(repeating: 1, count: 65), for: databaseID)
        } catch {
            throw XCTSkip("Keychain writes are unavailable in the current test host: \(error)")
        }
        SettingsService.quickUnlockPasswordInterval = .fourteenDays

        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: .now.addingTimeInterval(-13 * day))
        XCTAssertFalse(QuickUnlockKeychain.expireIfDue(reference))
        XCTAssertTrue(KeychainService.hasStoredKey(for: databaseID))

        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: .now.addingTimeInterval(-15 * day))
        XCTAssertTrue(QuickUnlockKeychain.expireIfDue(reference))
        XCTAssertFalse(KeychainService.hasStoredKey(for: databaseID))
        XCTAssertFalse(KeychainService.hasExpressUnlockKey(for: databaseID))
    }

    func testKeychainOnlyAndAppWrapperPreservePolicyAndSeparateLegacyMetadataCleanup() throws {
        var reference = DatabaseReference(id: databaseID, nickname: "Keep metadata", filename: "Legacy.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false, lastOpenedAt: nil,
            addedAt: .now, colorTag: nil, legacyKeychainFilename: "legacy-\(UUID().uuidString).kdbx")
        DatabaseListStore.update(reference)
        defer { DatabaseListStore.clearAll() }
        let key = SymmetricKey(size: .bits256)
        do { try KeychainService.storeCompositeKey(key, for: databaseID) }
        catch { throw XCTSkip("Keychain writes unavailable: \(error)") }
        guard KeychainService.shouldStoreQuickUnlockKey(for: databaseID, legacyFilename: reference.legacyKeychainFilename) else {
            throw XCTSkip("No available quick-unlock mechanism on this host")
        }
        let legacy = try XCTUnwrap(reference.legacyKeychainFilename)
        let legacyItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.keevault.app",
            kSecAttrAccount as String: "compositeKey:\(legacy)",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
        ]
        let status = SecItemAdd(legacyItem as CFDictionary, nil)
        guard status == errSecSuccess else { throw XCTSkip("Legacy fixture item unavailable: \(status)") }
        defer { KeychainService.deleteLegacyCompositeKey(forFilename: legacy) }
        XCTAssertTrue(KeychainService.hasLegacyStoredKey(forFilename: legacy))
        let express = ExpressUnlockKey(binding: Data(repeating: 0x44, count: 32), transformedKey: SymmetricKey(data: Data(repeating: 0x33, count: 32)))
        SettingsService.quickUnlockPasswordInterval = .never
        let oldEntry = Date(timeIntervalSince1970: 1_600_000_000)
        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID, at: oldEntry)
        XCTAssertEqual(QuickUnlockKeychain.persistKeychainItems(QuickUnlockKeys(storedKey: key, expressKey: express),
            for: reference, masterKeyEntered: false), .stored)
        XCTAssertTrue(KeychainService.hasStoredKey(for: databaseID))
        XCTAssertTrue(KeychainService.hasExpressUnlockKey(for: databaseID))
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == databaseID }, reference)
        XCTAssertFalse(KeychainService.hasLegacyStoredKey(forFilename: legacy))
        XCTAssertEqual((AppGroupContainer.defaults.dictionary(forKey: "KeeForge.quickUnlockMasterKeyEntries")?[databaseID.uuidString] as? Date), oldEntry)
        XCTAssertTrue(QuickUnlockKeychain.persist(QuickUnlockKeys(storedKey: key, expressKey: express), for: reference, masterKeyEntered: true))
        reference.legacyKeychainFilename = nil
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == databaseID }, reference)
        XCTAssertGreaterThan(try XCTUnwrap(AppGroupContainer.defaults.dictionary(forKey: "KeeForge.quickUnlockMasterKeyEntries")?[databaseID.uuidString] as? Date), oldEntry)
        SettingsService.quickUnlockPasswordInterval = .always
        XCTAssertEqual(QuickUnlockKeychain.persistKeychainItems(QuickUnlockKeys(storedKey: key, expressKey: express),
            for: reference, masterKeyEntered: true), .notStored)
        XCTAssertFalse(KeychainService.hasStoredKey(for: databaseID))
        XCTAssertFalse(KeychainService.hasExpressUnlockKey(for: databaseID))
    }

    func testAlwaysDeletesFreshKeysAndRefusesToStoreNew() throws {
        let reference = DatabaseReference(
            id: databaseID, nickname: nil, filename: "Always.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false,
            lastOpenedAt: nil, addedAt: .now, colorTag: nil, legacyKeychainFilename: nil
        )
        do {
            try KeychainService.storeCompositeKey(SymmetricKey(size: .bits256), for: databaseID)
            try KeychainService.storeExpressUnlockKey(Data(repeating: 1, count: 65), for: databaseID)
        } catch {
            throw XCTSkip("Keychain writes are unavailable in the current test host: \(error)")
        }
        QuickUnlockKeychain.recordMasterKeyEntry(for: databaseID)
        SettingsService.quickUnlockPasswordInterval = .always

        let stored = QuickUnlockKeychain.persist(
            QuickUnlockKeys(storedKey: SymmetricKey(size: .bits256)),
            for: reference,
            masterKeyEntered: true
        )

        XCTAssertFalse(stored)
        XCTAssertFalse(KeychainService.hasStoredKey(for: databaseID))
        XCTAssertFalse(KeychainService.hasExpressUnlockKey(for: databaseID))
    }

    func testRetrieveSpendsTheAuthenticatedContext() {
        let reference = DatabaseReference(
            id: databaseID, nickname: nil, filename: "Spent.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false,
            lastOpenedAt: nil, addedAt: .now, colorTag: nil, legacyKeychainFilename: nil
        )
        let context = LAContext()

        XCTAssertThrowsError(try QuickUnlockKeychain.retrieve(for: reference, context: context))

        var error: NSError?
        XCTAssertFalse(context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error))
        XCTAssertEqual(error?.code, LAError.invalidContext.rawValue)
    }

    private func isDue(_ interval: SettingsService.QuickUnlockPasswordInterval, at now: Date) -> Bool {
        QuickUnlockKeychain.isMasterKeyDue(for: databaseID, interval: interval, now: now, in: defaults)
    }
}
