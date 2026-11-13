import CryptoKit
import Foundation
import KDBXKit
import KDBXXML

enum SaveEffectScope: Sendable, Equatable { case databaseFile, sharedCopy, recoveryRecord }

enum SaveResult: Sendable, Equatable {
    /// The express key opens the exact installed ciphertext; hardware-key saves omit it.
    case saved(newSHA512: Data, expressKey: ExpressUnlockKey? = nil, localCommit: PendingLocalSaveStore.CommitReceipt? = nil)
    case committedWithoutConfirmedDurability(newSHA512: Data, expressKey: ExpressUnlockKey? = nil,
        localCommit: PendingLocalSaveStore.CommitReceipt? = nil, scope: SaveEffectScope = .databaseFile)
    case indeterminate(scope: SaveEffectScope)
    case conflict(remoteSHA512: Data, remoteData: Data)

    var warningScope: SaveEffectScope {
        switch self {
        case .committedWithoutConfirmedDurability(_, _, _, let scope), .indeterminate(let scope): scope
        case .saved, .conflict: .databaseFile
        }
    }

    var hasUnconfirmedDurability: Bool {
        if case .committedWithoutConfirmedDurability = self { return true }
        return false
    }
}

struct LocalSaveBeforeReplacementFailure: Error, LocalizedError {
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
}

struct SaveDurabilityWarning: Error, LocalizedError, Sendable {
    var scope: SaveEffectScope = .databaseFile
    var errorDescription: String? {
        switch scope {
        case .recoveryRecord: SaveBookkeepingWarning().localizedDescription
        case .databaseFile:
            String(localized: "The database file was replaced, but KeeForge could not confirm that the change will survive a system failure. The file already contains this change. If you changed the master key, use the new key. Keep a backup before closing the database.")
        case .sharedCopy:
            String(localized: "The shared copy contains this change, but KeeForge could not confirm its durability or automatic write-back. The original database has not been updated by this save. Open KeeForge to review pending changes and keep their encrypted snapshots.")
        }
    }
}

struct SaveUnknownOutcomeWarning: Error, LocalizedError, Sendable {
    let scope: SaveEffectScope
    var errorDescription: String? {
        switch scope {
        case .recoveryRecord: SaveBookkeepingWarning().localizedDescription
        case .databaseFile:
            String(localized: "KeeForge could not determine whether the database file was replaced. Do not repeat this operation. Keep the original and new master keys if you changed them, and use Database Details to recover the local save.")
        case .sharedCopy:
            String(localized: "KeeForge could not determine whether the shared copy was replaced. The original database was not updated by this save. Do not repeat this operation; open Database Details in KeeForge to recover its encrypted snapshot.")
        }
    }
}

struct SavePreReplacementRecoveryWarning: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        String(localized: "This save did not replace the database file, but KeeForge could not confirm that its recovery record was cleared. Open Database Details before trying a new operation.")
    }
}

struct RecoveryRecordWarning: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        String(localized: "The recovery operation took effect, but KeeForge could not confirm the durability of its final record. Review Database Details again; do not repeat the save.")
    }
}

struct SaveBookkeepingWarning: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        String(localized: "The database change is saved, but KeeForge could not confirm completion of its local recovery record. Do not repeat the save. Open Database Details to review any remaining recovery records or snapshots.")
    }
}

struct SaveAssociationWarning: Error, LocalizedError, Sendable {
    var durabilityUnconfirmed = false
    var errorDescription: String? {
        let association = String(localized: "The database already uses the new master key, but its key-file association could not be saved. Keep the new password and key file. Select the key file when unlocking, then set it again in Database Details.")
        return durabilityUnconfirmed ? association + " " + SaveDurabilityWarning().localizedDescription : association
    }
}

struct SaveConflict: Sendable, Equatable {
    let remoteSHA512: Data
    let remoteData: Data
}

/// The stored states a save is allowed to overwrite.
///
/// `openTimeSHA512` is what the session read when it opened the file — the
/// ordinary optimistic-concurrency baseline. `reconciledRemoteSHA512` is set
/// only by the merge flow, which has already read the diverged file and folded
/// it into the draft: those bytes are then just as safe to replace as the
/// open-time ones, and nothing else is. Anything else under the save is
/// content nobody has reconciled, and still conflicts.
struct SaveBaseline: Sendable, Equatable {
    let openTimeSHA512: Data
    let reconciledRemoteSHA512: Data?

    init(openTimeSHA512: Data, reconciledRemoteSHA512: Data? = nil) {
        self.openTimeSHA512 = openTimeSHA512
        self.reconciledRemoteSHA512 = reconciledRemoteSHA512
    }

    func covers(_ sha512: Data) -> Bool {
        sha512 == openTimeSHA512 || sha512 == reconciledRemoteSHA512
    }
}

/// Outer-header settings a save rewrites; a nil field keeps the file's value.
struct EncryptionSettingsChange: Sendable {
    var cipherID: Data?
    var kdfParameters: KDBXVariantMap?
    var compressionFlags: UInt32?

    func applied(to header: KDBXContainer.Header) -> KDBXContainer.Header {
        var header = header
        if let cipherID {
            header.cipherID = cipherID
        }
        if let kdfParameters {
            header.kdfParameters = kdfParameters
        }
        if let compressionFlags {
            header.compressionFlags = compressionFlags
        }
        return header
    }
}

enum SaveError: Error, LocalizedError, Equatable {
    case databaseIsReadOnly
    case databaseLocationUnavailable
    case saveContextUnavailable
    case reencryptionVerificationFailed
    case rekeyAppliedRemotely

    var errorDescription: String? {
        switch self {
        case .databaseIsReadOnly:
            String(localized: "This database is read-only.")
        case .databaseLocationUnavailable:
            String(localized: "The database file could not be located.")
        case .saveContextUnavailable:
            String(localized: "The database is not ready to save.")
        case .reencryptionVerificationFailed:
            String(localized: "The new database could not be verified after encryption.")
        case .rekeyAppliedRemotely:
            String(localized: "The new master key was uploaded, but the local copy could not be updated. The cloud file now requires the new master key.")
        }
    }
}

enum LocalDatabaseSaver {
    struct BackgroundTaskHandle: Sendable, Equatable {
        let identifier: UInt

        static let invalid = BackgroundTaskHandle(identifier: UInt.max)
    }

    struct ResolvedLocation: Sendable {
        let url: URL
        let usesSecurityScope: Bool
        /// The shared copy standing in for a bookmarked file this process
        /// cannot open. The app replaces that copy from the file, so the saved
        /// bytes are also kept as a pending local save for the app to merge.
        var awaitsWriteBack = false
    }

    enum ReplaceOutcome: Sendable, Equatable {
        case replaced(PendingLocalSaveStore.CommitReceipt? = nil)
        case replacedWithoutConfirmedDurability(PendingLocalSaveStore.CommitReceipt? = nil)
        case replacedWithUnconfirmedBookkeeping(PendingLocalSaveStore.CommitReceipt? = nil)
        case indeterminate
        case changed(currentData: Data)
    }

    struct ReplacementAuthorization: Sendable {
        let databaseID: UUID
        var token: PendingLocalSaveStore.Token?
        var expectedMasterKeyChangeAt: Date?
        var enforcesEpoch = true
        var isMasterKeyChange = false
        var association: PendingLocalSaveStore.KeyFileAssociation?
        var prepared: PendingLocalSaveStore.PreparedSource?
        var targetIsSharedCopy = false
        var storageIO = PendingLocalSaveStore.StorageIO()
    }

    struct Environment: Sendable {
        var beginBackgroundTask: @MainActor @Sendable (String) -> BackgroundTaskHandle
        var endBackgroundTask: @MainActor @Sendable (BackgroundTaskHandle) -> Void
        var resolveLocation: @Sendable (DatabaseReference) -> ResolvedLocation?
        var readData: @Sendable (URL) throws -> Data
        var extractHeader: @Sendable (Data, SymmetricKey, KDFExecutionPolicy) throws -> KDBXContainer.Header
        var encryptDraft: @Sendable (DatabaseDraft, SymmetricKey, KDBXContainer.Header, KDFExecutionPolicy) throws -> ExpressUnlock.Written
        var backupDirectoryURL: @Sendable (DatabaseReference) -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var writeBackup: @Sendable (Data, URL) throws -> Void
        var pruneBackups: @Sendable (DatabaseReference, Int) throws -> Void
        var now: @Sendable () -> Date
        /// Replaces the file only while it still hashes to the expected
        /// SHA-512 (nil: unconditionally), checked inside the same coordinated
        /// write so no other coordinated writer can land in between.
        var replaceFileAtomically: @Sendable (_ data: Data, _ url: URL, _ expectedSHA512: Data?, _ authorization: ReplacementAuthorization) throws -> ReplaceOutcome
        var cacheDatabaseCopy: @Sendable (Data, DatabaseReference) throws -> Void
        var pendingLocalStorageIO = PendingLocalSaveStore.StorageIO()
        var hasPendingLocalSaves: @Sendable (DatabaseReference) -> Bool

        static let live = Environment(
            beginBackgroundTask: { name in
                AppBackgroundTaskManager.begin(named: name)
            },
            endBackgroundTask: { handle in
                AppBackgroundTaskManager.end(handle)
            },
            resolveLocation: { reference in
                LocalDatabaseSaver.resolveLocation(for: reference)
            },
            readData: { url in
                try CoordinatedFileReader.readData(from: url)
            },
            extractHeader: { data, compositeKey, kdfPolicy in
                try KDBXParser.parse(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: SymmetricKey(size: .bits256),
                    kdfPolicy: kdfPolicy
                ).header
            },
            encryptDraft: { draft, compositeKey, header, kdfPolicy in
                try ExpressUnlock.write(draft: draft, compositeKey: compositeKey, header: header, kdfPolicy: kdfPolicy)
            },
            backupDirectoryURL: { reference in
                DatabaseListStore.databaseBackupDirectoryURL(for: reference)
            },
            createDirectory: { url in
                guard let anchor = AppGroupContainer.resolvedURL else { throw SaveError.databaseLocationUnavailable }
                try createDurableDirectory(at: url, anchor: anchor)
            },
            writeBackup: { data, url in
                guard let anchor = AppGroupContainer.resolvedURL else { throw SaveError.databaseLocationUnavailable }
                try writeAtomicallyAndDurably(data, to: url, directoryAnchor: anchor)
            },
            pruneBackups: { reference, count in
                try DatabaseListStore.pruneBackups(for: reference, keeping: count)
            },
            now: { .now },
            replaceFileAtomically: { data, url, expectedSHA512, authorization in
                try LocalDatabaseSaver.replaceFileAtomically(data, at: url, expectedSHA512: expectedSHA512, authorization: authorization)
            },
            cacheDatabaseCopy: { data, reference in
                if reference.isCloudBacked { try DatabaseListStore.cacheDatabaseCopy(data, for: reference) }
                else { try cacheLocalSnapshot(data, for: reference) }
            },
            hasPendingLocalSaves: { reference in
                PendingLocalSaveStore.hasSourcePayloads(for: reference.id)
            }
        )

        /// The AutoFill extension's saves, which go to the shared copy where
        /// `autoFillSavesAwaitWriteBack` says the extension cannot reach the
        /// file.
        static var autoFillExtension: Environment {
            var environment = live
            environment.resolveLocation = { reference in
                LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: reference)
                    ? LocalDatabaseSaver.sharedCopyLocation(for: reference)
                    : LocalDatabaseSaver.resolveLocation(for: reference)
            }
            return environment
        }
    }

    /// Saves an edited database draft back to encrypted storage.
    ///
    /// `newCompositeKey` rekeys the database: `compositeKey` still decrypts the
    /// on-disk file, `newCompositeKey` encrypts the saved bytes, and the result
    /// is verified to reopen with the new key before the file is replaced.
    ///
    /// `encryptionSettings` rewrites the header's cipher, KDF, or compression
    /// before encrypting, under the same reopen check.
    ///
    /// `reconciledRemoteSHA512` widens the overwrite gate by exactly one state
    /// — see `SaveBaseline`.
    ///
    /// - Important: The caller must keep `draft.writerSessionKey` alive until this async call
    ///   returns. `KDBXWriter` needs that session key to re-encrypt protected values while saving.
    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        reconciledRemoteSHA512: Data? = nil,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: SymmetricKey? = nil,
        encryptionSettings: EncryptionSettingsChange? = nil
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            reconciledRemoteSHA512: reconciledRemoteSHA512,
            kdfPolicy: kdfPolicy,
            newCompositeKey: newCompositeKey,
            encryptionSettings: encryptionSettings,
            environment: .live
        )
    }

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        reconciledRemoteSHA512: Data? = nil,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: SymmetricKey? = nil,
        encryptionSettings: EncryptionSettingsChange? = nil,
        environment: Environment
    ) async throws -> SaveResult {
        if reference.isReadOnly {
            throw LocalSaveBeforeReplacementFailure(underlying: SaveError.databaseIsReadOnly)
        }

        let backgroundTaskHandle = await environment.beginBackgroundTask("DatabaseSaving")
        defer {
            Task { @MainActor in
                environment.endBackgroundTask(backgroundTaskHandle)
            }
        }

        let authorization = ReplacementAuthorization(databaseID: reference.id, token: PendingLocalSaveStore.saveToken,
            expectedMasterKeyChangeAt: reference.lastMasterKeyChangeAt, enforcesEpoch: !reference.isCloudBacked,
            isMasterKeyChange: newCompositeKey != nil && !reference.isCloudBacked,
            association: PendingLocalSaveStore.keyFileAssociation, storageIO: environment.pendingLocalStorageIO)
        return try await Task.detached(priority: .utility) {
            do { return try saveOffMain(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                baseline: SaveBaseline(
                    openTimeSHA512: openTimeSHA512,
                    reconciledRemoteSHA512: reconciledRemoteSHA512
                ),
                kdfPolicy: kdfPolicy,
                newCompositeKey: newCompositeKey,
                encryptionSettings: encryptionSettings,
                environment: environment,
                authorization: authorization
            ) } catch let failure as LocalSaveBeforeReplacementFailure { throw failure }
            catch { throw LocalSaveBeforeReplacementFailure(underlying: error) }
        }.value
    }

    private static func saveOffMain(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        baseline: SaveBaseline,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: SymmetricKey?,
        encryptionSettings: EncryptionSettingsChange?,
        environment: Environment,
        authorization: ReplacementAuthorization
    ) throws -> SaveResult {
        guard let location = environment.resolveLocation(reference) else {
            throw SaveError.databaseLocationUnavailable
        }

        try PendingLocalSaveStore.validateWriteContext(for: reference.id, token: authorization.token,
            expectedMasterKeyChangeAt: authorization.expectedMasterKeyChangeAt, enforcesEpoch: authorization.enforcesEpoch,
            isMasterKeyChange: authorization.isMasterKeyChange, preparesSource: location.awaitsWriteBack)

        let hasSecurityScope = location.usesSecurityScope
            ? location.url.startAccessingSecurityScopedResource()
            : false
        defer {
            if hasSecurityScope {
                location.url.stopAccessingSecurityScopedResource()
            }
        }

        #if DEBUG
        var currentData = try environment.readData(location.url)
        if let conflictSequence = DatabaseListStore.consumeUITestLocalSaveConflictSequence() {
            currentData = try makeUITestConflictData(
                from: currentData,
                compositeKey: compositeKey,
                sequence: conflictSequence,
                kdfPolicy: kdfPolicy
            )
            var conflictAuthorization = authorization
            conflictAuthorization.token = nil
            conflictAuthorization.isMasterKeyChange = false
            _ = try environment.replaceFileAtomically(currentData, location.url, nil, conflictAuthorization)
        }
        #else
        let currentData = try environment.readData(location.url)
        #endif
        let currentSHA512 = FileDigest.sha512(currentData)
        guard baseline.covers(currentSHA512) else {
            return .conflict(remoteSHA512: currentSHA512, remoteData: currentData)
        }

        if authorization.enforcesEpoch {
            try PendingLocalSaveStore.validateReferenceAssociation(reference)
            try PendingLocalSaveStore.validateObservedKeyContext(for: reference.id,
                target: PendingLocalSaveStore.targetIdentity(at: location.url), sha512: currentSHA512,
                sharedCopy: location.awaitsWriteBack)
        }
        var header = try environment.extractHeader(currentData, compositeKey, kdfPolicy)
        guard header.formatVersion.requiresReadOnlyMode == false else {
            throw SaveError.databaseIsReadOnly
        }
        if let encryptionSettings {
            header = encryptionSettings.applied(to: header)
        }
        let writeKey = newCompositeKey ?? compositeKey
        let written = try environment.encryptDraft(draft, writeKey, header, kdfPolicy)
        let newData = written.data
        if newCompositeKey != nil || encryptionSettings != nil {
            do {
                _ = try environment.extractHeader(newData, writeKey, kdfPolicy)
            } catch {
                throw SaveError.reencryptionVerificationFailed
            }
        }

        let backupDirectoryURL = environment.backupDirectoryURL(reference)
        try environment.createDirectory(backupDirectoryURL)

        let backupURL = backupDirectoryURL.appendingPathComponent(
            backupFilename(for: environment.now()),
            isDirectory: false
        )
        try environment.writeBackup(currentData, backupURL)
        let scope: SaveEffectScope = location.awaitsWriteBack || reference.isCloudBacked ? .sharedCopy : .databaseFile
        let prepared = location.awaitsWriteBack
            ? try PendingLocalSaveStore.prepareSource(newData, for: reference.id,
                masterKeyChangedAt: reference.lastMasterKeyChangeAt, baseCacheSHA512: currentSHA512, io: environment.pendingLocalStorageIO)
            : nil
        var writeAuthorization = authorization
        writeAuthorization.prepared = prepared
        writeAuthorization.targetIsSharedCopy = location.awaitsWriteBack || reference.isCloudBacked
        let replaceOutcome: ReplaceOutcome
        do {
            replaceOutcome = try environment.replaceFileAtomically(newData, location.url, currentSHA512, writeAuthorization)
        } catch let failure as LocalSaveBeforeReplacementFailure { throw failure }
        catch {
            // An opaque adapter error after entering replacement is not proof of no effect.
            return .indeterminate(scope: scope)
        }
        let localCommit: PendingLocalSaveStore.CommitReceipt?
        let unconfirmed: Bool
        var warningScope = scope
        switch replaceOutcome {
        case .changed(let changedData):
            return .conflict(remoteSHA512: FileDigest.sha512(changedData), remoteData: changedData)
        case .indeterminate: return .indeterminate(scope: scope)
        case .replaced(let receipt): localCommit = receipt; unconfirmed = false
        case .replacedWithoutConfirmedDurability(let receipt): localCommit = receipt; unconfirmed = true
        case .replacedWithUnconfirmedBookkeeping(let receipt):
            localCommit = receipt; unconfirmed = true; warningScope = .recoveryRecord
        }
        var sourceAcceptanceUnconfirmed = false
        if let prepared, unconfirmed == false {
            switch PendingLocalSaveStore.activateSource(prepared, io: environment.pendingLocalStorageIO) {
            case .accepted: break
            case .acceptedWithoutConfirmedDurability, .notAccepted: sourceAcceptanceUnconfirmed = true
            }
        }
        // When the save location already IS the cache file (a cloud reference
        // without a bookmark resolves straight to it), the replace above was
        // the cache write; repeating it widens the window where a concurrent
        // cache read can mismatch its pending-upload marker.
        //
        // A pending local save keeps the shared copy too: that copy holds an
        // AutoFill save these bytes may not contain, and AutoFill reads it.
        // Whoever merges the pending saves refreshes the copy afterwards.
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        if canonicalPath(of: location.url) != canonicalPath(of: cacheURL),
           newCompositeKey != nil || environment.hasPendingLocalSaves(reference) == false {
            do {
                try environment.cacheDatabaseCopy(newData, reference)
            } catch {
                // The file is already replaced, so the save has succeeded. An
                // older copy must not keep answering AutoFill for it; with
                // none, AutoFill reads the file or fails until a copy is written.
                if reference.isCloudBacked { try? FileManager.default.removeItem(at: cacheURL) }
                else { invalidateOlderLocalCache(for: reference, installedSHA512: FileDigest.sha512(newData)) }
            }
        }
        try? environment.pruneBackups(reference, 5)

        if unconfirmed || sourceAcceptanceUnconfirmed {
            return .committedWithoutConfirmedDurability(
                newSHA512: FileDigest.sha512(newData),
                expressKey: reference.hardwareKey == nil ? written.expressKey : nil,
                localCommit: localCommit, scope: warningScope
            )
        }
        return .saved(
            newSHA512: FileDigest.sha512(newData),
            expressKey: reference.hardwareKey == nil ? written.expressKey : nil, localCommit: localCommit
        )
    }

    private static func resolveLocation(for reference: DatabaseReference) -> ResolvedLocation? {
        if let url = DatabaseListStore.resolveDatabaseURL(for: reference) {
            return ResolvedLocation(url: url, usesSecurityScope: true)
        }

        guard reference.bookmarkData == nil else {
            return nil
        }

        let cachedURL = DatabaseListStore.cachedDatabaseURL(for: reference) ?? DatabaseListStore.cacheLocation(for: reference)
        return ResolvedLocation(url: cachedURL, usesSecurityScope: false)
    }

    static func refreshLocalCache(_ data: Data, for reference: DatabaseReference) {
        do { try cacheLocalSnapshot(data, for: reference) }
        catch { invalidateOlderLocalCache(for: reference, installedSHA512: FileDigest.sha512(data)) }
    }

    static func cacheLocalSnapshot(_ data: Data, for reference: DatabaseReference) throws {
        guard let location = resolveLocation(for: reference), let anchor = AppGroupContainer.resolvedURL else {
            throw SaveError.databaseLocationUnavailable
        }
        let cache = DatabaseListStore.cacheLocation(for: reference)
        guard canonicalPath(of: cache) != canonicalPath(of: location.url) else { return }
        let access = location.usesSecurityScope && location.url.startAccessingSecurityScopedResource()
        defer { if access { location.url.stopAccessingSecurityScopedResource() } }
        let sha = FileDigest.sha512(data)
        var coordinatorError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: location.url, options: [], writingItemAt: cache,
            options: .forReplacing, error: &coordinatorError) { original, destination in
            result = Result {
                try PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: sha) {
                    guard FileDigest.sha512(try Data(contentsOf: original)) == sha else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                    try writeAtomicallyAndDurably(data, to: destination, directoryAnchor: anchor)
                }
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw SaveError.databaseLocationUnavailable }
        try result.get()
    }

    private static func invalidateOlderLocalCache(for reference: DatabaseReference, installedSHA512: Data) {
        guard let location = resolveLocation(for: reference) else { return }
        let cache = DatabaseListStore.cacheLocation(for: reference)
        guard canonicalPath(of: cache) != canonicalPath(of: location.url) else { return }
        let access = location.usesSecurityScope && location.url.startAccessingSecurityScopedResource()
        defer { if access { location.url.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: location.url, options: [], writingItemAt: cache,
            options: .forDeleting, error: &coordinatorError) { original, destination in
            try? PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: installedSHA512) {
                guard FileDigest.sha512(try Data(contentsOf: original)) == installedSHA512 else { return }
                let data = try Data(contentsOf: destination)
                guard FileDigest.sha512(data) != installedSHA512 else { return }
                try FileManager.default.removeItem(at: destination)
                try synchronizeDirectory(destination.deletingLastPathComponent())
            }
        }
    }

    static func keyTargetNeedsRecovery(for reference: DatabaseReference, snapshot: PendingLocalSaveStore.RecoverySnapshot) async -> Bool {
        guard snapshot.keyEvidence != nil else { return false }
        do {
            return try await CoordinatedFileReader.performBlocking(timeout: .seconds(15)) {
                let outcome = try observeOriginal(reference) { url in
                    try PendingLocalSaveStore.validateReferenceAssociation(reference)
                    try PendingLocalSaveStore.validateObservedKeyContext(for: reference.id,
                        target: PendingLocalSaveStore.targetIdentity(at: url), sha512: FileDigest.sha512(try Data(contentsOf: url)), sharedCopy: false)
                    return .resolved
                }
                return outcome != .resolved
            }
        } catch { return true }
    }

    static func exportKeyEpochCopy(
        _ evidence: PendingLocalSaveStore.KeyEpochEvidence, for reference: DatabaseReference
    ) async throws -> Data {
        let cache = DatabaseListStore.cacheLocation(for: reference)
        return try await CoordinatedFileReader.performBlocking(timeout: .seconds(15)) {
            var error: NSError?
            var result: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: cache, options: [], error: &error) { url in
                result = Result { try PendingLocalSaveStore.exportKeyEpochCopy(evidence, for: reference.id, at: url) }
            }
            if let error { throw error }
            guard let result else { throw SaveError.databaseLocationUnavailable }
            return try result.get()
        }
    }

    static func exportKeyEpochCopy(
        _ admission: PendingLocalSaveStore.Admission, for reference: DatabaseReference
    ) async throws -> Data {
        let cache = DatabaseListStore.cacheLocation(for: reference)
        return try await CoordinatedFileReader.performBlocking(timeout: .seconds(15)) {
            var error: NSError?
            var result: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: cache, options: [], error: &error) { url in
                result = Result { try PendingLocalSaveStore.exportKeyEpochCopy(admission, for: reference.id, at: url) }
            }
            if let error { throw error }
            guard let result else { throw SaveError.databaseLocationUnavailable }
            return try result.get()
        }
    }

    struct OriginalSnapshot: Sendable {
        let data: Data
        let target: PendingLocalSaveStore.TargetIdentity
        let sha512: Data
        init(data: Data, target: PendingLocalSaveStore.TargetIdentity) {
            self.data = data
            self.target = target
            sha512 = FileDigest.sha512(data)
        }
        var installed: PendingLocalSaveStore.InstalledTarget { .init(target: target, sha512: sha512) }
    }

    enum ExternalAdoptionFailure: Error, LocalizedError, Equatable {
        case attachmentsDiverged
        var errorDescription: String? {
            String(localized: "The two copies store their attachments differently. Your draft is unchanged. Export your unsaved changes before closing this session.")
        }
    }

    struct AuthenticatedExternalAdoption: Sendable {
        let owner: PendingLocalSaveStore.RecoverySnapshot
        let original: OriginalSnapshot
        let priorCiphertext: Data
        let rebased: DatabaseDraft
        let baseRoot: KPGroup
        let baseMeta: KPMeta
        let basePool: [Data]
        let lockCycleID: Int
        let draftRevision: Int
        fileprivate init(owner: PendingLocalSaveStore.RecoverySnapshot, original: OriginalSnapshot, priorCiphertext: Data,
            rebased: DatabaseDraft, baseRoot: KPGroup, baseMeta: KPMeta, basePool: [Data], lockCycleID: Int, draftRevision: Int) {
            self.owner = owner
            self.original = original
            self.priorCiphertext = priorCiphertext
            self.rebased = rebased
            self.baseRoot = baseRoot
            self.baseMeta = baseMeta
            self.basePool = basePool
            self.lockCycleID = lockCycleID
            self.draftRevision = draftRevision
        }
    }

    static func prepareAuthenticatedExternalAdoption(
        owner: PendingLocalSaveStore.RecoverySnapshot, priorCiphertext: Data, original: OriginalSnapshot,
        draft: DatabaseDraft, compositeKey: SymmetricKey, sessionKey: SymmetricKey, lockCycleID: Int, draftRevision: Int
    ) throws -> AuthenticatedExternalAdoption {
        guard let witness = owner.keyEvidence, witness.targetState.isConfirmed, !owner.needsRecovery,
              owner.entries.isEmpty, FileDigest.sha512(priorCiphertext) == witness.sha512 else {
            throw PendingLocalSaveStore.OwnershipError.recoveryRequired
        }
        _ = try KDBXParser.parse(data: priorCiphertext, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp)
        let current = try KDBXParser.parse(data: original.data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp)
        guard !current.header.formatVersion.requiresReadOnlyMode else { throw SaveError.databaseIsReadOnly }
        let rebased: DatabaseDraft
        if draft.isDirty {
            guard let localPool = draft.binaryPoolFields else { throw SaveError.saveContextUnavailable }
            let result = try KDBXMerger.merge(local: .init(rootGroup: draft.rootGroup, meta: draft.meta, binaryPoolFields: localPool),
                remote: .init(rootGroup: current.rootGroup, meta: current.meta, binaryPoolFields: current.header.innerHeaderBinaryFields), sessionKey: sessionKey)
            guard case .merged(let merged) = result else { throw ExternalAdoptionFailure.attachmentsDiverged }
            rebased = draft.rebased(baseRootGroup: current.rootGroup, baseMeta: current.meta,
                baseBinaryPoolFields: current.header.innerHeaderBinaryFields, mergedRootGroup: merged.rootGroup,
                mergedMeta: merged.meta, mergedBinaryPoolFields: localPool)
        } else {
            rebased = DatabaseDraft(rootGroup: current.rootGroup, meta: current.meta, sessionKey: sessionKey,
                binaryPoolFields: current.header.innerHeaderBinaryFields)
        }
        return AuthenticatedExternalAdoption(owner: owner, original: original, priorCiphertext: priorCiphertext, rebased: rebased,
            baseRoot: current.rootGroup, baseMeta: current.meta, basePool: current.header.innerHeaderBinaryFields,
            lockCycleID: lockCycleID, draftRevision: draftRevision)
    }

    static func readOriginalSnapshot(for reference: DatabaseReference) throws -> OriginalSnapshot {
        guard let location = resolveLocation(for: reference), !location.awaitsWriteBack else { throw SaveError.databaseLocationUnavailable }
        let access = location.usesSecurityScope && location.url.startAccessingSecurityScopedResource()
        defer { if access { location.url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var result: Result<OriginalSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: location.url, options: [], error: &error) { url in
            result = Result { OriginalSnapshot(data: try Data(contentsOf: url), target: try PendingLocalSaveStore.targetIdentity(at: url)) }
        }
        if let error { throw error }
        guard let result else { throw SaveError.databaseLocationUnavailable }
        return try result.get()
    }

    struct ExternalAdoptionCompletion: Sendable {
        let ownership: PendingLocalSaveStore.ResolutionOutcome
        let target: PendingLocalSaveStore.TargetCommit
    }

    static func adoptAuthenticatedTarget(
        _ authenticated: AuthenticatedExternalAdoption, reference: DatabaseReference,
        synchronizeParent: @Sendable (URL) throws -> Void = synchronizeDirectory,
        ownerIO: PendingLocalSaveStore.StorageIO = .init(), canCommit: @Sendable () -> Bool = { true }
    ) throws -> ExternalAdoptionCompletion {
        guard let location = resolveLocation(for: reference), !location.awaitsWriteBack else { throw SaveError.databaseLocationUnavailable }
        let access = location.usesSecurityScope && location.url.startAccessingSecurityScopedResource()
        defer { if access { location.url.stopAccessingSecurityScopedResource() } }
        var observed: PendingLocalSaveStore.TargetCommit?
        let resolution = try DatabaseListStore.withCurrentLocalReference(reference, target: location.url) { url in
            guard canCommit() else { throw CancellationError() }
            guard authenticated.owner.databaseID == reference.id else { throw SaveError.saveContextUnavailable }
            let (resolution, commit) = try PendingLocalSaveStore.adoptAuthenticatedTarget(authenticated,
                observeTarget: { .init(target: try PendingLocalSaveStore.targetIdentity(at: url), sha512: FileDigest.sha512(try Data(contentsOf: url))) },
                confirmDurability: {
                    do {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        try handle.synchronize()
                        try synchronizeParent(url.deletingLastPathComponent())
                        return true
                    } catch { return false }
                }, canCommit: canCommit, io: ownerIO)
            observed = commit
            return resolution
        }
        guard let observed else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        return ExternalAdoptionCompletion(ownership: resolution, target: observed)
    }

    static func captureTarget(for reference: DatabaseReference) throws -> PendingLocalSaveStore.TargetIdentity {
        guard let location = resolveLocation(for: reference) else { throw SaveError.databaseLocationUnavailable }
        let access = location.usesSecurityScope && location.url.startAccessingSecurityScopedResource()
        defer { if access { location.url.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var result: Result<PendingLocalSaveStore.TargetIdentity, Error>?
        NSFileCoordinator().coordinate(readingItemAt: location.url, options: [], error: &coordinatorError) { url in
            result = Result { try PendingLocalSaveStore.targetIdentity(at: url) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw SaveError.databaseLocationUnavailable }
        return try result.get()
    }

    static func completePendingMerge(
        _ receipt: PendingLocalSaveStore.CommitReceipt, reference: DatabaseReference,
        io: PendingLocalSaveStore.StorageIO = .init()
    ) -> PendingLocalSaveStore.ResolutionOutcome {
        do {
            return try observeOriginal(reference) { url in
                PendingLocalSaveStore.complete(receipt, observeTarget: {
                    (try PendingLocalSaveStore.targetIdentity(at: url), FileDigest.sha512(try Data(contentsOf: url)))
                }, io: io)
            }
        } catch { return .retainedForRecovery }
    }

    static func settleInstalledKeyChange(
        _ receipt: PendingLocalSaveStore.CommitReceipt, reference: DatabaseReference,
        associationProof: DatabaseListStore.DurableKeyFileAssociationReceipt,
        io: PendingLocalSaveStore.StorageIO = .init()
    ) throws -> PendingLocalSaveStore.ResolutionOutcome {
        try observeOriginal(reference) { url in
            PendingLocalSaveStore.settleKeyPublication(receipt, associationProof: associationProof,
                observeTarget: { (try PendingLocalSaveStore.targetIdentity(at: url), FileDigest.sha512(try Data(contentsOf: url))) }, io: io)
        }
    }

    static func confirmInstalledKeyChange(
        for reference: DatabaseReference, snapshot: PendingLocalSaveStore.RecoverySnapshot,
        beforePublication: @Sendable () throws -> Void = {}
    ) throws -> PendingLocalSaveStore.ResolutionOutcome {
        if let admission = snapshot.admission, case .masterKeyChange(let association) = admission.purpose,
           let association, let intended = admission.intendedSHA512 {
            var inspectedTarget: PendingLocalSaveStore.TargetIdentity?
            _ = try observeOriginal(reference) { url in
                try PendingLocalSaveStore.validateRecoveryAdmission(admission, for: reference.id)
                let target = try PendingLocalSaveStore.targetIdentity(at: url)
                guard target.canonicalPath == admission.target.canonicalPath, target.parent == admission.target.parent,
                      FileDigest.sha512(try Data(contentsOf: url)) == intended else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                inspectedTarget = target
                return .resolved
            }
            try beforePublication()
            guard case .durable(let proof) = DatabaseListStore.publishKeyFileAssociation(
                for: reference.id, operationID: admission.operationID, association: association, expectedTarget: inspectedTarget) else { throw SaveAssociationWarning() }
            return try observeOriginal(reference) { url in
                try PendingLocalSaveStore.validateRecoveryAdmission(admission, for: reference.id)
                guard FileDigest.sha512(try Data(contentsOf: url)) == intended else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                var receipt = PendingLocalSaveStore.CommitReceipt(databaseID: reference.id, admission: admission, sha512: intended)
                let installed = try PendingLocalSaveStore.targetIdentity(at: url)
                guard installed.canonicalPath == admission.target.canonicalPath, installed.parent == admission.target.parent else {
                    throw PendingLocalSaveStore.OwnershipError.targetChanged
                }
                receipt.targetCommit = .unconfirmed(.init(target: installed, sha512: intended))
                // Metadata recovery does not infer the original replacement's durability after a restart.
                return PendingLocalSaveStore.settleKeyPublication(receipt, associationProof: proof,
                    observeTarget: { (try PendingLocalSaveStore.targetIdentity(at: url), FileDigest.sha512(try Data(contentsOf: url))) })
            }
        }
        guard let evidence = snapshot.keyEvidence else { throw SaveAssociationWarning() }
        var inspectedTarget: PendingLocalSaveStore.TargetIdentity?
        _ = try observeOriginal(reference) { url in
            let target = try PendingLocalSaveStore.targetIdentity(at: url)
            let sha = FileDigest.sha512(try Data(contentsOf: url))
            guard (target == evidence.target && sha == evidence.sha512)
                || (target.canonicalPath == evidence.target.canonicalPath && target.parent == evidence.target.parent
                    && sha == evidence.pending?.sha512) else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
            inspectedTarget = target
            return .resolved
        }
        try beforePublication()
        guard case .durable(let proof) = DatabaseListStore.publishKeyFileAssociation(
            for: reference.id, operationID: evidence.epochID, association: evidence.association,
            expectedTarget: inspectedTarget, expectedWitness: evidence, expectedAssociationVersion: snapshot.associationVersion) else { throw SaveAssociationWarning() }
        return try observeOriginal(reference) { url in
            PendingLocalSaveStore.confirmKeyEvidence(evidence, for: reference.id, expectedAssociationVersion: snapshot.associationVersion, associationProof: proof,
                observeTarget: { (try PendingLocalSaveStore.targetIdentity(at: url), FileDigest.sha512(try Data(contentsOf: url))) })
        }
    }

    private static func observeOriginal(_ reference: DatabaseReference,
        _ observe: (URL) throws -> PendingLocalSaveStore.ResolutionOutcome
    ) throws -> PendingLocalSaveStore.ResolutionOutcome {
        guard let location = resolveLocation(for: reference), !location.awaitsWriteBack else { throw SaveError.databaseLocationUnavailable }
        let access = location.usesSecurityScope && location.url.startAccessingSecurityScopedResource()
        defer { if access { location.url.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var result: Result<PendingLocalSaveStore.ResolutionOutcome, Error>?
        NSFileCoordinator().coordinate(readingItemAt: location.url, options: [], error: &coordinatorError) { url in
            result = Result { try observe(url) }
        }
        if let coordinatorError {
            if case .success(let outcome)? = result {
                return outcome == .resolved ? .resolvedVisibleWithoutConfirmedDurability : outcome
            }
            throw coordinatorError
        }
        guard let result else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        return try result.get()
    }

    /// Whether the AutoFill extension saves this database to the shared copy
    /// and leaves the file to the app. True on the Mac for a bookmarked local
    /// database: the extension's sandbox cannot open the file behind the app's
    /// bookmark. The iOS extension opens that file itself.
    static func autoFillSavesAwaitWriteBack(for reference: DatabaseReference) -> Bool {
        #if os(macOS)
        reference.isCloudBacked == false && reference.bookmarkData != nil
        #else
        false
        #endif
    }

    static func sharedCopyLocation(for reference: DatabaseReference) -> ResolvedLocation {
        ResolvedLocation(
            url: DatabaseListStore.cacheLocation(for: reference),
            usesSecurityScope: false,
            awaitsWriteBack: true
        )
    }

    private static func canonicalPath(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func backupFilename(for date: Date) -> String {
        let utcCalendar = Calendar(identifier: .gregorian)
        let utcTimeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = utcCalendar.dateComponents(in: utcTimeZone, from: date)
        let microseconds = (components.nanosecond ?? 0) / 1_000

        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%06d.kdbx",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            microseconds
        )
    }

    #if DEBUG
    private static func makeUITestConflictData(
        from data: Data,
        compositeKey: SymmetricKey,
        sequence: Int,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Data {
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parse(
            data: data,
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            kdfPolicy: kdfPolicy
        )
        let conflictMarkerParent = parsed.rootGroup.entries.isEmpty && parsed.rootGroup.groups.count == 1
            ? parsed.rootGroup.groups[0]
            : parsed.rootGroup
        conflictMarkerParent.entries.append(
            KPEntry(
                title: "UI Test Conflict \(sequence)",
                notes: "Injected save conflict \(sequence)"
            )
        )
        var header = parsed.header
        if DatabaseListStore.uiTestLocalSaveConflictDivergesPool {
            // Leading byte is the pool entry's flags field; the rest is filler.
            header.innerHeaderBinaryFields.append(
                Data([0x00]) + Data("keeforge-ui-test-divergent-binary-\(sequence)".utf8)
            )
        }
        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            header: header,
            sessionKey: sessionKey,
            kdfPolicy: kdfPolicy
        )
    }
    #endif

    struct ReplacementIO: Sendable {
        var stage: @Sendable (Data, URL) throws -> Void = { try writeAtomicallyAndDurably($0, to: $1) }
        var synchronize: @Sendable (URL) throws -> Void = synchronizeDirectory
        // Models a file-provider error reported after its coordinated accessor returns.
        var coordinationCompletion: @Sendable () throws -> Void = {}
    }

    static func replaceFileAtomically(
        _ data: Data, at url: URL, expectedSHA512: Data?,
        authorization: ReplacementAuthorization? = nil, io: ReplacementIO = .init()
    ) throws -> ReplaceOutcome {
        let manager = FileManager.default
        let intended = FileDigest.sha512(data)
        var coordinatorError: NSError?
        var result: Result<ReplaceOutcome, Error>?
        var enteredReplacement = false
        var observedEffect: PendingLocalSaveStore.TargetCommit?
        var targetWrite: PendingLocalSaveStore.TargetWriteToken?

        func access(readingURL: URL?, writingURL: URL) {
            result = Result {
                do {
                    if let expectedSHA512 {
                        let current = try Data(contentsOf: readingURL ?? writingURL)
                        guard FileDigest.sha512(current) == expectedSHA512 else { return .changed(currentData: current) }
                    }
                    let stagingDirectory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                        appropriateFor: writingURL, create: true)
                    defer { try? manager.removeItem(at: stagingDirectory) }
                    let staged = stagingDirectory.appendingPathComponent("keeforge-save-\(UUID().uuidString)")
                    try io.stage(data, staged)
                    let perform: (PendingLocalSaveStore.CommitReceipt?) throws -> ReplaceOutcome = { receipt in
                        enteredReplacement = true
                        var replacementThrew = false
                        do {
                            _ = try manager.replaceItemAt(writingURL, withItemAt: staged, backupItemName: nil, options: [])
                        } catch { replacementThrew = true }
                        guard let installed = try? Data(contentsOf: writingURL), FileDigest.sha512(installed) == intended,
                              let identity = try? PendingLocalSaveStore.targetIdentity(at: writingURL) else { return .indeterminate }
                        var installedReceipt = receipt
                        if installedReceipt == nil, let authorization {
                            installedReceipt = .init(databaseID: authorization.databaseID, sha512: intended)
                        }
                        var durable = false
                        if !replacementThrew {
                            do { try io.synchronize(writingURL.deletingLastPathComponent()); durable = true } catch {}
                        }
                        let installedTarget = PendingLocalSaveStore.InstalledTarget(target: identity, sha512: intended)
                        observedEffect = durable ? .confirmed(installedTarget) : .unconfirmed(installedTarget)
                        installedReceipt?.targetCommit = observedEffect
                        installedReceipt?.encryptedSnapshot = data
                        return durable ? .replaced(installedReceipt) : .replacedWithoutConfirmedDurability(installedReceipt)
                    }
                    if let authorization {
                        let authorized = try PendingLocalSaveStore.withWriteAuthorization(
                            for: authorization.databaseID, token: authorization.token,
                            expectedMasterKeyChangeAt: authorization.expectedMasterKeyChangeAt,
                            enforcesEpoch: authorization.enforcesEpoch, isMasterKeyChange: authorization.isMasterKeyChange,
                            association: authorization.association, prepared: authorization.prepared,
                            intendedSHA512: intended, observeTarget: {
                                let bytes = try Data(contentsOf: readingURL ?? writingURL)
                                if let expectedSHA512, FileDigest.sha512(bytes) != expectedSHA512 {
                                    throw CoordinatedConflict(currentData: bytes)
                                }
                                return (try PendingLocalSaveStore.targetIdentity(at: writingURL), FileDigest.sha512(bytes))
                            }, targetIsSharedCopy: authorization.targetIsSharedCopy,
                            io: authorization.storageIO, perform
                        )
                        targetWrite = authorized.targetWrite
                        return authorized.value
                    }
                    return try perform(nil)
                } catch let conflict as CoordinatedConflict { return .changed(currentData: conflict.currentData) }
                catch let failure as LocalSaveBeforeReplacementFailure { throw failure }
                catch {
                    if enteredReplacement { return .indeterminate }
                    if let failure = error as? PendingLocalSaveStore.AdmissionPublicationFailure {
                        let release = PendingLocalSaveStore.releaseAfterProvenNoReplacement(failure.token,
                            io: authorization?.storageIO ?? .init())
                        if release != .resolved {
                            throw LocalSaveBeforeReplacementFailure(underlying: SavePreReplacementRecoveryWarning())
                        }
                    }
                    throw LocalSaveBeforeReplacementFailure(underlying: error)
                }
            }
        }
        let coordinator = NSFileCoordinator()
        if expectedSHA512 != nil {
            coordinator.coordinate(readingItemAt: url, options: [], writingItemAt: url,
                options: .forReplacing, error: &coordinatorError) { reading, writing in access(readingURL: reading, writingURL: writing) }
        } else {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) {
                access(readingURL: nil, writingURL: $0)
            }
        }
        func finalize(_ outcome: ReplaceOutcome, coordinationFailed: Bool = false) -> ReplaceOutcome {
            var finalOutcome = outcome
            if coordinationFailed {
                observedEffect = observedEffect?.withoutConfirmation
                switch outcome {
                case .replaced(var receipt), .replacedWithoutConfirmedDurability(var receipt), .replacedWithUnconfirmedBookkeeping(var receipt):
                    receipt?.targetCommit = receipt?.targetCommit?.withoutConfirmation
                    finalOutcome = .replacedWithoutConfirmedDurability(receipt)
                case .indeterminate, .changed: break
                }
            }
            if let targetWrite, let observedEffect {
                var confirmationError: NSError?
                var resolution = PendingLocalSaveStore.ResolutionOutcome.retainedForRecovery
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &confirmationError) { target in
                    resolution = PendingLocalSaveStore.finishTargetWrite(targetWrite, commit: observedEffect, observeTarget: {
                        (try PendingLocalSaveStore.targetIdentity(at: target), FileDigest.sha512(try Data(contentsOf: target)))
                    }, io: authorization?.storageIO ?? .init())
                }
                if resolution != .resolved || confirmationError != nil, case .replaced(let receipt) = finalOutcome {
                    return .replacedWithUnconfirmedBookkeeping(receipt)
                }
            }
            return finalOutcome
        }
        do {
            if let coordinatorError { throw coordinatorError }
            try io.coordinationCompletion()
        } catch {
            if case .success(let outcome)? = result { return finalize(outcome, coordinationFailed: true) }
            if enteredReplacement { return .indeterminate }
            throw LocalSaveBeforeReplacementFailure(underlying: error)
        }
        guard let result else {
            if enteredReplacement { return .indeterminate }
            throw LocalSaveBeforeReplacementFailure(underlying: CocoaError(.fileWriteUnknown))
        }
        return finalize(try result.get())
    }

    private struct CoordinatedConflict: Error { let currentData: Data }

}

private enum AppBackgroundTaskManager {
    @MainActor
    static func begin(named name: String) -> LocalDatabaseSaver.BackgroundTaskHandle {
        guard Bundle.main.bundleURL.pathExtension != "appex",
              let application = sharedApplication() else {
            return .invalid
        }

        let selector = NSSelectorFromString("beginBackgroundTaskWithName:expirationHandler:")
        guard application.responds(to: selector) else {
            return .invalid
        }

        typealias BeginMethod = @convention(c) (AnyObject, Selector, NSString, AnyObject?) -> UInt
        let method = unsafeBitCast(application.method(for: selector), to: BeginMethod.self)
        let expirationHandler: @convention(block) () -> Void = {}
        let identifier = method(application, selector, name as NSString, expirationHandler as AnyObject)
        return .init(identifier: identifier)
    }

    @MainActor
    static func end(_ handle: LocalDatabaseSaver.BackgroundTaskHandle) {
        guard handle != .invalid,
              let application = sharedApplication() else {
            return
        }

        let selector = NSSelectorFromString("endBackgroundTask:")
        guard application.responds(to: selector) else {
            return
        }

        typealias EndMethod = @convention(c) (AnyObject, Selector, UInt) -> Void
        let method = unsafeBitCast(application.method(for: selector), to: EndMethod.self)
        method(application, selector, handle.identifier)
    }

    @MainActor
    private static func sharedApplication() -> NSObject? {
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type else {
            return nil
        }

        let selector = NSSelectorFromString("sharedApplication")
        guard applicationClass.responds(to: selector),
              let application = applicationClass.perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }

        return application
    }
}
