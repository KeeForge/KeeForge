import CryptoKit
import Foundation
import KDBXKit

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
    var token: PendingLocalSaveStore.Token? = nil
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
    enum Reason: Sendable, Equatable { case associationUnconfirmed, authorityChanged }
    var durabilityUnconfirmed = false
    var reason: Reason = .associationUnconfirmed
    var errorDescription: String? {
        if reason == .authorityChanged {
            return String(localized: "KeeForge could not verify the key record for this completion. Reopen the database before another operation, and review Database Details if recovery is still required.")
        }
        let association = String(localized: "The database already uses the new master key, but KeeForge could not confirm its key-file association or local key record. Keep the new password and key file and open Database Details to recover.")
        return durabilityUnconfirmed ? association + " " + SaveDurabilityWarning().localizedDescription : association
    }
}

struct SaveConflict: Sendable, Equatable {
    let remoteSHA512: Data
    let remoteData: Data
    var requiresLocalRecovery = false
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
        var bookmarkRenewal: DatabaseListStore.DatabaseBookmarkRenewal? = nil
    }

    enum ReplaceOutcome: Sendable, Equatable {
        case replaced(PendingLocalSaveStore.CommitReceipt? = nil)
        case replacedWithoutConfirmedDurability(PendingLocalSaveStore.CommitReceipt? = nil)
        case replacedWithUnconfirmedBookkeeping(PendingLocalSaveStore.CommitReceipt? = nil)
        case indeterminate
        case changed(currentData: Data)
    }

    struct SecurityScopeIO: Sendable {
        var begin: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var end: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    }
    @TaskLocal private static var scopedOriginalLocation: ResolvedLocation?

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
        var localPublicationFailure: @Sendable (String, Error) -> Void = { _, _ in }
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
                LocalDatabaseSaver.resolveLocation(for: reference, renewBookmark: false)
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
                    : LocalDatabaseSaver.resolveLocation(for: reference, renewBookmark: false)
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
            ) } catch let failure as LocalSaveBeforeReplacementFailure {
                environment.localPublicationFailure("save-before-replacement", failure.underlying)
                throw failure
            }
            catch let failure as PendingLocalSaveStore.AdmissionPublicationFailure {
                environment.localPublicationFailure("save-admission-publication", failure)
                throw LocalSaveBeforeReplacementFailure(underlying: SavePreReplacementRecoveryWarning(token: failure.token))
            }
            catch {
                environment.localPublicationFailure("save-preparation", error)
                throw LocalSaveBeforeReplacementFailure(underlying: error)
            }
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
        var ordinaryToken: PendingLocalSaveStore.Token?
        if authorization.enforcesEpoch, authorization.token == nil, !authorization.isMasterKeyChange, !location.awaitsWriteBack {
            do { ordinaryToken = try admitOrdinarySave(reference: reference, location: location,
                baseline: currentSHA512, io: environment.pendingLocalStorageIO) }
            catch let conflict as CoordinatedConflict { return .conflict(remoteSHA512: FileDigest.sha512(conflict.currentData), remoteData: conflict.currentData) }
        } else { ordinaryToken = nil }
        var replacementMayHaveStarted = false
        func releaseProvenUncommittedAdmission() throws {
            guard let token = ordinaryToken else { return }
            ordinaryToken = nil
            guard PendingLocalSaveStore.releaseAfterProvenNoReplacement(token, io: environment.pendingLocalStorageIO) == .resolved else {
                throw LocalSaveBeforeReplacementFailure(underlying: SavePreReplacementRecoveryWarning())
            }
        }
        do {
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
            if let ordinaryToken { writeAuthorization.token = ordinaryToken }
            writeAuthorization.targetIsSharedCopy = location.awaitsWriteBack || reference.isCloudBacked
            let replaceOutcome: ReplaceOutcome
            do {
                replacementMayHaveStarted = true
                replaceOutcome = try environment.replaceFileAtomically(newData, location.url, currentSHA512, writeAuthorization)
            } catch let failure as LocalSaveBeforeReplacementFailure {
                replacementMayHaveStarted = false
                throw failure
            }
            catch {
                // An opaque adapter error after entering replacement is not proof of no effect.
                return .indeterminate(scope: scope)
            }
            let localCommit: PendingLocalSaveStore.CommitReceipt?
            var unconfirmed: Bool
            var warningScope = scope
            switch replaceOutcome {
            case .changed(let changedData):
                replacementMayHaveStarted = false
                try releaseProvenUncommittedAdmission()
                return .conflict(remoteSHA512: FileDigest.sha512(changedData), remoteData: changedData)
            case .indeterminate: return .indeterminate(scope: scope)
            case .replaced(let receipt): localCommit = receipt; unconfirmed = false
            case .replacedWithoutConfirmedDurability(let receipt): localCommit = receipt; unconfirmed = true
            case .replacedWithUnconfirmedBookkeeping(let receipt):
                localCommit = receipt; unconfirmed = true; warningScope = .recoveryRecord
            }
            if ordinaryToken != nil, !unconfirmed {
                let completion = $scopedOriginalLocation.withValue(location) {
                    localCommit.map { completePendingMerge($0, reference: reference, io: environment.pendingLocalStorageIO) }
                        ?? .retainedForRecovery
                }
                if completion != .resolved { unconfirmed = true; warningScope = .recoveryRecord }
            }
            if ordinaryToken != nil, unconfirmed, let localCommit {
                var observationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: location.url,
                    options: [], error: &observationError) { target in
                    _ = PendingLocalSaveStore.recordKnownOrdinaryCommit(localCommit, observeTarget: {
                        (try PendingLocalSaveStore.targetIdentity(at: target), FileDigest.sha512(try Data(contentsOf: target)))
                    }, io: environment.pendingLocalStorageIO)
                }
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
               newCompositeKey != nil || localCommit?.purpose == .ordinarySave || environment.hasPendingLocalSaves(reference) == false {
                $scopedOriginalLocation.withValue(location) {
                    PendingLocalSaveStore.$cacheCommit.withValue(localCommit) {
                        do {
                            try environment.cacheDatabaseCopy(newData, reference)
                        } catch {
                            // The file is already replaced, so the save has succeeded. An
                            // older copy must not keep answering AutoFill for it; with
                            // none, AutoFill reads the file or fails until a copy is written.
                            environment.localPublicationFailure("save-cache", error)
                            if reference.isCloudBacked { try? FileManager.default.removeItem(at: cacheURL) }
                            else { invalidateOlderLocalCache(for: reference, installedSHA512: FileDigest.sha512(newData),
                                onFailure: environment.localPublicationFailure) }
                        }
                    }
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
        } catch {
            if !replacementMayHaveStarted { try releaseProvenUncommittedAdmission() }
            throw error
        }
    }

    private static func admitOrdinarySave(
        reference: DatabaseReference, location: ResolvedLocation, baseline: Data, io: PendingLocalSaveStore.StorageIO
    ) throws -> PendingLocalSaveStore.Token {
        var error: NSError?
        var result: Result<PendingLocalSaveStore.Token, Error>?
        NSFileCoordinator().coordinate(readingItemAt: location.url, options: [], error: &error) { target in
            result = Result {
                let bytes = try Data(contentsOf: target)
                guard FileDigest.sha512(bytes) == baseline else { throw CoordinatedConflict(currentData: bytes) }
                return try PendingLocalSaveStore.admit([], for: reference.id,
                    target: PendingLocalSaveStore.targetIdentity(at: target), baseline: baseline,
                    masterKeyChangedAt: reference.lastMasterKeyChangeAt, purpose: .ordinarySave, io: io)
            }
        }
        do {
            if let error { throw error }
            try io.admissionCoordinationCompletion()
        } catch {
            if case .success(let token) = result { throw PendingLocalSaveStore.AdmissionPublicationFailure(token: token, underlying: error) }
            if case .failure(let failure as PendingLocalSaveStore.AdmissionPublicationFailure) = result { throw failure }
            throw error
        }
        guard let result else { throw SaveError.databaseLocationUnavailable }
        return try result.get()
    }

    static func resolveLocation(for reference: DatabaseReference, renewBookmark: Bool = false) -> ResolvedLocation? {
        var renewal: DatabaseListStore.DatabaseBookmarkRenewal?
        if let url = DatabaseListStore.resolveDatabaseURL(for: reference, renewBookmark: renewBookmark, onBookmarkRenewal: { renewal = $0 }) {
            return ResolvedLocation(url: url, usesSecurityScope: true, bookmarkRenewal: renewal)
        }

        guard reference.bookmarkData == nil else {
            return nil
        }

        let cachedURL = DatabaseListStore.cachedDatabaseURL(for: reference) ?? DatabaseListStore.cacheLocation(for: reference)
        return ResolvedLocation(url: cachedURL, usesSecurityScope: false)
    }

    private static func committedCacheTarget(for reference: DatabaseReference, sha512: Data) -> PendingLocalSaveStore.TargetIdentity? {
        guard let commit = PendingLocalSaveStore.cacheCommit, commit.databaseID == reference.id,
              commit.sha512 == sha512, let bytes = commit.encryptedSnapshot, FileDigest.sha512(bytes) == sha512,
              let admission = commit.admission, admission.observedMasterKeyChangeAt == reference.lastMasterKeyChangeAt,
              let installed = commit.installedTarget, installed.canonicalPath == admission.target.canonicalPath,
              installed.parent == admission.target.parent else { return nil }
        return installed
    }

    enum CachePublicationStage: String, Sendable {
        case lease, location, reference, owner, target, write, coordination
    }

    static func cacheLocalSnapshot(
        _ data: Data, for reference: DatabaseReference, lease capturedLease: PendingLocalSaveStore.CacheReadLease? = nil,
        allowNewReference: Bool = false, legacyMigrationSource: URL? = nil,
        onFailure: (CachePublicationStage, Error) -> Void = { _, _ in },
        scopeIO: SecurityScopeIO = .init()
    ) throws {
        var stage = CachePublicationStage.lease
        do {
            var lease = try capturedLease ?? PendingLocalSaveStore.captureCacheReadLease(for: reference)
            guard lease.reference.matches(reference) else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
            stage = .location
            let sha = FileDigest.sha512(data)
            let committedTarget = committedCacheTarget(for: reference, sha512: sha)
            let resolved: ResolvedLocation?
            if let scoped = scopedOriginalLocation {
                resolved = scoped
            } else if let legacyMigrationSource {
                guard lease.epochID == nil, let legacy = SharedVaultStore.legacyCachedDatabaseURL,
                      canonicalPath(of: legacy) == canonicalPath(of: legacyMigrationSource) else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
                resolved = ResolvedLocation(url: legacyMigrationSource, usesSecurityScope: false)
            } else { resolved = resolveLocation(for: reference, renewBookmark: false) }
            guard let location = resolved, let anchor = AppGroupContainer.resolvedURL else { throw SaveError.databaseLocationUnavailable }
            if lease.bookmarkRenewal == nil { lease.bookmarkRenewal = location.bookmarkRenewal }
            let cache = DatabaseListStore.cacheLocation(for: reference)
            let primary = canonicalPath(of: cache) == canonicalPath(of: location.url)
            if primary && !allowNewReference { return }
            let access = location.usesSecurityScope && scopeIO.begin(location.url)
            defer { if access { scopeIO.end(location.url) } }
            stage = .reference
            try DatabaseListStore.withLocalCacheReference(reference, allowNewReference: allowNewReference, lease: lease) {
                var error: NSError?
                var result: Result<Void, Error>?
                func publish(original: URL?, destination: URL) {
                    result = Result {
                        stage = .owner
                        try PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: sha, lease: lease) {
                            stage = .target
                            if let original {
                                if let committedTarget {
                                    guard try PendingLocalSaveStore.targetIdentity(at: original) == committedTarget else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                                }
                                if let renewal = lease.bookmarkRenewal {
                                    guard try PendingLocalSaveStore.targetIdentity(at: original) == renewal.target else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                                }
                                guard FileDigest.sha512(try Data(contentsOf: original)) == sha else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                            } else {
                                guard !FileManager.default.fileExists(atPath: destination.path) else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
                            }
                            stage = .write
                            try writeAtomicallyAndDurably(data, to: destination, directoryAnchor: anchor)
                        }
                    }
                }
                let coordinator = NSFileCoordinator()
                if primary {
                    coordinator.coordinate(writingItemAt: cache, options: .forReplacing, error: &error) { publish(original: nil, destination: $0) }
                } else {
                    coordinator.coordinate(readingItemAt: location.url, options: [], writingItemAt: cache, options: .forReplacing,
                        error: &error) { publish(original: $0, destination: $1) }
                }
                if let error { stage = .coordination; throw error }
                guard let result else { throw SaveError.databaseLocationUnavailable }
                try result.get()
            }
        } catch {
            onFailure(stage, error)
            throw error
        }
    }

    private static func invalidateOlderLocalCache(
        for reference: DatabaseReference, installedSHA512: Data,
        onFailure: (String, Error) -> Void = { _, _ in }, scopeIO: SecurityScopeIO = .init()
    ) {
        var stage = "invalidate-lease"
        do {
            var lease = try PendingLocalSaveStore.captureCacheReadLease(for: reference)
            stage = "invalidate-location"
            let committedTarget = committedCacheTarget(for: reference, sha512: installedSHA512)
            let location = scopedOriginalLocation ?? resolveLocation(for: reference, renewBookmark: false)
            guard let location else { throw SaveError.databaseLocationUnavailable }
            if lease.bookmarkRenewal == nil { lease.bookmarkRenewal = location.bookmarkRenewal }
            let cache = DatabaseListStore.cacheLocation(for: reference)
            guard canonicalPath(of: cache) != canonicalPath(of: location.url) else { return }
            let access = location.usesSecurityScope && scopeIO.begin(location.url)
            defer { if access { scopeIO.end(location.url) } }
            stage = "invalidate-reference"
            try DatabaseListStore.withLocalCacheReference(reference, allowNewReference: false, lease: lease) {
                var coordinatorError: NSError?
                var result: Result<Void, Error>?
                NSFileCoordinator().coordinate(readingItemAt: location.url, options: [], writingItemAt: cache,
                    options: .forDeleting, error: &coordinatorError) { original, destination in
                    result = Result {
                        stage = "invalidate-owner"
                        try PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: installedSHA512, lease: lease) {
                            stage = "invalidate-target"
                            if let committedTarget {
                                guard try PendingLocalSaveStore.targetIdentity(at: original) == committedTarget else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                            }
                            if let renewal = lease.bookmarkRenewal {
                                guard try PendingLocalSaveStore.targetIdentity(at: original) == renewal.target else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                            }
                            guard FileDigest.sha512(try Data(contentsOf: original)) == installedSHA512 else {
                                throw PendingLocalSaveStore.OwnershipError.targetChanged
                            }
                            let data = try Data(contentsOf: destination)
                            guard FileDigest.sha512(data) != installedSHA512 else { return }
                            stage = "invalidate-delete"
                            try FileManager.default.removeItem(at: destination)
                            try synchronizeDirectory(destination.deletingLastPathComponent())
                        }
                    }
                }
                if let coordinatorError { stage = "invalidate-coordination"; throw coordinatorError }
                guard let result else { throw SaveError.databaseLocationUnavailable }
                try result.get()
            }
        } catch { onFailure(stage, error) }
    }

    static func retireSettledKeyWitness(for reference: DatabaseReference, io: PendingLocalSaveStore.StorageIO = .init()) -> PendingLocalSaveStore.ResolutionOutcome {
        do {
            let snapshot = try PendingLocalSaveStore.recovery(for: reference.id)
            guard let evidence = snapshot.keyEvidence else { return .resolved }
            if evidence.targetState.isReadyToRetire {
                return PendingLocalSaveStore.resumeCertifiedRetirement(evidence, for: reference.id)
            }
            guard evidence.targetState.isConfirmed, !snapshot.needsRecovery, snapshot.entries.isEmpty else { return .resolved }
            return DatabaseListStore.certifySettledKeyWitness(for: reference, evidence: evidence, io: io)
        } catch { return .retainedForRecovery }
    }

    static func keyTargetNeedsRecovery(for reference: DatabaseReference, snapshot: PendingLocalSaveStore.RecoverySnapshot) async -> Bool {
        guard let evidence = snapshot.keyEvidence else { return false }
        if evidence.targetState.isReadyToRetire {
            return await Task.detached { PendingLocalSaveStore.resumeCertifiedRetirement(evidence, for: reference.id) == .retainedForRecovery }.value
        }
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

    static func captureTarget(for reference: DatabaseReference) throws -> PendingLocalSaveStore.TargetIdentity {
        guard let location = resolveLocation(for: reference, renewBookmark: false) else { throw SaveError.databaseLocationUnavailable }
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
        io: PendingLocalSaveStore.StorageIO = .init(), scopeIO: SecurityScopeIO = .init()
    ) -> PendingLocalSaveStore.ResolutionOutcome {
        do {
            return try withOriginalScope(reference, scopeIO: scopeIO) { location in
                let completion = try observeOriginal(at: location.url) { url in
                    PendingLocalSaveStore.complete(receipt, observeTarget: {
                        (try PendingLocalSaveStore.targetIdentity(at: url), FileDigest.sha512(try Data(contentsOf: url)))
                    }, io: io)
                }
                guard completion == .resolved else { return completion }
                return $scopedOriginalLocation.withValue(location) {
                    if receipt.purpose == .merge, let bytes = receipt.encryptedSnapshot,
                       FileDigest.sha512(bytes) == receipt.sha512 {
                        PendingLocalSaveStore.$cacheCommit.withValue(receipt) {
                            do { try cacheLocalSnapshot(bytes, for: reference, scopeIO: scopeIO) }
                            catch { invalidateOlderLocalCache(for: reference, installedSHA512: receipt.sha512, scopeIO: scopeIO) }
                        }
                    }
                    return retireSettledKeyWitness(for: reference, io: io)
                }
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
        if let evidence = snapshot.keyEvidence, evidence.targetState.isReadyToRetire {
            return PendingLocalSaveStore.resumeCertifiedRetirement(evidence, for: reference.id)
        }
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

    private static func withOriginalScope<T>(
        _ reference: DatabaseReference, scopeIO: SecurityScopeIO = .init(), _ body: (ResolvedLocation) throws -> T
    ) throws -> T {
        guard let location = scopedOriginalLocation ?? resolveLocation(for: reference, renewBookmark: false),
              !location.awaitsWriteBack else { throw SaveError.databaseLocationUnavailable }
        let access = location.usesSecurityScope && scopeIO.begin(location.url)
        defer { if access { scopeIO.end(location.url) } }
        return try body(location)
    }

    private static func observeOriginal(_ reference: DatabaseReference,
        _ observe: (URL) throws -> PendingLocalSaveStore.ResolutionOutcome
    ) throws -> PendingLocalSaveStore.ResolutionOutcome {
        try withOriginalScope(reference) { try observeOriginal(at: $0.url, observe) }
    }

    private static func observeOriginal(at url: URL,
        _ observe: (URL) throws -> PendingLocalSaveStore.ResolutionOutcome
    ) throws -> PendingLocalSaveStore.ResolutionOutcome {
        var coordinatorError: NSError?
        var result: Result<PendingLocalSaveStore.ResolutionOutcome, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { url in
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
        var observedFailure: @Sendable (String, Error) -> Void = { _, _ in }
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
        var failureObservation: (String, Error)?
        var phase = "baseline"
        var observedEffect: PendingLocalSaveStore.TargetCommit?
        var targetWrite: PendingLocalSaveStore.TargetWriteToken?

        func access(readingURL: URL?, writingURL: URL) {
            result = Result {
                do {
                    if let expectedSHA512 {
                        let current = try Data(contentsOf: readingURL ?? writingURL)
                        guard FileDigest.sha512(current) == expectedSHA512 else { return .changed(currentData: current) }
                    }
                    phase = "staging"
                    let stagingDirectory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                        appropriateFor: writingURL, create: true)
                    defer { try? manager.removeItem(at: stagingDirectory) }
                    let staged = stagingDirectory.appendingPathComponent("keeforge-save-\(UUID().uuidString)")
                    try io.stage(data, staged)
                    let perform: (PendingLocalSaveStore.CommitReceipt?) throws -> ReplaceOutcome = { receipt in
                        enteredReplacement = true
                        phase = "replacement"
                        var replacementThrew = false
                        do {
                            _ = try manager.replaceItemAt(writingURL, withItemAt: staged, backupItemName: nil, options: [])
                        } catch {
                            replacementThrew = true
                            failureObservation = (phase, error)
                        }
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
                        phase = "owner"
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
                    failureObservation = (phase, error)
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
        if let (phase, error) = failureObservation { io.observedFailure(phase, error) }
        func finalize(_ outcome: ReplaceOutcome, coordinationFailed: Bool = false) -> ReplaceOutcome {
            var finalOutcome = outcome
            if coordinationFailed {
                observedEffect = observedEffect?.withoutConfirmation
                switch outcome {
                case .replaced(var receipt), .replacedWithoutConfirmedDurability(var receipt), .replacedWithUnconfirmedBookkeeping(var receipt):
                    let targetCommit = receipt?.targetCommit?.withoutConfirmation
                    receipt?.targetCommit = targetCommit
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
                if resolution == .resolved, confirmationError == nil, observedEffect.isConfirmed,
                   let reference = DatabaseListStore.databases.first(where: { $0.id == targetWrite.databaseID }) {
                    resolution = retireSettledKeyWitness(for: reference, io: authorization?.storageIO ?? .init())
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
            io.observedFailure("coordination-completion", error)
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
