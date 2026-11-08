import CryptoKit
import Darwin
import Foundation

enum CloudDatabaseSaver {
    typealias ProgressHandler = @Sendable (Double) -> Void

    enum PendingUploadPushResult: Sendable, Equatable {
        case saved(updatedReference: DatabaseReference)
        case conflict(remoteRev: String?)
    }

    struct Environment: Sendable {
        var beginBackgroundTask: @MainActor @Sendable (String) -> LocalDatabaseSaver.BackgroundTaskHandle
        var endBackgroundTask: @MainActor @Sendable (LocalDatabaseSaver.BackgroundTaskHandle) -> Void
        var cacheURL: @Sendable (DatabaseReference) -> URL
        var readData: @Sendable (URL) throws -> Data
        var extractHeader: @Sendable (Data, SymmetricKey, KDFExecutionPolicy) throws -> KDBXParser.Header
        var encryptDraft: @Sendable (DatabaseDraft, SymmetricKey, KDBXParser.Header, KDFExecutionPolicy) throws -> ExpressUnlock.Written
        var getMetadata: @Sendable (DatabaseReference) async throws -> CloudFileMetadata
        var upload: @Sendable (DatabaseReference, Data, String?, @escaping ProgressHandler) async throws -> CloudFileMetadata
        var downloadRemoteData: @Sendable (DatabaseReference) async throws -> Data
        var backupDirectoryURL: @Sendable (DatabaseReference) -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var writeBackup: @Sendable (Data, URL) throws -> Void
        var pruneBackups: @Sendable (DatabaseReference, Int) throws -> Void
        var now: @Sendable () -> Date
        var queue: PendingUploadQueue.Environment = .live
        var writeGuarantee: @Sendable (DatabaseReference, String?, Int) -> CloudWriteGuarantee = { reference, rev, count in
            guard let metadata = reference.cloudSyncMetadata,
                  let provider = CloudProviderRegistry.provider(for: metadata.provider) else { return .preflightOnly }
            return provider.writeGuarantee(expectedRev: rev, byteCount: count)
        }
        var replaceFile: @Sendable (Data, URL, Data?) throws -> LocalDatabaseSaver.ReplaceOutcome = LocalDatabaseSaver.Environment.live.replaceFileAtomically
        var synchronizeCacheDirectory: @Sendable (URL) throws -> Void = synchronizeDirectory
        var installMissingCache: @Sendable (Data, URL) throws -> Bool = CloudDatabaseSaver.installMissingCache
        static let live = Environment(
            beginBackgroundTask: LocalDatabaseSaver.Environment.live.beginBackgroundTask,
            endBackgroundTask: LocalDatabaseSaver.Environment.live.endBackgroundTask,
            cacheURL: { reference in
                DatabaseListStore.cacheLocation(for: reference)
            },
            readData: { url in
                try CoordinatedFileReader.readData(from: url)
            },
            extractHeader: LocalDatabaseSaver.Environment.live.extractHeader,
            encryptDraft: LocalDatabaseSaver.Environment.live.encryptDraft,
            getMetadata: { reference in
                let (provider, metadata) = try providerAndMetadata(for: reference)
                return try await provider.getMetadata(accountId: metadata.accountId, fileId: metadata.fileId)
            },
            upload: { reference, data, expectedRev, progress in
                let (provider, metadata) = try providerAndMetadata(for: reference)
                return try await provider.upload(
                    accountId: metadata.accountId,
                    fileId: metadata.fileId,
                    data: data,
                    expectedRev: expectedRev,
                    progress: progress
                )
            },
            downloadRemoteData: { reference in
                let (provider, metadata) = try providerAndMetadata(for: reference)
                return try await CloudDatabaseSaver.downloadRemoteData(provider: provider, metadata: metadata)
            },
            backupDirectoryURL: { reference in
                DatabaseListStore.databaseBackupDirectoryURL(for: reference)
            },
            createDirectory: LocalDatabaseSaver.Environment.live.createDirectory,
            writeBackup: LocalDatabaseSaver.Environment.live.writeBackup,
            pruneBackups: LocalDatabaseSaver.Environment.live.pruneBackups,
            now: LocalDatabaseSaver.Environment.live.now
        )
    }

    /// `newCompositeKey` rekeys the database: `compositeKey` still decrypts the
    /// cached file, `newCompositeKey` encrypts the uploaded bytes, and the
    /// result is verified to reopen with the new key before the upload.
    ///
    /// `encryptionSettings` rewrites the header's cipher, KDF, or compression
    /// before encrypting, under the same reopen check.
    ///
    /// `reconciledRemoteSHA512` widens the overwrite gate by exactly one state
    /// — see `SaveBaseline`. On this path it is what lets a merge save proceed
    /// while the local cache still holds the open-time bytes: the remote it
    /// reconciled is the state being replaced, and the stale recorded rev then
    /// rebases onto the head that hashes to it.
    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        reconciledRemoteSHA512: Data? = nil,
        expectedRev: String?,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: SymmetricKey? = nil,
        encryptionSettings: EncryptionSettingsChange? = nil,
        rekeyContext: PendingUploadQueue.RekeyContext? = nil
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            reconciledRemoteSHA512: reconciledRemoteSHA512,
            expectedRev: expectedRev,
            kdfPolicy: kdfPolicy,
            newCompositeKey: newCompositeKey,
            encryptionSettings: encryptionSettings,
            rekeyContext: rekeyContext,
            environment: .live
        )
    }

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        reconciledRemoteSHA512: Data? = nil,
        expectedRev: String?,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: SymmetricKey? = nil,
        encryptionSettings: EncryptionSettingsChange? = nil,
        rekeyContext: PendingUploadQueue.RekeyContext? = nil,
        environment: Environment
    ) async throws -> SaveResult {
        if reference.isReadOnly {
            throw SaveError.databaseIsReadOnly
        }

        guard reference.cloudSyncMetadata != nil,
              (newCompositeKey != nil) == (rekeyContext != nil) else {
            throw SaveError.saveContextUnavailable
        }

        let backgroundTaskHandle = await environment.beginBackgroundTask("CloudDatabaseSaving")
        defer {
            Task { @MainActor in
                environment.endBackgroundTask(backgroundTaskHandle)
            }
        }

        return try await Task.detached(priority: .utility) {
            try await saveOffMain(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                baseline: SaveBaseline(
                    openTimeSHA512: openTimeSHA512,
                    reconciledRemoteSHA512: reconciledRemoteSHA512
                ),
                expectedRev: expectedRev,
                kdfPolicy: kdfPolicy,
                newCompositeKey: newCompositeKey,
                encryptionSettings: encryptionSettings,
                rekeyContext: rekeyContext,
                environment: environment
            )
        }.value
    }

    private static func saveOffMain(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        baseline: SaveBaseline,
        expectedRev: String?,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: SymmetricKey?,
        encryptionSettings: EncryptionSettingsChange?,
        rekeyContext: PendingUploadQueue.RekeyContext?,
        environment: Environment
    ) async throws -> SaveResult {
        let cacheURL = environment.cacheURL(reference)
        let currentData = try environment.readData(cacheURL)
        let currentSHA512 = KDBXCrypto.sha512(currentData)
        guard baseline.covers(currentSHA512) else {
            return .conflict(remoteSHA512: currentSHA512, remoteData: currentData)
        }

        // A rekey is online-only; no journal or local mutation precedes this probe.
        if newCompositeKey != nil {
            guard rekeyContext != nil else { throw SaveError.saveContextUnavailable }
            let remoteMetadata = try await environment.getMetadata(reference)
            let remoteBytes = try await environment.downloadRemoteData(reference)
            guard baseline.covers(KDBXCrypto.sha512(remoteBytes)) else {
                return .conflict(remoteSHA512: KDBXCrypto.sha512(remoteBytes), remoteData: remoteBytes)
            }
            guard environment.writeGuarantee(reference, remoteMetadata.rev, currentData.count) != .disabled else {
                throw CloudProviderError.invalidConfiguration
            }
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
        let expressKey = reference.hardwareKey == nil ? written.expressKey : nil
        if newCompositeKey != nil || encryptionSettings != nil {
            do {
                _ = try environment.extractHeader(newData, writeKey, kdfPolicy)
            } catch {
                throw SaveError.reencryptionVerificationFailed
            }
        }

        // Back up before uploading, so every local file operation stays ahead
        // of the remote change. Backing up afterwards would let a local write
        // failure report the save as failed with the remote already advanced —
        // a spurious "changed outside KeeForge" conflict on the next retry.
        let backupDirectoryURL = environment.backupDirectoryURL(reference)
        try environment.createDirectory(backupDirectoryURL)

        let backupURL = backupDirectoryURL.appendingPathComponent(
            backupFilename(for: environment.now()),
            isDirectory: false
        )
        try environment.writeBackup(currentData, backupURL)

        var intent: PendingUploadQueue.StoredMarker?
        let replacement = try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue) {
            let latest = try environment.readData(cacheURL)
            guard KDBXCrypto.sha512(latest) == currentSHA512 else { return LocalDatabaseSaver.ReplaceOutcome.changed(currentData: latest) }
            let latestReference = DatabaseListStore.databases.first { $0.id == reference.id } ?? reference
            guard latestReference.cloudSyncMetadata?.keyEpoch == reference.cloudSyncMetadata?.keyEpoch,
                  latestReference.lastMasterKeyChangeAt == reference.lastMasterKeyChangeAt else { throw SaveError.saveContextUnavailable }
            var prepared = try PendingUploadQueue.prepare(
                reference: latestReference, currentData: currentData, intendedData: newData,
                cacheURL: cacheURL, rekeyContext: rekeyContext,
                remoteBaseSHA512: baseline.reconciledRemoteSHA512, environment: environment.queue
            )
            intent = prepared
            if rekeyContext != nil { return .replaced }
            let outcome = try environment.replaceFile(newData, cacheURL, currentSHA512)
            guard outcome.didReplace else {
                _ = try? PendingUploadQueue.dropIfUnchanged(prepared, environment: environment.queue)
                return outcome
            }
            prepared.marker.openTimeSHA512 = KDBXCrypto.sha512(newData)
            intent = (try? PendingUploadQueue.finalize(prepared, environment: environment.queue)) ?? prepared
            DatabaseListStore.recordCloudLocalCommit(for: reference.id, operationID: prepared.id)
            return outcome
        }
        if case .changed(let bytes) = replacement { return .conflict(remoteSHA512: KDBXCrypto.sha512(bytes), remoteData: bytes) }
        guard let intent else { throw SaveError.saveContextUnavailable }
        if rekeyContext != nil {
            guard let result = try await deliver(intent, reference: reference, environment: environment) else {
                throw SaveError.saveContextUnavailable
            }
            if case .conflict = result { throw CloudProviderError.conflict(remoteRev: nil) }
        } else {
            PendingUploadQueue.postEnqueuedNotification(environment: environment.queue)
        }
        try? environment.pruneBackups(reference, 5)
        return .saved(newSHA512: KDBXCrypto.sha512(newData), expressKey: expressKey)
    }

    private static func recordIssue(_ error: Error, reference: DatabaseReference) {
        guard let current = DatabaseListStore.databases.first(where: { $0.id == reference.id }),
              let metadata = current.cloudSyncMetadata else { return }
        DatabaseListStore.updateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: metadata) {
            $0.lastSyncIssue = CloudProviderError.issue(for: error)
            $0.lastSyncedAt = nil
        }
    }

    static func deliver(
        _ snapshot: PendingUploadQueue.StoredMarker, reference: DatabaseReference,
        environment: Environment = .live
    ) async throws -> PendingUploadPushResult? {
        do { return try await deliverJournal(snapshot, reference: reference, environment: environment) }
        catch { recordIssue(error, reference: reference); throw error }
    }

    /// Delivery never rewrites ordinary local commits. The journal owns the exact ciphertext across awaits.
    private static func deliverJournal(
        _ snapshot: PendingUploadQueue.StoredMarker, reference: DatabaseReference,
        environment: Environment = .live
    ) async throws -> PendingUploadPushResult? {
        var stored = try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue) {
            try PendingUploadQueue.recoverPrepared(snapshot, environment: environment.queue)
        }
        let marker = stored.marker
        let all = PendingUploadQueue.listMarkers(for: reference.id, environment: environment.queue)
        if all.contains(where: { $0.id != stored.id && ($0.marker.rekeyContext != nil || ($0.marker.uploadAttemptID != nil && $0.marker.confirmedAt == nil && $0.marker.attemptIsFenced != true)) }) { return nil }
        if marker.uploadAttemptID == nil, marker.rekeyContext == nil,
           all.contains(where: { $0.id != stored.id && $0.marker.isConflicted }) { return nil }
        if marker.requiresLocalRecovery == true { return .conflict(remoteRev: nil) }
        if let predecessorID = marker.predecessorOperationID,
           all.contains(where: { $0.id == predecessorID }) { return nil }
        guard marker.isPayloadFinalized == true || marker.rekeyContext != nil else {
            if marker.isPayloadFinalized == nil {
                try PendingUploadQueue.markDatabaseConflicted(for: reference.id, environment: environment.queue)
                return .conflict(remoteRev: nil)
            }
            return nil
        }
        let payloadPath = marker.intendedPayloadPath ?? marker.encryptedBytesCacheURL
        let bytes = try environment.queue.readData(PendingUploadQueue.resolveAppGroupURL(for: payloadPath, environment: environment.queue))
        let payloadSHA = marker.intendedPayloadSHA512 ?? marker.openTimeSHA512
        guard KDBXCrypto.sha512(bytes) == payloadSHA else {
            try PendingUploadQueue.markDatabaseConflicted(for: reference.id, environment: environment.queue)
            return .conflict(remoteRev: nil)
        }
        if marker.rekeyContext == nil {
            let wrongEpoch = marker.keyEpoch != reference.cloudSyncMetadata?.keyEpoch
            let predatesRekey = reference.lastMasterKeyChangeAt.map { marker.createdAt < $0 } ?? false
            if wrongEpoch || (marker.keyEpoch == nil && predatesRekey) {
                try PendingUploadQueue.markDatabaseConflicted(for: reference.id, environment: environment.queue)
                return .conflict(remoteRev: nil)
            }
        }
        if stored.marker.confirmedAt == nil {
            let remoteMetadata = try await environment.getMetadata(reference)
            let remoteBytes = try await environment.downloadRemoteData(reference)
            let remoteSHA = KDBXCrypto.sha512(remoteBytes)
            if marker.uploadAttemptID != nil, marker.attemptIsFenced != true,
               let originalRev = marker.expectedRev, remoteMetadata.rev != nil, remoteMetadata.rev != originalRev,
               environment.writeGuarantee(reference, originalRev, bytes.count) == .serverConditional {
                stored.marker.attemptIsFenced = true
                stored = try PendingUploadQueue.update(stored, environment: environment.queue)
            }
            if stored.marker.discardRequested == true, stored.marker.attemptIsFenced == true {
                _ = try PendingUploadQueue.dropIfUnchanged(stored, environment: environment.queue)
                return .saved(updatedReference: reference)
            }
            if remoteSHA != payloadSHA {
                let baseMatches: Bool
                if let base = marker.remoteBaseSHA512 { baseMatches = remoteSHA == base }
                else if let recorded = reference.cloudSyncMetadata {
                    baseMatches = !remoteHasDiverged(recorded: recorded, remote: remoteMetadata, expectedRev: marker.expectedRev)
                } else { baseMatches = false }
                guard baseMatches else {
                    try PendingUploadQueue.markDatabaseConflicted(for: reference.id, environment: environment.queue)
                    return .conflict(remoteRev: remoteMetadata.rev)
                }
                let unresolved = marker.uploadAttemptID != nil && stored.marker.attemptIsFenced != true
                let expectedRev = unresolved ? marker.expectedRev : remoteMetadata.rev
                let guarantee = environment.writeGuarantee(reference, expectedRev, bytes.count)
                guard guarantee != .disabled else { throw CloudProviderError.invalidConfiguration }
                if stored.marker.discardRequested == true { return nil }
                if unresolved && guarantee != .serverConditional { return nil }
                if unresolved && remoteMetadata.rev != marker.expectedRev { return nil }
                stored.marker.expectedRev = expectedRev
                stored.marker.uploadAttemptID = UUID()
                stored.marker.attemptIsFenced = false
                stored = try PendingUploadQueue.update(stored, environment: environment.queue)
                // No mutation is dispatched until uncertainty is durable.
                let response: CloudFileMetadata
                do { response = try await environment.upload(reference, bytes, expectedRev, { _ in }) }
                catch {
                    if let failure = error as? CloudUploadFailure, failure.provesNoCommit, !unresolved {
                        stored.marker.attemptIsFenced = true
                        stored = try PendingUploadQueue.update(stored, environment: environment.queue)
                    }
                    if guarantee == .preflightOnly {
                        try? PendingUploadQueue.markDatabaseConflicted(for: reference.id, environment: environment.queue)
                    }
                    throw error
                }
                stored.marker.confirmedRemoteRev = response.rev
                stored.marker.confirmedRemoteHash = response.contentHash
            } else {
                stored.marker.confirmedRemoteRev = remoteMetadata.rev
                stored.marker.confirmedRemoteHash = remoteMetadata.contentHash
            }
            stored.marker.confirmedAt = .now
            stored = try PendingUploadQueue.update(stored, environment: environment.queue)
        }
        return try finishDelivery(stored, reference: reference, bytes: bytes, environment: environment)
    }

    private static func finishDelivery(
        _ stored: PendingUploadQueue.StoredMarker, reference: DatabaseReference,
        bytes: Data, environment: Environment
    ) throws -> PendingUploadPushResult {
        try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue) {
            let payloadSHA = KDBXCrypto.sha512(bytes)
            var current = DatabaseListStore.databases.first { $0.id == reference.id } ?? reference
            if let rekey = stored.marker.rekeyContext {
                do {
                    guard PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue).contains(where: {
                        $0.id == stored.id && $0.marker == stored.marker
                    }) else { throw SaveError.rekeyAppliedRemotely }
                    let publishingEpoch = current.cloudSyncMetadata?.keyEpoch != rekey.epoch
                    if publishingEpoch {
                        guard current.lastMasterKeyChangeAt.map({ $0 > stored.marker.createdAt }) != true else {
                            throw SaveError.rekeyAppliedRemotely
                        }
                    } else {
                        guard current.cloudSyncMetadata?.localHeadOperationID == stored.id else {
                            throw SaveError.rekeyAppliedRemotely
                        }
                    }
                    let cacheURL = environment.cacheURL(current)
                    let previous = try? environment.readData(cacheURL)
                    let previousSHA = previous.map(KDBXCrypto.sha512)
                    guard previousSHA == payloadSHA || (previousSHA != nil && previousSHA == stored.marker.predecessorSHA512)
                        || (!publishingEpoch && previous == nil) else { throw SaveError.rekeyAppliedRemotely }
                    if publishingEpoch {
                        // Invalidate old-key unlock items before publishing new-key bytes.
                        KeychainService.deleteCompositeKey(for: current.id)
                        if let legacy = current.legacyKeychainFilename { KeychainService.deleteLegacyCompositeKey(forFilename: legacy) }
                    }
                    if previousSHA != payloadSHA {
                        if let previous {
                            let hasOtherPending = PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue).contains { $0.id != stored.id }
                            let filename = backupFilename(for: .now)
                            let retainedFilename = hasOtherPending ? String(filename.dropLast(5)) + DatabaseListStore.retainedBackupSuffix + ".kdbx" : filename
                            let backupURL = environment.backupDirectoryURL(current).appendingPathComponent(retainedFilename)
                            try environment.createDirectory(backupURL.deletingLastPathComponent())
                            try environment.writeBackup(previous, backupURL)
                            let outcome = try environment.replaceFile(bytes, cacheURL, previousSHA)
                            guard outcome.didReplace else { throw SaveError.rekeyAppliedRemotely }
                        } else {
                            guard try environment.installMissingCache(bytes, cacheURL) else { throw SaveError.rekeyAppliedRemotely }
                        }
                    }
                    guard KDBXCrypto.sha512(try environment.readData(cacheURL)) == payloadSHA else {
                        throw SaveError.rekeyAppliedRemotely
                    }
                    if publishingEpoch {
                        guard let updated = DatabaseListStore.recordCloudLocalCommit(
                            for: current.id, operationID: stored.id, rekey: rekey, committedAt: stored.marker.confirmedAt ?? .now
                        ) else { throw SaveError.rekeyAppliedRemotely }
                        current = updated
                    }
                } catch { throw SaveError.rekeyAppliedRemotely }
            }
            let cacheSHA = (try? environment.readData(environment.cacheURL(current))).map(KDBXCrypto.sha512)
            let currentHead = current.cloudSyncMetadata?.localHeadOperationID
            let headStillPending = PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue).contains { $0.id == currentHead }
            if stored.marker.rekeyContext == nil, cacheSHA == payloadSHA, currentHead != stored.id, !headStillPending {
                current = DatabaseListStore.recordCloudLocalCommit(for: current.id, operationID: stored.id) ?? current
            }
            // Keep the durable ciphertext journal until the cache pathname is durable too.
            do { try environment.synchronizeCacheDirectory(environment.cacheURL(current).deletingLastPathComponent()) }
            catch { return .saved(updatedReference: current) }
            if let rekey = stored.marker.rekeyContext {
                guard let latest = DatabaseListStore.databases.first(where: { $0.id == current.id }),
                      latest.cloudSyncMetadata?.keyEpoch == rekey.epoch,
                      latest.cloudSyncMetadata?.localHeadOperationID == stored.id,
                      (try? environment.readData(environment.cacheURL(latest))).map(KDBXCrypto.sha512) == payloadSHA else {
                    throw SaveError.rekeyAppliedRemotely
                }
                current = latest
            }
            if cacheSHA == payloadSHA, current.cloudSyncMetadata?.localHeadOperationID == stored.id,
               let observed = current.cloudSyncMetadata {
                let remaining = PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue).filter { $0.id != stored.id }
                guard let updated = DatabaseListStore.updateCloudSyncMetadata(for: current.id, ifUnchangedFrom: observed, mutate: {
                    if let rev = stored.marker.confirmedRemoteRev { $0.remoteRev = rev }
                    if let hash = stored.marker.confirmedRemoteHash { $0.remoteContentHash = hash }
                    $0.remoteModifiedAt = stored.marker.confirmedAt
                    $0.lastSyncedAt = remaining.isEmpty ? stored.marker.confirmedAt : nil
                    $0.lastSyncIssue = nil
                }) else { throw SaveError.saveContextUnavailable }
                current = updated
            }
            // A confirmed parent transfers its exact remote ancestry before its journal can disappear.
            for var child in PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue)
            where child.marker.predecessorOperationID == stored.id || child.marker.absorbedOperationIDs?.contains(stored.id) == true {
                child.marker.expectedRev = stored.marker.confirmedRemoteRev
                child.marker.baseRev = stored.marker.confirmedRemoteRev
                child.marker.remoteBaseSHA512 = payloadSHA
                child.marker.predecessorOperationID = nil
                _ = try PendingUploadQueue.update(child, environment: environment.queue)
            }
            _ = try PendingUploadQueue.dropIfUnchanged(stored, environment: environment.queue)
            return .saved(updatedReference: current)
        }
    }

    private static func installMissingCache(_ bytes: Data, _ cacheURL: URL) throws -> Bool {
        let directory = cacheURL.deletingLastPathComponent()
        try createDurableDirectory(at: directory)
        let stagedURL = directory.appendingPathComponent(".rekey-recovery-\(UUID().uuidString).kdbx")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try writeAtomicallyAndDurably(bytes, to: stagedURL)
        // An intervening writer wins; never replace a cache that appeared after the missing-file read.
        guard Darwin.link(stagedURL.path, cacheURL.path) == 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    static func pushPendingUpload(
        reference: DatabaseReference,
        encryptedBytes: Data,
        expectedRev: String?
    ) async throws -> PendingUploadPushResult {
        try await pushPendingUpload(
            reference: reference,
            encryptedBytes: encryptedBytes,
            expectedRev: expectedRev,
            environment: .live
        )
    }

    static func pushPendingUpload(
        reference: DatabaseReference,
        encryptedBytes: Data,
        expectedRev: String?,
        environment: Environment
    ) async throws -> PendingUploadPushResult {
        guard reference.cloudSyncMetadata != nil else {
            throw SaveError.saveContextUnavailable
        }

        let backgroundTaskHandle = await environment.beginBackgroundTask("PendingUploadDraining")
        defer {
            Task { @MainActor in
                environment.endBackgroundTask(backgroundTaskHandle)
            }
        }

        return try await Task.detached(priority: .utility) {
            try await pushPendingUploadOffMain(
                reference: reference,
                encryptedBytes: encryptedBytes,
                expectedRev: expectedRev,
                environment: environment
            )
        }.value
    }

    /// Whether the remote head differs from the state this save was based on —
    /// the conflict-versus-upload gate. A recorded rev makes it exact. A nil
    /// rev is common (pre-rev-tracking references, offline opens, ETag-less
    /// WebDAV) and there a bare `remote.rev != expectedRev` passes vacuously,
    /// turning the upload into an unconditional overwrite (Dropbox
    /// `WriteMode.overwrite`, OneDrive `conflictBehavior=replace` without
    /// `If-Match`). So nil falls back to metadata: the reported content hash
    /// must match the recorded one, and an unrecorded rev is conflict-suspect.
    /// Residue: a bare WebDAV server exposing neither rev nor hash offers
    /// nothing to verify against; closing that needs a remote-byte compare.
    static func remoteHasDiverged(
        recorded: CloudSyncMetadata,
        remote: CloudFileMetadata,
        expectedRev: String?
    ) -> Bool {
        if let expectedRev {
            return remote.rev != expectedRev
        }

        if let remoteContentHash = remote.contentHash {
            return remoteContentHash != recorded.remoteContentHash
        }

        return remote.rev != nil
    }

    private static func pushPendingUploadOffMain(
        reference: DatabaseReference,
        encryptedBytes: Data,
        expectedRev: String?,
        environment: Environment
    ) async throws -> PendingUploadPushResult {
        guard let stored = PendingUploadQueue.listMarkers(for: reference.id, environment: environment.queue).first(where: {
            $0.marker.isPayloadFinalized == true && $0.marker.openTimeSHA512 == KDBXCrypto.sha512(encryptedBytes)
        }) else { throw SaveError.saveContextUnavailable }
        guard let result = try await deliver(stored, reference: reference, environment: environment) else {
            throw CloudProviderError.serviceUnavailable
        }
        return result
    }

    private static func backupFilename(for date: Date) -> String {
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

    private static func providerAndMetadata(for reference: DatabaseReference) throws -> (CloudProvider, CloudSyncMetadata) {
        guard let metadata = reference.cloudSyncMetadata else {
            throw SaveError.saveContextUnavailable
        }

        guard let provider = CloudProviderRegistry.provider(for: metadata.provider) else {
            throw CloudProviderError.notAuthenticated
        }

        return (provider, metadata)
    }

    private static func downloadRemoteData(
        provider: CloudProvider,
        metadata: CloudSyncMetadata
    ) async throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try await provider.download(
            accountId: metadata.accountId,
            fileId: metadata.fileId,
            to: tempURL,
            progress: { _ in }
        )
        #if os(iOS)
        // iOS Data Protection; every other on-disk copy of database bytes gets
        // class A, so the staged ciphertext must too. On macOS setting a
        // protection class either fails or leaves the file unreadable —
        // FileVault covers at-rest encryption there instead.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: tempURL.path
        )
        #endif
        return try Data(contentsOf: tempURL)
    }
}
