import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import KeeForge

/// `ExpressUnlock` must open exactly what the KDF path opens, and only offer a
/// cached key to the file version and composite key it was derived for.
final class ExpressUnlockTests: XCTestCase {
    private let sessionKey = SymmetricKey(size: .bits256)
    private var bundle: Bundle { Bundle(for: Self.self) }

    func testFreshOpenYieldsAKeyThatReopensTheSameVersionWithoutTheKDF() throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try compositeKey(for: .test)
        let derivations = DerivationCounter()

        let fresh = try ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: nil,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )
        XCTAssertEqual(derivations.count, 1)
        XCTAssertFalse(fresh.usedCachedKey)
        let storedKey = try XCTUnwrap(fresh.keyToStore)

        let express = try ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: storedKey,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )

        XCTAssertEqual(derivations.count, 1, "The cached key must replace the KDF")
        XCTAssertTrue(express.usedCachedKey)
        XCTAssertEqual(express.keyToStore?.binding, storedKey.binding)
        let reference = try KDBXParser.parseWithMetaAndHeader(
            data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )
        try KDBXTreeAssertions.assertTreesEqual(
            (reference.rootGroup, reference.meta), (express.rootGroup, express.meta), sessionKey: sessionKey
        )
        XCTAssertEqual(express.header.masterSeed, reference.header.masterSeed)
    }

    /// Every bundled fixture, including foreign writers, other ciphers, a key
    /// file, and unknown header fields, opens to the same tree through the
    /// cached key as through the KDF.
    func testCachedKeyOpensEveryBundledFixtureLikeTheKDF() throws {
        let fixtures: [KDBXTestFixture] = [
            .test, .demo, .demoKeyfile, .unknownInnerHeader, .kitchenSink,
            .foreignChaCha20, .foreignTwofish, .argon2HighIterations,
        ]
        for fixture in fixtures {
            let data = try fixture.data(in: bundle)
            let compositeKey = try KDBXCrypto.compositeKey(
                password: fixture.password,
                keyFileData: try fixture.keyFileData(in: bundle)
            )
            let cachedKey = try XCTUnwrap(ExpressUnlock.parse(
                data: data, compositeKey: compositeKey, cachedKey: nil, sessionKey: sessionKey, kdfPolicy: .mainApp
            ).keyToStore, fixture.name)
            let derivations = DerivationCounter()

            let express = try ExpressUnlock.parse(
                data: data, compositeKey: compositeKey, cachedKey: cachedKey,
                sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
            )

            XCTAssertTrue(express.usedCachedKey, fixture.name)
            XCTAssertEqual(derivations.count, 0, fixture.name)
            let reference = try KDBXParser.parseWithMetaAndHeader(
                data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
            )
            try KDBXTreeAssertions.assertTreesEqual(
                (reference.rootGroup, reference.meta), (express.rootGroup, express.meta), sessionKey: sessionKey
            )
            XCTAssertEqual(express.header.unknownOuterHeaderFields.count, reference.header.unknownOuterHeaderFields.count, fixture.name)
            XCTAssertEqual(express.header.innerHeaderBinaryFields, reference.header.innerHeaderBinaryFields, fixture.name)
        }
    }

    func testCachedKeyIsTheKDFOutputOfThatVersion() throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try compositeKey(for: .test)
        let header = try header(of: data)

        let opened = try ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: nil, sessionKey: sessionKey, kdfPolicy: .mainApp
        )

        let expected = try KDBXParser.deriveKey(
            compositeKey: compositeKey, kdfParams: header.kdfParameters, kdfPolicy: .mainApp
        )
        let stored = try XCTUnwrap(opened.keyToStore)
        XCTAssertEqual(stored.transformedKey.withUnsafeBytes { Data($0) }, expected)
    }

    /// Every save rotates the KDF salt, so the previous version's key is not
    /// offered and the new version's key replaces it.
    func testKeyFromAnEarlierVersionIsNotOfferedAfterASave() throws {
        let original = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try compositeKey(for: .test)
        let earlierKey = try XCTUnwrap(ExpressUnlock.parse(
            data: original, compositeKey: compositeKey, cachedKey: nil, sessionKey: sessionKey, kdfPolicy: .mainApp
        ).keyToStore)
        let saved = try resave(original, compositeKey: compositeKey)
        let derivations = DerivationCounter()

        let opened = try ExpressUnlock.parse(
            data: saved, compositeKey: compositeKey, cachedKey: earlierKey,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )

        XCTAssertEqual(derivations.count, 1)
        XCTAssertFalse(opened.usedCachedKey)
        let newKey = try XCTUnwrap(opened.keyToStore)
        XCTAssertNotEqual(newKey.binding, earlierKey.binding)
        XCTAssertTrue(newKey.matches(kdfParameters: try header(of: saved).kdfParameters, compositeKey: compositeKey))
        XCTAssertFalse(earlierKey.matches(kdfParameters: try header(of: saved).kdfParameters, compositeKey: compositeKey))
    }

    /// A key cached under one master key is never offered under another, and
    /// a wrong password still fails exactly as without a cache.
    func testKeyIsNotOfferedUnderAnotherCompositeKey() throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try compositeKey(for: .test)
        let cachedKey = try XCTUnwrap(ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: nil, sessionKey: sessionKey, kdfPolicy: .mainApp
        ).keyToStore)
        let wrongKey = KDBXCrypto.compositeKey(password: "not the password")
        let derivations = DerivationCounter()

        XCTAssertFalse(cachedKey.matches(kdfParameters: try header(of: data).kdfParameters, compositeKey: wrongKey))
        XCTAssertThrowsError(try ExpressUnlock.parse(
            data: data, compositeKey: wrongKey, cachedKey: cachedKey,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )) { error in
            guard case .hmacMismatch? = error as? KDBXCrypto.CryptoError else {
                return XCTFail("Expected hmacMismatch, got \(error)")
            }
        }
        XCTAssertEqual(derivations.count, 1, "The wrong password runs the KDF once, with no cached shortcut")
    }

    /// A binding that matches but key bytes that do not (a damaged item) must
    /// fall back to the KDF instead of failing the unlock.
    func testDamagedKeyWithAValidBindingFallsBackToTheKDF() throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try compositeKey(for: .test)
        let binding = try XCTUnwrap(ExpressUnlockKey.binding(
            kdfParameters: try header(of: data).kdfParameters,
            compositeKey: compositeKey
        ))
        let damagedKey = ExpressUnlockKey(binding: binding, transformedKey: SymmetricKey(size: .bits256))
        let derivations = DerivationCounter()

        let opened = try ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: damagedKey,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )

        XCTAssertEqual(derivations.count, 1)
        XCTAssertFalse(opened.usedCachedKey)
        let repairedKey = try XCTUnwrap(opened.keyToStore)
        XCTAssertNotEqual(
            repairedKey.transformedKey.withUnsafeBytes { Data($0) },
            damagedKey.transformedKey.withUnsafeBytes { Data($0) }
        )
        XCTAssertTrue(try ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: repairedKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        ).usedCachedKey)
    }

    func testAESKDFDatabaseUsesTheCachedKey() throws {
        let compositeKey = try compositeKey(for: .test)
        let data = try resave(
            try KDBXTestFixture.test.data(in: bundle),
            compositeKey: compositeKey,
            kdfParameters: try DatabaseCreationDefaults.aesKDFParameters(rounds: 1_000)
        )
        let cachedKey = try XCTUnwrap(ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: nil, sessionKey: sessionKey, kdfPolicy: .mainApp
        ).keyToStore)
        let derivations = DerivationCounter()

        let opened = try ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: cachedKey,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )

        XCTAssertTrue(opened.usedCachedKey)
        XCTAssertEqual(derivations.count, 0)
    }

    /// KDBX 3.1 is read-only and keeps its own KDF path: nothing is cached
    /// and a key cached for another file is ignored.
    func testKDBX31OpensWithoutAnExpressKey() throws {
        let legacy = try KDBXTestFixture.legacyKDBX31.data(in: bundle)
        let legacyKey = try compositeKey(for: .legacyKDBX31)
        let foreignKey = ExpressUnlockKey(binding: Data(count: 32), transformedKey: SymmetricKey(size: .bits256))

        let opened = try ExpressUnlock.parse(
            data: legacy, compositeKey: legacyKey, cachedKey: foreignKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )

        XCTAssertNil(opened.keyToStore)
        XCTAssertFalse(opened.usedCachedKey)
        XCTAssertFalse(opened.rootGroup.allEntries.isEmpty)
    }

    // MARK: - Binding

    func testBindingCoversEveryKDFParameter() throws {
        let compositeKey = KDBXCrypto.compositeKey(password: "binding")
        let parameters = try DatabaseCreationDefaults.argon2idKDFParameters(salt: Data(repeating: 7, count: 32))
        let key = try XCTUnwrap(ExpressUnlockKey(
            transformedKey: Data(repeating: 1, count: 32), kdfParameters: parameters, compositeKey: compositeKey
        ))
        XCTAssertTrue(key.matches(kdfParameters: parameters, compositeKey: compositeKey))

        let variants: [String: Any] = [
            "S": Data(repeating: 8, count: 32),
            "I": UInt64(11),
            "M": UInt64(32 << 20),
            "P": UInt32(1),
            "V": UInt32(0x10),
            "$UUID": KDBXParser.argon2dUUID,
        ]
        for (name, value) in variants {
            var changed = parameters
            changed[name] = value
            XCTAssertFalse(key.matches(kdfParameters: changed, compositeKey: compositeKey), "Changing \(name) must invalidate")
        }

        var extra = parameters
        extra["K"] = Data([1])
        XCTAssertFalse(key.matches(kdfParameters: extra, compositeKey: compositeKey), "An added parameter must invalidate")

        var retyped = parameters
        retyped["I"] = UInt32(10)
        XCTAssertFalse(key.matches(kdfParameters: retyped, compositeKey: compositeKey), "The value type is bound too")
    }

    func testParametersTheBindingCannotEncodeAreNeverCached() {
        let compositeKey = KDBXCrypto.compositeKey(password: "binding")
        let parameters: [String: Any] = ["$UUID": KDBXParser.argon2idUUID, "X": Double(1)]

        XCTAssertNil(ExpressUnlockKey.binding(kdfParameters: parameters, compositeKey: compositeKey))
        XCTAssertNil(ExpressUnlockKey(
            transformedKey: Data(repeating: 1, count: 32), kdfParameters: parameters, compositeKey: compositeKey
        ))
        let key = ExpressUnlockKey(binding: Data(count: 32), transformedKey: SymmetricKey(size: .bits256))
        XCTAssertFalse(key.matches(kdfParameters: parameters, compositeKey: compositeKey))
    }

    func testOnlyAFullLengthKeyIsCached() throws {
        let parameters = try DatabaseCreationDefaults.argon2idKDFParameters()
        XCTAssertNil(ExpressUnlockKey(
            transformedKey: Data(repeating: 1, count: 16),
            kdfParameters: parameters,
            compositeKey: KDBXCrypto.compositeKey(password: "binding")
        ))
    }

    // MARK: - Serialization

    func testSerializationRoundTripsAndRejectsMalformedPayloads() throws {
        let key = ExpressUnlockKey(binding: Data(repeating: 3, count: 32), transformedKey: SymmetricKey(size: .bits256))
        let payload = key.serialized()
        XCTAssertEqual(payload.count, ExpressUnlockKey.serializedByteCount)

        let decoded = try XCTUnwrap(ExpressUnlockKey(serialized: payload))
        XCTAssertEqual(decoded.binding, key.binding)
        XCTAssertEqual(decoded.transformedKey, key.transformedKey)
        XCTAssertNotNil(ExpressUnlockKey(serialized: SymmetricKey(data: payload)), "The Keychain hands it back as a key")

        XCTAssertNil(ExpressUnlockKey(serialized: payload.dropLast()))
        XCTAssertNil(ExpressUnlockKey(serialized: payload + Data([0])))
        var otherVersion = Data(payload)
        otherVersion[otherVersion.startIndex] = 2
        XCTAssertNil(ExpressUnlockKey(serialized: otherVersion))
        XCTAssertNil(ExpressUnlockKey(serialized: Data()))
    }

    // MARK: - Saves

    /// A save keeps the KDF output of the salt it rotated to, and that key
    /// opens the saved bytes exactly as the KDF does.
    func testWriteKeepsTheKeyOfTheSavedVersion() throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try compositeKey(for: .test)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )
        let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey)
        let derivations = DerivationCounter()

        let written = try ExpressUnlock.write(
            draft: draft, compositeKey: compositeKey, header: parsed.header,
            kdfPolicy: .mainApp, deriveKey: derivations.derive
        )

        XCTAssertEqual(derivations.count, 1, "The save's own KDF run is the key; no second run")
        let savedHeader = try header(of: written.data)
        XCTAssertNotEqual(savedHeader.kdfParameters["S"] as? Data, parsed.header.kdfParameters["S"] as? Data)
        let expressKey = try XCTUnwrap(written.expressKey)
        XCTAssertTrue(expressKey.matches(kdfParameters: savedHeader.kdfParameters, compositeKey: compositeKey))
        XCTAssertFalse(expressKey.matches(kdfParameters: parsed.header.kdfParameters, compositeKey: compositeKey))
        XCTAssertEqual(
            expressKey.transformedKey.withUnsafeBytes { Data($0) },
            try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: savedHeader.kdfParameters, kdfPolicy: .mainApp)
        )

        let reopened = try ExpressUnlock.parse(
            data: written.data, compositeKey: compositeKey, cachedKey: expressKey,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )
        XCTAssertTrue(reopened.usedCachedKey)
        XCTAssertEqual(derivations.count, 1)
        let viaKDF = try KDBXParser.parseWithMetaAndHeader(
            data: written.data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )
        try KDBXTreeAssertions.assertTreesEqual(
            (viaKDF.rootGroup, viaKDF.meta), (reopened.rootGroup, reopened.meta), sessionKey: sessionKey
        )
    }

    /// The writer seam encrypts with whatever key it is handed, so only KDF
    /// output may go in: anything else writes a file the password cannot open.
    func testWriterUsesTheSuppliedTransformedKey() throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try compositeKey(for: .test)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )

        let written = try KDBXWriter.write(
            rootGroup: parsed.rootGroup, meta: parsed.meta, header: parsed.header, sessionKey: sessionKey
        ) { _ in Data(repeating: 7, count: 32) }

        XCTAssertThrowsError(try KDBXParser.parseWithMetaAndHeader(
            data: written, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )) { error in
            guard case .hmacMismatch? = error as? KDBXCrypto.CryptoError else {
                return XCTFail("Expected hmacMismatch, got \(error)")
            }
        }
    }

    func testLocalSaveReturnsTheKeyOfTheSavedFile() async throws {
        DatabaseListStore.clearAll()
        defer { DatabaseListStore.clearAll() }
        let databaseURL = try makeScratchCopy(of: .test)
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeSaveContext(data: try Data(contentsOf: databaseURL))

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft, reference: reference, compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512, kdfPolicy: .mainApp
        )

        guard case .saved(_, let expressKey) = result else {
            return XCTFail("Expected save to succeed.")
        }
        try assertOpensWithoutTheKDF(
            try Data(contentsOf: databaseURL), expressKey: XCTUnwrap(expressKey), compositeKey: context.compositeKey
        )
    }

    func testCloudSaveReturnsTheKeyOfTheUploadedBytes() async throws {
        let cacheURL = try makeScratchCopy(of: .test)
        let reference = makeCloudReference()
        let context = try makeSaveContext(data: try Data(contentsOf: cacheURL))
        let uploaded = UploadedBytes()

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft, reference: reference, compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512, expectedRev: "rev-1", kdfPolicy: .mainApp,
            environment: makeCloudEnvironment(cacheURL: cacheURL, uploaded: uploaded)
        )

        guard case .saved(_, let expressKey) = result else {
            return XCTFail("Expected save to succeed.")
        }
        try assertOpensWithoutTheKDF(
            try XCTUnwrap(uploaded.data), expressKey: XCTUnwrap(expressKey), compositeKey: context.compositeKey
        )
    }

    /// The saver never hands out a key for a hardware-key database, whatever
    /// the caller would do with it.
    func testSavesOfAHardwareKeyDatabaseReturnNoKey() async throws {
        DatabaseListStore.clearAll()
        defer { DatabaseListStore.clearAll() }
        let databaseURL = try makeScratchCopy(of: .test)
        var localReference = try TestDatabaseSupport.makeReference(for: databaseURL)
        localReference.hardwareKey = HardwareKeyConfiguration(transport: .nfc, slot: .two)
        let localContext = try makeSaveContext(data: try Data(contentsOf: databaseURL))

        let localResult = try await LocalDatabaseSaver.save(
            draft: localContext.draft, reference: localReference, compositeKey: localContext.compositeKey,
            openTimeSHA512: localContext.openTimeSHA512, kdfPolicy: .mainApp
        )

        let cacheURL = try makeScratchCopy(of: .test)
        var cloudReference = makeCloudReference()
        cloudReference.hardwareKey = HardwareKeyConfiguration(transport: .nfc, slot: .two)
        let cloudContext = try makeSaveContext(data: try Data(contentsOf: cacheURL))
        let cloudResult = try await CloudDatabaseSaver.save(
            draft: cloudContext.draft, reference: cloudReference, compositeKey: cloudContext.compositeKey,
            openTimeSHA512: cloudContext.openTimeSHA512, expectedRev: "rev-1", kdfPolicy: .mainApp,
            environment: makeCloudEnvironment(cacheURL: cacheURL, uploaded: UploadedBytes())
        )

        for result in [localResult, cloudResult] {
            guard case .saved(_, let expressKey) = result else {
                return XCTFail("Expected save to succeed.")
            }
            XCTAssertNil(expressKey)
        }
    }

    // MARK: - Helpers

    private func compositeKey(for fixture: KDBXTestFixture) throws -> SymmetricKey {
        try KDBXCrypto.compositeKey(password: fixture.password, keyFileData: nil)
    }

    private func header(of data: Data) throws -> KDBXParser.Header {
        var reader = DataReader(data: data)
        _ = try KDBXParser.parseVersion(from: &reader)
        return try KDBXParser.parseHeader(&reader)
    }

    private func resave(
        _ data: Data,
        compositeKey: SymmetricKey,
        kdfParameters: [String: Any]? = nil
    ) throws -> Data {
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )
        guard let kdfParameters else {
            return try KDBXWriter.write(
                rootGroup: parsed.rootGroup, meta: parsed.meta, compositeKey: compositeKey,
                header: parsed.header, sessionKey: sessionKey, kdfPolicy: .mainApp
            )
        }
        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup, meta: parsed.meta, compositeKey: compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(cipherID: parsed.header.cipherID, kdfParameters: kdfParameters),
            sessionKey: sessionKey, kdfPolicy: .mainApp
        )
    }

    private func assertOpensWithoutTheKDF(
        _ data: Data,
        expressKey: ExpressUnlockKey,
        compositeKey: SymmetricKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let derivations = DerivationCounter()
        let opened = try ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: expressKey,
            sessionKey: sessionKey, kdfPolicy: .mainApp, deriveKey: derivations.derive
        )
        XCTAssertTrue(opened.usedCachedKey, file: file, line: line)
        XCTAssertEqual(derivations.count, 0, file: file, line: line)
    }

    private func makeSaveContext(data: Data) throws -> (draft: DatabaseDraft, compositeKey: SymmetricKey, openTimeSHA512: Data) {
        let compositeKey = try compositeKey(for: .test)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )
        let draft = try DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey).apply(
            .createEntry(
                parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup),
                draft: EntryDraftPayload(title: "Saved", password: "saved-secret")
            )
        )
        return (draft, compositeKey, KDBXCrypto.sha512(data))
    }

    private func makeScratchCopy(of fixture: KDBXTestFixture) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("express.kdbx", isDirectory: false)
        try fixture.data(in: bundle).write(to: url)
        return url
    }

    private func makeCloudReference() -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "express.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: false,
            autoFillEnabled: true,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-express",
                    fileId: "/Vaults/express.kdbx",
                    displayPath: "/Vaults/express.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: "rev-1",
                    lastSyncedAt: nil,
                    lastSyncIssue: nil
                )
            )
        )
    }

    private func makeCloudEnvironment(cacheURL: URL, uploaded: UploadedBytes) -> CloudDatabaseSaver.Environment {
        let backupDirectory = cacheURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.cacheURL = { _ in cacheURL }
        environment.backupDirectoryURL = { _ in backupDirectory }
        environment.pruneBackups = { _, _ in }
        environment.getMetadata = { _ in
            CloudFileMetadata(modifiedDate: Date(timeIntervalSince1970: 100), contentHash: nil, size: 0, rev: "rev-1")
        }
        environment.upload = { _, data, _, _ in
            uploaded.record(data)
            return CloudFileMetadata(modifiedDate: Date(timeIntervalSince1970: 200), contentHash: nil, size: Int64(data.count), rev: "rev-2")
        }
        environment.applyUploadedBytes = { reference, _, _ in reference }
        environment.dropSupersededPendingUploads = { _, _ in }
        return environment
    }
}

private final class UploadedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?

    var data: Data? { lock.withLock { bytes } }

    func record(_ data: Data) {
        lock.withLock { bytes = data }
    }
}

/// Counts KDF runs so a test can tell the cached path from the KDF path.
final class DerivationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0

    var count: Int { lock.withLock { runs } }

    var derive: ExpressUnlock.KeyDerivation {
        { [self] compositeKey, kdfParameters, kdfPolicy in
            lock.withLock { runs += 1 }
            return try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: kdfParameters, kdfPolicy: kdfPolicy)
        }
    }
}

/// The session side: which key quick unlock reads, what an unlock hands to
/// Keychain storage, and that a hardware-key database never takes part.
@MainActor
final class DatabaseViewModelExpressUnlockTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: Self.self) }
    private let password = KDBXTestFixture.test.password

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    func testPasswordUnlockHandsTheNewVersionsKeyToQuickUnlockStorage() async throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let persisted = PersistedKeys()
        let vm = try makeViewModel(data: data, persisted: persisted)

        await vm.unlock(password: password)

        XCTAssertEqual(vm.state, .unlocked)
        let keys = try XCTUnwrap(persisted.last)
        XCTAssertEqual(keys.storedKey, try KDBXCrypto.compositeKey(password: password, keyFileData: nil))
        let expressKey = try XCTUnwrap(keys.expressKey)
        XCTAssertTrue(try ExpressUnlock.parse(
            data: data, compositeKey: keys.storedKey, cachedKey: expressKey,
            sessionKey: SymmetricKey(size: .bits256), kdfPolicy: .mainApp
        ).usedCachedKey)
    }

    func testBiometricUnlockOpensWithTheStoredKeyAndKeepsIt() async throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: nil)
        let expressKey = try expressKey(for: data, compositeKey: compositeKey)
        let persisted = PersistedKeys()
        let vm = try makeViewModel(data: data, persisted: persisted) { _, _ in
            QuickUnlockKeys(storedKey: compositeKey, expressKey: expressKey)
        }

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .unlocked)
        XCTAssertFalse(vm.rootGroup?.allEntries.isEmpty ?? true)
        XCTAssertEqual(persisted.last?.expressKey?.binding, expressKey.binding)
        XCTAssertEqual(persisted.last?.expressKey?.transformedKey, expressKey.transformedKey)
    }

    /// The common case after editing on another device: the stored key is
    /// for an older version, so the unlock runs the KDF, counts no failed
    /// attempt, and stores the current version's key.
    func testBiometricUnlockAfterTheFileChangedRefreshesTheKey() async throws {
        let original = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: nil)
        let staleKey = try expressKey(for: original, compositeKey: compositeKey)
        let changed = try resave(original, compositeKey: compositeKey)
        let persisted = PersistedKeys()
        let vm = try makeViewModel(data: changed, persisted: persisted) { _, _ in
            QuickUnlockKeys(storedKey: compositeKey, expressKey: staleKey)
        }

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .unlocked)
        XCTAssertEqual(vm.failedAttempts, 0)
        let refreshed = try XCTUnwrap(persisted.last?.expressKey)
        XCTAssertNotEqual(refreshed.binding, staleKey.binding)
        XCTAssertTrue(refreshed.matches(kdfParameters: try header(of: changed).kdfParameters, compositeKey: compositeKey))
    }

    func testBiometricUnlockWithADamagedKeyStillUnlocks() async throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: nil)
        let binding = try XCTUnwrap(ExpressUnlockKey.binding(
            kdfParameters: try header(of: data).kdfParameters, compositeKey: compositeKey
        ))
        let damaged = ExpressUnlockKey(binding: binding, transformedKey: SymmetricKey(size: .bits256))
        let persisted = PersistedKeys()
        let vm = try makeViewModel(data: data, persisted: persisted) { _, _ in
            QuickUnlockKeys(storedKey: compositeKey, expressKey: damaged)
        }

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .unlocked)
        XCTAssertEqual(vm.failedAttempts, 0)
        XCTAssertNotEqual(persisted.last?.expressKey?.transformedKey, damaged.transformedKey)
    }

    /// The master password changed elsewhere: the stored key no longer opens
    /// the file. A cached key cannot hide that; the failure is the one quick
    /// unlock reports today, and nothing is stored.
    func testStaleStoredKeyFailsLikeBeforeAndStoresNothing() async throws {
        let data = try KDBXTestFixture.test.data(in: bundle)
        let oldKey = KDBXCrypto.compositeKey(password: "old password")
        let oldExpressKey = ExpressUnlockKey(
            binding: try XCTUnwrap(ExpressUnlockKey.binding(kdfParameters: try header(of: data).kdfParameters, compositeKey: oldKey)),
            transformedKey: SymmetricKey(size: .bits256)
        )
        let persisted = PersistedKeys()
        let vm = try makeViewModel(data: data, persisted: persisted) { _, _ in
            QuickUnlockKeys(storedKey: oldKey, expressKey: oldExpressKey)
        }

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .failed)
        XCTAssertNotEqual(vm.state, .unlocked)
        XCTAssertNil(vm.rootGroup)
        XCTAssertNil(persisted.last)
    }

    /// The YubiKey response is part of the composite key. Even a cached key
    /// that would open the file must not be used, or quick unlock would skip
    /// the YubiKey; and none is ever handed to storage.
    func testHardwareKeyDatabaseStillAsksTheYubiKeyAndStoresNoExpressKey() async throws {
        let fixture = KDBXTestFixture.challengeResponse
        let data = try fixture.data(in: bundle)
        let preKey = try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil)
        let fullKey = ChallengeResponseKey.compositeKey(
            preKey: preKey,
            response: YubiKeyEmulator.response(to: try ChallengeResponseKey.challenge(forDatabase: data))
        )
        let workingExpressKey = try expressKey(for: data, compositeKey: fullKey)
        let persisted = PersistedKeys()
        var responderCalls = 0
        let vm = try makeViewModel(
            data: data,
            hardwareKey: HardwareKeyConfiguration(transport: .nfc, slot: .two),
            persisted: persisted,
            biometricKeys: { _, _ in
                QuickUnlockKeys(storedKey: preKey, expressKey: workingExpressKey)
            },
            respond: { challenge, _ in
                responderCalls += 1
                return YubiKeyEmulator.response(to: challenge)
            }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .unlocked)
        XCTAssertEqual(responderCalls, 1)
        let keys = try XCTUnwrap(persisted.last)
        XCTAssertEqual(keys.storedKey, preKey)
        XCTAssertNil(keys.expressKey)
    }

    func testHardwareKeyDatabaseWithoutTheYubiKeyStaysLockedDespiteACachedKey() async throws {
        let fixture = KDBXTestFixture.challengeResponse
        let data = try fixture.data(in: bundle)
        let preKey = try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil)
        let fullKey = ChallengeResponseKey.compositeKey(
            preKey: preKey,
            response: YubiKeyEmulator.response(to: try ChallengeResponseKey.challenge(forDatabase: data))
        )
        let workingExpressKey = try expressKey(for: data, compositeKey: fullKey)
        let persisted = PersistedKeys()
        let vm = try makeViewModel(
            data: data,
            hardwareKey: HardwareKeyConfiguration(transport: .nfc, slot: .two),
            persisted: persisted,
            biometricKeys: { _, _ in
                QuickUnlockKeys(storedKey: preKey, expressKey: workingExpressKey)
            },
            respond: { _, _ in throw HardwareKeyError.timedOut }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(vm.rootGroup)
        XCTAssertNil(persisted.last)
    }

    func testHardwareKeyPasswordUnlockStoresNoExpressKey() async throws {
        let fixture = KDBXTestFixture.challengeResponse
        let persisted = PersistedKeys()
        let vm = try makeViewModel(
            data: try fixture.data(in: bundle),
            hardwareKey: HardwareKeyConfiguration(transport: .nfc, slot: .two),
            persisted: persisted,
            respond: { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        )

        await vm.unlock(password: fixture.password)

        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertEqual(persisted.last?.storedKey, try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil))
        XCTAssertNil(persisted.last?.expressKey)
    }

    // MARK: - Saves

    func testSaveStoresTheSavedVersionsKey() async throws {
        let savedKey = Self.savedVersionKey
        let expressSaves = ExpressKeySaves()
        let vm = try makeViewModel(
            data: try KDBXTestFixture.test.data(in: bundle),
            persisted: PersistedKeys(),
            localSave: { _, _, _, _, _, _, _ in .saved(newSHA512: Data("saved".utf8), expressKey: savedKey) },
            expressSaves: expressSaves
        )
        await vm.unlock(password: password)

        try await saveAnEdit(in: vm)

        XCTAssertEqual(expressSaves.keys, [savedKey])
    }

    /// Unlocked by password without the quick-unlock item being written (no
    /// biometrics enrolled, or an older key in it): the saved version's key
    /// would open what quick unlock cannot, so the stale item is only dropped.
    func testSaveWithoutAQuickUnlockItemHoldingTheSessionKeyOnlyDropsTheKey() async throws {
        let expressSaves = ExpressKeySaves()
        let vm = try makeViewModel(
            data: try KDBXTestFixture.test.data(in: bundle),
            persisted: PersistedKeys(),
            storesQuickUnlockKey: false,
            localSave: { _, _, _, _, _, _, _ in .saved(newSHA512: Data("saved".utf8), expressKey: Self.savedVersionKey) },
            expressSaves: expressSaves
        )
        await vm.unlock(password: password)

        try await saveAnEdit(in: vm)

        XCTAssertEqual(expressSaves.keys, [nil])
    }

    /// A rekey writes the file under another composite key: the item is
    /// dropped, and only once the quick-unlock item holds the new key does a
    /// later save store one again.
    func testRekeyDropsTheKeyAndLaterSavesFollowTheStoredKey() async throws {
        for storesNewKey in [true, false] {
            let expressSaves = ExpressKeySaves()
            let vm = try makeViewModel(
                data: try KDBXTestFixture.test.data(in: bundle),
                persisted: PersistedKeys(),
                localSave: { _, _, _, _, _, _, _ in .saved(newSHA512: Data("saved".utf8), expressKey: Self.savedVersionKey) },
                storedKeyPresenceCheck: { _ in storesNewKey },
                expressSaves: expressSaves
            )
            await vm.unlock(password: password)

            try await vm.changeMasterKey(
                newPassword: "rotated", newKeyFileData: nil, newKeyFileBookmarkData: nil, newKeyFileFilename: nil
            )
            XCTAssertEqual(expressSaves.keys, [nil], "storesNewKey: \(storesNewKey)")

            try await saveAnEdit(in: vm)
            XCTAssertEqual(
                expressSaves.keys,
                [nil, storesNewKey ? Self.savedVersionKey : nil],
                "storesNewKey: \(storesNewKey)"
            )
        }
    }

    func testEncryptionSettingsChangeDropsTheKey() async throws {
        let expressSaves = ExpressKeySaves()
        let vm = try makeViewModel(
            data: try KDBXTestFixture.test.data(in: bundle),
            persisted: PersistedKeys(),
            localSave: { _, _, _, _, _, _, _ in .saved(newSHA512: Data("saved".utf8), expressKey: Self.savedVersionKey) },
            expressSaves: expressSaves
        )
        await vm.unlock(password: password)

        try await vm.changeEncryptionSettings(cipher: nil, keyDerivation: .aesKDF(rounds: 1_000), isCompressed: nil)

        XCTAssertEqual(expressSaves.keys, [nil])
    }

    /// The Keychain side of a save: the key is stored only beside a
    /// quick-unlock item and never for a hardware-key database.
    func testStoringASavedVersionsKeyNeedsAQuickUnlockItemAndNoHardwareKey() throws {
        let url = try KDBXTestFixture.test.url(in: bundle)
        let reference = try TestDatabaseSupport.makeReference(for: url)
        var hardwareKeyReference = try TestDatabaseSupport.makeReference(for: url)
        hardwareKeyReference.hardwareKey = HardwareKeyConfiguration(transport: .nfc, slot: .two)
        addTeardownBlock {
            KeychainService.deleteCompositeKey(for: reference.id)
            KeychainService.deleteCompositeKey(for: hardwareKeyReference.id)
        }

        QuickUnlockKeychain.replaceExpressKey(with: Self.savedVersionKey, for: reference)
        XCTAssertFalse(KeychainService.hasExpressUnlockKey(for: reference.id), "No quick-unlock item")

        for storedReference in [reference, hardwareKeyReference] {
            do {
                try KeychainService.storeCompositeKey(SymmetricKey(size: .bits256), for: storedReference.id)
            } catch {
                throw XCTSkip("Keychain writes are unavailable in the current test host: \(error)")
            }
        }
        QuickUnlockKeychain.replaceExpressKey(with: Self.savedVersionKey, for: reference)
        XCTAssertTrue(KeychainService.hasExpressUnlockKey(for: reference.id))
        QuickUnlockKeychain.replaceExpressKey(with: Self.savedVersionKey, for: hardwareKeyReference)
        XCTAssertFalse(KeychainService.hasExpressUnlockKey(for: hardwareKeyReference.id))

        QuickUnlockKeychain.replaceExpressKey(with: nil, for: reference)
        XCTAssertFalse(KeychainService.hasExpressUnlockKey(for: reference.id))
        XCTAssertTrue(KeychainService.hasStoredKey(for: reference.id), "Dropping the express item keeps quick unlock")
    }

    // MARK: - Helpers

    private func makeViewModel(
        data: Data,
        hardwareKey: HardwareKeyConfiguration? = nil,
        persisted: PersistedKeys,
        storesQuickUnlockKey: Bool = true,
        biometricKeys: @escaping DatabaseViewModel.BiometricCompositeKeyOperation = { _, _ in
            throw LAError(.biometryNotAvailable)
        },
        respond: @escaping DatabaseViewModel.HardwareKeyResponseOperation = { _, _ in
            throw HardwareKeyError.unavailable
        },
        localSave: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, _, _, _, _ in
            throw SaveError.saveContextUnavailable
        },
        storedKeyPresenceCheck: @escaping DatabaseViewModel.StoredKeyPresenceCheck = { _ in false },
        expressSaves: ExpressKeySaves = ExpressKeySaves()
    ) throws -> DatabaseViewModel {
        let url = try KDBXTestFixture.test.url(in: bundle)
        var reference = try TestDatabaseSupport.makeReference(for: url)
        reference.hardwareKey = hardwareKey
        return DatabaseViewModel(
            databaseReference: reference,
            localDatabaseReadOperation: { _ in DatabaseViewModel.LocalDatabaseReadResult(url: url, data: data) },
            localSaveOperation: localSave,
            biometricCompositeKeyOperation: biometricKeys,
            quickUnlockKeyPersistOperation: { keys, _ in
                persisted.record(keys)
                return storesQuickUnlockKey
            },
            expressUnlockKeySaveOperation: { key, _ in expressSaves.record(key) },
            storedKeyPresenceCheck: storedKeyPresenceCheck,
            storedKeyStoreOperation: { _, _ in },
            storedKeyDeleteOperation: { _ in },
            hardwareKeyResponseOperation: respond,
            hardwareKeyTransportsProvider: { [.nfc] }
        )
    }

    nonisolated private static let savedVersionKey = ExpressUnlockKey(
        binding: Data(repeating: 9, count: 32),
        transformedKey: SymmetricKey(data: Data(repeating: 4, count: 32))
    )

    private func saveAnEdit(in vm: DatabaseViewModel) async throws {
        let rootGroup = try XCTUnwrap(vm.rootGroup)
        let draft = DatabaseDraft(
            rootGroup: rootGroup,
            meta: try XCTUnwrap(vm.currentMeta),
            sessionKey: try XCTUnwrap(vm.sessionKey)
        )
        vm.draft = try draft.apply(.createEntry(
            parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: rootGroup),
            draft: EntryDraftPayload(title: "Edited", password: "edited-secret")
        ))
        try await vm.save()
    }

    private func makeViewModel(
        data: Data,
        persisted: PersistedKeys,
        biometricKeys: @escaping DatabaseViewModel.BiometricCompositeKeyOperation
    ) throws -> DatabaseViewModel {
        try makeViewModel(data: data, hardwareKey: nil, persisted: persisted, biometricKeys: biometricKeys)
    }

    private func expressKey(for data: Data, compositeKey: SymmetricKey) throws -> ExpressUnlockKey {
        try XCTUnwrap(ExpressUnlock.parse(
            data: data, compositeKey: compositeKey, cachedKey: nil,
            sessionKey: SymmetricKey(size: .bits256), kdfPolicy: .mainApp
        ).keyToStore)
    }

    private func header(of data: Data) throws -> KDBXParser.Header {
        var reader = DataReader(data: data)
        _ = try KDBXParser.parseVersion(from: &reader)
        return try KDBXParser.parseHeader(&reader)
    }

    private func resave(_ data: Data, compositeKey: SymmetricKey) throws -> Data {
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp
        )
        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup, meta: parsed.meta, compositeKey: compositeKey,
            header: parsed.header, sessionKey: sessionKey, kdfPolicy: .mainApp
        )
    }
}

@MainActor
private final class ExpressKeySaves {
    private(set) var keys: [ExpressUnlockKey?] = []

    func record(_ key: ExpressUnlockKey?) {
        keys.append(key)
    }
}

@MainActor
private final class PersistedKeys {
    private(set) var last: QuickUnlockKeys?

    func record(_ keys: QuickUnlockKeys) {
        last = keys
    }
}
