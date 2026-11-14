import CryptoKit
import LocalAuthentication
import os
import KDBXKit
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

    @MainActor
    func testRealLocalRekeyAndCloudUnlockPersistBothMasterKeyDates() async throws {
        DatabaseListStore.clearAll()
        let previousInterval = SettingsService.quickUnlockPasswordInterval
        SettingsService.quickUnlockPasswordInterval = .fourteenDays
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        let password = KDBXTestFixture.test.password
        let url = folder.appendingPathComponent("local-date.kdbx")
        try bytes.write(to: url)
        let localReference = try DatabaseListStore.add(url: url)
        let cloudReference = DatabaseReference(id: UUID(), nickname: nil, filename: "cloud-date.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false, lastOpenedAt: nil,
            addedAt: .now, colorTag: nil, legacyKeychainFilename: nil,
            source: .cloud(CloudSyncMetadata(provider: CloudProviderKind.dropbox.rawValue, accountId: "date-test",
                fileId: "/cloud-date.kdbx", displayPath: "/cloud-date.kdbx", remoteContentHash: nil,
                remoteModifiedAt: nil, remoteRev: "date-revision", lastSyncedAt: nil, lastSyncIssue: nil)))
        DatabaseListStore.update(cloudReference)
        defer {
            SettingsService.quickUnlockPasswordInterval = previousInterval
            DatabaseListStore.clearAll()
            KeychainService.deleteCompositeKey(for: localReference.id)
            KeychainService.deleteCompositeKey(for: cloudReference.id)
            QuickUnlockKeychain.removeMasterKeyEntry(for: localReference.id)
            QuickUnlockKeychain.removeMasterKeyEntry(for: cloudReference.id)
        }
        let key = try KDBXCrypto.compositeKey(password: password, keyFileData: nil)
        do {
            try KeychainService.storeCompositeKey(key, for: localReference.id)
            try KeychainService.storeCompositeKey(key, for: cloudReference.id)
        } catch { throw XCTSkip("Keychain writes unavailable in this host: \(error)") }
        guard KeychainService.shouldStoreQuickUnlockKey(for: cloudReference.id, legacyFilename: nil) else {
            throw XCTSkip("This host cannot persist quick-unlock items under the existing policy")
        }
        let race = MasterKeyDateRace()
        let ready = expectation(description: "real local rekey reached publication")
        let startPublication = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let native = DatabaseListStore.KeyCommitPublicationIO()
        var localObserver = QuickUnlockKeychain.MasterKeyEntryAccessObserver()
        localObserver.didRead = { id, access in if id == localReference.id && access == .record { race.pauseFirstSnapshot() } }
        let localAccessObserver = localObserver
        var io = native
        io.coordinate = { target, registry, accessor in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 {
                ready.fulfill()
                guard startPublication.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            }
            try QuickUnlockKeychain.$masterKeyEntryAccessObserver.withValue(localAccessObserver) {
                try native.coordinate(target, registry, accessor)
            }
        }
        let local = DatabaseViewModel(databaseReference: localReference, keyCommitPublicationIO: io)
        defer { local.lock(); startPublication.signal(); race.release() }
        await local.unlock(password: password)
        XCTAssertEqual(local.state, .unlocked)
        let now = Date.now
        QuickUnlockKeychain.recordMasterKeyEntry(for: localReference.id, at: now.addingTimeInterval(-day))
        QuickUnlockKeychain.removeMasterKeyEntry(for: cloudReference.id)
        let rekey = Task { try await local.changeMasterKey(newPassword: "date-safe rekey", newKeyFileData: nil,
            newKeyFileBookmarkData: nil, newKeyFileFilename: nil) }
        await fulfillment(of: [ready], timeout: 3)
        var cloudObserver = QuickUnlockKeychain.MasterKeyEntryAccessObserver()
        cloudObserver.willAccess = { id, access in if id == cloudReference.id && access == .record { race.contenderAttempts.signal() } }
        cloudObserver.didRead = { id, access in if id == cloudReference.id && access == .record { race.contenderRead.signal() } }
        cloudObserver.didWrite = { id, access in if id == cloudReference.id && access == .record { race.contenderWrote.signal() } }
        let observer = cloudObserver
        let persisted = OSAllocatedUnfairLock(initialState: false)
        let cloud = DatabaseViewModel(databaseReference: cloudReference, cloudSyncOperation: { reference, _ in
            CloudSyncResolution(reference: reference, localURL: DatabaseListStore.cacheLocation(for: reference), data: bytes, status: .current)
        }, quickUnlockKeyPersistOperation: { keys, reference, typed in
            startPublication.signal()
            XCTAssertEqual(race.firstSnapshot.wait(timeout: .now() + 5), .success)
            return QuickUnlockKeychain.$masterKeyEntryAccessObserver.withValue(observer) {
                let stored = QuickUnlockKeychain.persist(keys, for: reference, masterKeyEntered: typed)
                persisted.withLock { $0 = stored }
                return stored
            }
        })
        defer { cloud.lock() }
        let controller = Task.detached { race.releaseAfterContenderAttempt(expectsWrite: true) }
        await cloud.unlock(password: password)
        try await rekey.value
        let overtook = await controller.value
        XCTAssertFalse(overtook, "A cloud RMW cannot read while the local snapshot transaction is held")
        XCTAssertTrue(persisted.withLock { $0 }, "The production cloud persistence path must actually store")
        XCTAssertEqual(cloud.state, .unlocked)
        XCTAssertEqual(local.state, .unlocked)
        let entries = AppGroupContainer.defaults.dictionary(forKey: "KeeForge.quickUnlockMasterKeyEntries")
        let localDate = try XCTUnwrap(entries?[localReference.id.uuidString] as? Date)
        let cloudDate = try XCTUnwrap(entries?[cloudReference.id.uuidString] as? Date)
        XCTAssertGreaterThanOrEqual(localDate, now)
        XCTAssertGreaterThanOrEqual(cloudDate, now)
        let later = max(localDate, cloudDate).addingTimeInterval(15 * day)
        XCTAssertTrue(QuickUnlockKeychain.isMasterKeyDue(for: localReference.id, interval: .fourteenDays, now: later))
        XCTAssertTrue(QuickUnlockKeychain.isMasterKeyDue(for: cloudReference.id, interval: .fourteenDays, now: later))
        XCTAssertFalse(QuickUnlockKeychain.isMasterKeyDue(for: localReference.id, interval: .fourteenDays, now: Date.now))
        XCTAssertFalse(QuickUnlockKeychain.isMasterKeyDue(for: cloudReference.id, interval: .fourteenDays, now: Date.now))
        _ = try KDBXParser.parse(data: Data(contentsOf: url), password: "date-safe rekey", sessionKey: SymmetricKey(size: .bits256))
    }

    func testConcurrentRemovalAndListClearDoNotLoseOtherDatabaseDates() async throws {
        for clearsList in [false, true] {
            let firstID = UUID(), secondID = UUID(), addedID = UUID(), keptID = UUID()
            let removedIDs: Set<UUID> = [firstID, secondID]
            DatabaseListStore.clearAll()
            if clearsList {
                for id in removedIDs {
                    DatabaseListStore.update(DatabaseReference(id: id, nickname: nil, filename: "date-\(id).kdbx", bookmarkData: nil,
                        keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false,
                        lastOpenedAt: nil, addedAt: .now, colorTag: nil, legacyKeychainFilename: nil))
                }
            }
            defer {
                DatabaseListStore.clearAll()
                for id in [firstID, secondID, addedID, keptID] { QuickUnlockKeychain.removeMasterKeyEntry(for: id) }
            }
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            for id in [firstID, secondID, keptID] { QuickUnlockKeychain.recordMasterKeyEntry(for: id, at: date) }
            let race = MasterKeyDateRace()
            defer { race.release() }
            var firstObserver = QuickUnlockKeychain.MasterKeyEntryAccessObserver()
            firstObserver.didRead = { id, access in if removedIDs.contains(id) && access == .remove { race.pauseFirstSnapshot() } }
            let first = firstObserver
            let removal = Task.detached {
                QuickUnlockKeychain.$masterKeyEntryAccessObserver.withValue(first) {
                    if clearsList { DatabaseListStore.clearAll() }
                    else { QuickUnlockKeychain.removeMasterKeyEntry(for: firstID) }
                }
            }
            await fulfillment(of: [race.entered], timeout: 3)
            var secondObserver = QuickUnlockKeychain.MasterKeyEntryAccessObserver()
            secondObserver.willAccess = { id, access in if id == addedID && access == .record { race.contenderAttempts.signal() } }
            secondObserver.didRead = { id, access in if id == addedID && access == .record { race.contenderRead.signal() } }
            secondObserver.didWrite = { id, access in if id == addedID && access == .record { race.contenderWrote.signal() } }
            let second = secondObserver
            let writer = Task.detached {
                QuickUnlockKeychain.$masterKeyEntryAccessObserver.withValue(second) { QuickUnlockKeychain.recordMasterKeyEntry(for: addedID, at: date) }
            }
            let controller = Task.detached { race.releaseAfterContenderAttempt(expectsWrite: true) }
            await removal.value
            await writer.value
            let overtook = await controller.value
            XCTAssertFalse(overtook)
            let entries = AppGroupContainer.defaults.dictionary(forKey: "KeeForge.quickUnlockMasterKeyEntries")
            XCTAssertNil(entries?[firstID.uuidString])
            if clearsList { XCTAssertNil(entries?[secondID.uuidString]) }
            else { XCTAssertEqual(entries?[secondID.uuidString] as? Date, date) }
            XCTAssertEqual(entries?[keptID.uuidString] as? Date, date)
            XCTAssertEqual(entries?[addedID.uuidString] as? Date, date)
            XCTAssertTrue(QuickUnlockKeychain.isMasterKeyDue(for: addedID, interval: .fourteenDays, now: date.addingTimeInterval(15 * day)))
        }
    }

    func testDueReadWaitsForTheWholeConcurrentMasterEntryUpdate() async {
        let id = UUID(), date = Date.now
        QuickUnlockKeychain.recordMasterKeyEntry(for: id, at: date.addingTimeInterval(-20 * day))
        defer { QuickUnlockKeychain.removeMasterKeyEntry(for: id) }
        let race = MasterKeyDateRace()
        defer { race.release() }
        var writerObserver = QuickUnlockKeychain.MasterKeyEntryAccessObserver()
        writerObserver.didRead = { observedID, access in if observedID == id && access == .record { race.pauseFirstSnapshot() } }
        let first = writerObserver
        let writer = Task.detached {
            QuickUnlockKeychain.$masterKeyEntryAccessObserver.withValue(first) { QuickUnlockKeychain.recordMasterKeyEntry(for: id, at: date) }
        }
        await fulfillment(of: [race.entered], timeout: 3)
        var readerObserver = QuickUnlockKeychain.MasterKeyEntryAccessObserver()
        readerObserver.willAccess = { observedID, access in if observedID == id && access == .read { race.contenderAttempts.signal() } }
        readerObserver.didRead = { observedID, access in if observedID == id && access == .read { race.contenderRead.signal() } }
        let second = readerObserver
        let reader = Task.detached {
            QuickUnlockKeychain.$masterKeyEntryAccessObserver.withValue(second) {
                QuickUnlockKeychain.isMasterKeyDue(for: id, interval: .fourteenDays, now: date)
            }
        }
        let controller = Task.detached { race.releaseAfterContenderAttempt(expectsWrite: false) }
        await writer.value
        let due = await reader.value
        let overtook = await controller.value
        XCTAssertFalse(due, "A read after the serialized replacement sees the reset interval")
        XCTAssertFalse(overtook)
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

private final class MasterKeyDateRace: @unchecked Sendable {
    let entered = XCTestExpectation(description: "first date snapshot held")
    let firstSnapshot = DispatchSemaphore(value: 0)
    let contenderAttempts = DispatchSemaphore(value: 0)
    let contenderRead = DispatchSemaphore(value: 0)
    let contenderWrote = DispatchSemaphore(value: 0)
    private let continueFirst = DispatchSemaphore(value: 0)
    private let paused = OSAllocatedUnfairLock(initialState: false)
    func pauseFirstSnapshot() {
        guard paused.withLock({ value in if value { return false }; value = true; return true }) else { return }
        entered.fulfill()
        firstSnapshot.signal()
        XCTAssertEqual(continueFirst.wait(timeout: .now() + 5), .success)
    }
    func release() { continueFirst.signal() }
    func releaseAfterContenderAttempt(expectsWrite: Bool) -> Bool {
        defer { release() }
        guard contenderAttempts.wait(timeout: .now() + 5) == .success else { XCTFail("Second registry access never arrived"); return true }
        let overtook = contenderRead.wait(timeout: .now() + 1) == .success
        if overtook && expectsWrite { XCTAssertEqual(contenderWrote.wait(timeout: .now() + 3), .success) }
        return overtook
    }
}
