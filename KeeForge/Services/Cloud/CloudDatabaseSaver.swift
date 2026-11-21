import CryptoKit
import Darwin
import Foundation
import KDBXKit

struct CloudSaveRecoveryWarning: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        String(localized: "This cloud operation needs recovery. Keep both the original and new keys if you changed them. Export the encrypted copy from Settings → Cloud → Cloud Recovery before trying another operation. An uncertain request will not be sent again automatically.")
    }
}

enum CloudDatabaseSaver {
    typealias ProgressHandler = @Sendable (Double) -> Void
    @TaskLocal static var keyChange: PendingUploadQueue.KeyChange?
    @TaskLocal static var rekeyTicket: RekeyTicket?
    @TaskLocal static var saveTicket: SaveTicket?

    final class SaveTicket: @unchecked Sendable {
        let operationID: UUID
        private let lock = NSLock()
        private var digest: Data?
        init(operationID: UUID = UUID()) { self.operationID = operationID }
        func prepare(_ sha: Data) { lock.withLock { digest = sha } }
        var payloadSHA: Data? { lock.withLock { digest } }
    }

    // This registry contains only weak, session-owned completion tickets, never keys.
    final class RekeyTicket: @unchecked Sendable {
        private final class Registry: @unchecked Sendable {
            let lock = NSLock()
            var tickets: [UUID: WeakTicket] = [:]
        }
        private final class WeakTicket {
            weak var value: RekeyTicket?
            init(_ value: RekeyTicket) { self.value = value }
        }
        private static let registry = Registry()
        let operationID = UUID()
        private let lock = NSLock()
        private var digest: Data?
        private var completed = false
        private let notify: @Sendable () -> Void

        init(notify: @escaping @Sendable () -> Void) {
            self.notify = notify
            Self.registry.lock.withLock { Self.registry.tickets[operationID] = WeakTicket(self) }
        }
        deinit { Self.registry.lock.withLock { Self.registry.tickets.removeValue(forKey: operationID) } }
        func prepare(_ sha: Data) { lock.withLock { digest = sha } }
        var payloadSHA: Data? { lock.withLock { digest } }
        var isCompleted: Bool { lock.withLock { completed } }
        static func signal(_ id: UUID) {
            registry.lock.withLock { registry.tickets[id]?.value }?.notify()
        }
        static func complete(_ id: UUID) {
            let ticket = registry.lock.withLock { registry.tickets[id]?.value }
            guard let ticket else { return }
            let shouldNotify = ticket.lock.withLock {
                guard !ticket.completed, ticket.digest != nil else { return false }
                ticket.completed = true
                return true
            }
            if shouldNotify { ticket.notify() }
        }
    }

    /// One authenticated merge invocation; never serialized and never a Keychain grant.
    final class MergeContext: @unchecked Sendable {
        private enum Phase { case authenticated, saving, replacing, durable, consuming, revoked, finished }
        let operationID: UUID
        let beforeReference: DatabaseReference
        let sources: [PendingUploadQueue.StoredMarker]
        let remoteSHA512: Data
        private let reference: DatabaseReference
        var ownerReference: DatabaseReference { reference }
        private let cacheSHA512: Data
        var localBaseline: SaveBaseline { .init(openTimeSHA512: cacheSHA512, reconciledRemoteSHA512: nil) }
        private let target: PendingLocalSaveStore.TargetIdentity
        let lease: PendingLocalSaveStore.CacheReadLease
        private let lock = NSLock()
        private var phase: Phase = .authenticated
        private var output: PendingLocalSaveStore.InstalledTarget?
        private var deferredNotification: (@Sendable () -> Void)?

        private init(_ authentication: DatabaseViewModel.CloudMergeAuthentication, reference: DatabaseReference,
                     sha512: Data, target: PendingLocalSaveStore.TargetIdentity, lease: PendingLocalSaveStore.CacheReadLease) {
            operationID = authentication.operationID
            beforeReference = authentication.reference
            sources = authentication.sources
            remoteSHA512 = authentication.remoteSHA512
            self.reference = reference
            cacheSHA512 = sha512
            self.target = target
            self.lease = lease
        }

        static func capture(_ authentication: DatabaseViewModel.CloudMergeAuthentication) throws -> MergeContext {
            let before = authentication.reference
            guard let current = DatabaseListStore.databases.first(where: { $0.id == before.id }), sameEpoch(before, current) else {
                throw SaveError.saveContextUnavailable
            }
            let cache = DatabaseListStore.cacheLocation(for: current)
            var result: Result<MergeContext, Error>?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: cache, error: &error) { protected in
                result = Result {
                    try DatabaseListStore.withCloudMergeReference(current) { current in
                        try PendingUploadQueue.withCommitLock(for: current.id, nonBlocking: true) {
                            let bytes = try Data(contentsOf: protected)
                            let sha = FileDigest.sha512(bytes)
                            guard authentication.sources.contains(where: {
                                $0.marker.intendedPayloadSHA512 == sha
                                    && ($0.id == current.cloudSyncMetadata?.localHeadOperationID
                                        || ($0.marker.journalVersion == nil && $0.marker.binding == nil))
                            }) else { throw SaveError.saveContextUnavailable }
                            let context = MergeContext(authentication, reference: current, sha512: sha,
                                target: try PendingLocalSaveStore.targetIdentity(at: protected),
                                lease: try PendingLocalSaveStore.captureCacheReadLease(for: current))
                            try PendingLocalSaveStore.withReferenceEpochAuthorization(context.lease) {}
                            try context.validateSources(allowingOutput: false)
                            return context
                        }
                    }
                }
            }
            if let result { return try result.get() }
            throw error ?? CocoaError(.fileReadUnknown)
        }

        private static func sameEpoch(_ before: DatabaseReference, _ current: DatabaseReference) -> Bool {
            before.id == current.id && before.cloudSyncMetadata?.provider == current.cloudSyncMetadata?.provider
                && before.cloudSyncMetadata?.accountId == current.cloudSyncMetadata?.accountId
                && before.cloudSyncMetadata?.fileId == current.cloudSyncMetadata?.fileId
                && before.cloudSyncMetadata?.keyEpoch == current.cloudSyncMetadata?.keyEpoch
                && before.lastMasterKeyChangeAt == current.lastMasterKeyChangeAt
                && before.keyFileBookmarkData == current.keyFileBookmarkData && before.keyFileFilename == current.keyFileFilename
                && before.bookmarkData == current.bookmarkData && before.hardwareKey == current.hardwareKey
                && before.legacyKeychainFilename == current.legacyKeychainFilename && before.isReadOnly == current.isReadOnly
        }

        func revoke() { lock.withLock { if phase != .replacing && phase != .consuming { phase = .revoked } } }
        func finish() {
            lock.withLock { phase = .finished }
            notifyAfterHandoff()
        }
        func deferEnqueuedNotification(_ notify: @escaping @Sendable () -> Void) {
            lock.withLock { deferredNotification = notify }
        }
        private func notifyAfterHandoff() {
            let notify = lock.withLock {
                let captured = deferredNotification
                deferredNotification = nil
                return captured
            }
            notify?()
        }
        func begin(reference: DatabaseReference, remoteSHA512: Data?) throws {
            try lock.withLock {
                guard phase == .authenticated, reference == beforeReference, remoteSHA512 == self.remoteSHA512 else {
                    throw SaveError.saveContextUnavailable
                }
                phase = .saving
            }
        }
        private func requireSaving() throws {
            guard lock.withLock({ phase == .saving }) else { throw CancellationError() }
        }
        func claimReplacement() throws {
            try lock.withLock {
                guard phase == .saving else { throw CancellationError() }
                phase = .replacing
            }
        }
        private func validateSources(allowingOutput: Bool) throws {
            let journal = try PendingUploadQueue.readJournal(for: reference.id)
            let originals = journal.filter { !allowingOutput || $0.id != operationID }
            guard originals.count == sources.count else { throw SaveError.saveContextUnavailable }
            for source in sources {
                guard CloudJournalDecision.permitsAuthenticatedMergeSource(source, reference: reference),
                      originals.contains(where: { $0.id == source.id && $0.marker == source.marker }),
                      FileDigest.sha512(try PendingUploadQueue.readImmutablePayload(source)) == source.marker.intendedPayloadSHA512 else {
                    throw SaveError.saveContextUnavailable
                }
            }
            if allowingOutput {
                guard let own = journal.first(where: { $0.id == operationID }), own.marker.keyEpoch == reference.cloudSyncMetadata?.keyEpoch,
                      own.marker.confirmedAt == nil, own.marker.uploadAttemptID == nil else { throw SaveError.saveContextUnavailable }
            }
        }
        func readBeforeEncryption() throws -> Data {
            try requireSaving()
            let cache = DatabaseListStore.cacheLocation(for: reference)
            var result: Result<Data, Error>?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: cache, error: &error) { protected in
                result = Result {
                    try DatabaseListStore.withCloudMergeReference(reference) { _ in
                        try PendingUploadQueue.withCommitLock(for: reference.id, nonBlocking: true) {
                            try requireSaving()
                            try validateSources(allowingOutput: false)
                            let bytes = try Data(contentsOf: protected)
                            guard FileDigest.sha512(bytes) == cacheSHA512,
                                  try PendingLocalSaveStore.targetIdentity(at: protected) == target else { throw SaveError.saveContextUnavailable }
                            try PendingLocalSaveStore.withReferenceEpochAuthorization(lease) {}
                            return try PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: cacheSHA512, lease: lease) { bytes }
                        }
                    }
                }
            }
            if let result { return try result.get() }
            throw error ?? CocoaError(.fileReadUnknown)
        }
        /// Caller already holds the commit lease; no coordination or waiting for list lock here.
        func validateBeforePreparation() throws {
            try DatabaseListStore.withCloudMergeReference(reference) { _ in
                try requireSaving()
                try validateSources(allowingOutput: false)
                let cache = DatabaseListStore.cacheLocation(for: reference)
                guard try PendingLocalSaveStore.targetIdentity(at: cache) == target,
                      FileDigest.sha512(try Data(contentsOf: cache)) == cacheSHA512 else { throw SaveError.saveContextUnavailable }
            }
        }
        func withReplacementFence(at cache: URL, _ replace: () throws -> LocalDatabaseSaver.ReplaceOutcome) throws -> LocalDatabaseSaver.ReplaceOutcome {
            try DatabaseListStore.withCloudMergeReference(reference) { _ in
                try requireSaving()
                try validateSources(allowingOutput: true)
                guard try PendingLocalSaveStore.targetIdentity(at: cache) == target,
                      FileDigest.sha512(try Data(contentsOf: cache)) == cacheSHA512 else { throw SaveError.saveContextUnavailable }
                return try replace()
            }
        }
        func recordDurableOutput(_ outcome: LocalDatabaseSaver.ReplaceOutcome, sha512: Data) throws {
            guard case .replaced(let receipt) = outcome, let receipt, let commit = receipt.targetCommit,
                  commit.isConfirmed, commit.snapshot.sha512 == sha512 else { throw CloudSaveRecoveryWarning() }
            try lock.withLock {
                guard phase == .replacing else { throw CloudSaveRecoveryWarning() }
                output = commit.snapshot
                phase = .durable
            }
        }
        func consume(sha512: Data, onFailure: @escaping @Sendable (String, Error) -> Void = { _, _ in }) throws {
            defer { notifyAfterHandoff() }
            var stage = "output-receipt"
            do {
                guard let installed = lock.withLock({ phase == .durable ? output : nil }), installed.sha512 == sha512 else {
                    throw CloudSaveRecoveryWarning()
                }
                var expected = reference
                expected.updateCloudSyncMetadata { $0.localHeadOperationID = operationID }
                let cache = DatabaseListStore.cacheLocation(for: reference)
                var result: Result<Void, Error>?
                var error: NSError?
                stage = "coordination"
                NSFileCoordinator().coordinate(readingItemAt: cache, error: &error) { protected in
                    result = Result {
                        stage = "list-entry"
                        return try DatabaseListStore.withCloudMergeReference(expected) { current in
                            stage = "commit-entry"
                            var queue = PendingUploadQueue.Environment.live
                            queue.observedCommitLockFailure = { code in
                                onFailure("cloud-merge-consume.flock-errno", POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
                            }
                            return try PendingUploadQueue.withCommitLock(for: current.id, environment: queue, nonBlocking: true) {
                                stage = "source-proof"
                                try validateSources(allowingOutput: true)
                                stage = "installed-target"
                                guard try PendingLocalSaveStore.targetIdentity(at: protected) == installed.target,
                                      FileDigest.sha512(try Data(contentsOf: protected)) == sha512 else { throw SaveError.saveContextUnavailable }
                                stage = "owner-epoch"
                                try PendingLocalSaveStore.withReferenceEpochAuthorization(lease) {}
                                stage = "owner-cache"
                                try PendingLocalSaveStore.withCachePublicationAuthorization(for: current.id, sha512: sha512, lease: lease) {
                                    stage = "phase-claim"
                                    try lock.withLock {
                                        guard phase == .durable else { throw CancellationError() }
                                        phase = .consuming
                                    }
                                    try PendingUploadQueue.transferMergedSourcesLocked(sources, toPayloadSHA512: sha512, reference: current, onStage: { stage = $0 })
                                }
                            }
                        }
                    }
                }
                if let error { onFailure("cloud-merge-consume.coordination-result", error) }
                if let result { try result.get(); return }
                throw error ?? CocoaError(.fileReadUnknown)
            } catch {
                onFailure("cloud-merge-consume." + stage, error)
                throw error
            }
        }
    }

    @TaskLocal static var mergeContext: MergeContext?

    enum PendingUploadPushResult: Sendable, Equatable {
        case saved(updatedReference: DatabaseReference)
        /// Remote confirmation is durable, but the journal still owns the ciphertext.
        case retained(updatedReference: DatabaseReference)
        case conflict(remoteRev: String?)
    }

    struct Environment: Sendable {
        var beginBackgroundTask: @MainActor @Sendable (String) -> LocalDatabaseSaver.BackgroundTaskHandle
        var endBackgroundTask: @MainActor @Sendable (LocalDatabaseSaver.BackgroundTaskHandle) -> Void
        var cacheURL: @Sendable (DatabaseReference) -> URL
        var readData: @Sendable (URL) throws -> Data
        var extractHeader: @Sendable (Data, SymmetricKey, KDFExecutionPolicy) throws -> KDBXContainer.Header
        var encryptDraft: @Sendable (DatabaseDraft, SymmetricKey, KDBXContainer.Header, KDFExecutionPolicy) throws -> ExpressUnlock.Written
        var getMetadata: @Sendable (DatabaseReference) async throws -> CloudFileMetadata
        var upload: @Sendable (DatabaseReference, Data, String?, @escaping ProgressHandler) async throws -> CloudFileMetadata
        var downloadRemoteData: @Sendable (DatabaseReference) async throws -> Data
        var backupDirectoryURL: @Sendable (DatabaseReference) -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var writeBackup: @Sendable (Data, URL) throws -> Void
        var pruneBackups: @Sendable (DatabaseReference, Int) throws -> Void
        var now: @Sendable () -> Date
        var uploadObserved: (@Sendable (DatabaseReference, Data, CloudFileMetadata) async throws -> CloudFileMetadata?)?
        var queue: PendingUploadQueue.Environment = .live
        var revisionIdentifiesContent: @Sendable (DatabaseReference, String?) -> Bool = { reference, revision in
            guard let metadata = reference.cloudSyncMetadata,
                  let provider = CloudProviderRegistry.provider(for: metadata.provider) else { return false }
            return provider.revisionIdentifiesContent(revision)
        }
        var writeGuarantee: @Sendable (DatabaseReference, String?, Int) -> CloudWriteGuarantee = { reference, rev, count in
            guard let metadata = reference.cloudSyncMetadata,
                  let provider = CloudProviderRegistry.provider(for: metadata.provider) else { return .preflightOnly }
            return provider.writeGuarantee(expectedRev: rev, byteCount: count)
        }
        var replaceFile: @Sendable (Data, URL, Data?, DatabaseReference) throws -> LocalDatabaseSaver.ReplaceOutcome = { data, url, sha, reference in
            var authorization = LocalDatabaseSaver.ReplacementAuthorization(databaseID: reference.id,
                enforcesEpoch: false, targetIsSharedCopy: true)
            if let context = mergeContext {
                authorization.cacheLease = context.lease
                authorization.coordinatedFence = { target, replace in try context.withReplacementFence(at: target, replace) }
                authorization.beforeReplacement = { try context.claimReplacement() }
            }
            return try LocalDatabaseSaver.replaceFileAtomically(data, at: url, expectedSHA512: sha, authorization: authorization)
        }
        var rekeyRegistryIO: DurableFileWriteIO = .init()
        var rekeyReplacementIO: LocalDatabaseSaver.ReplacementIO = .init()
        var synchronizeCacheFile: @Sendable (URL) throws -> Void = CloudDatabaseSaver.synchronizeCacheFile
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
            now: LocalDatabaseSaver.Environment.live.now,
            uploadObserved: { reference, data, observed in
                guard let metadata = reference.cloudSyncMetadata,
                      let observedProvider = CloudProviderRegistry.provider(for: metadata.provider) as? any CloudObservedUploadProvider else {
                    return nil
                }
                return try await observedProvider.upload(accountId: metadata.accountId, fileId: metadata.fileId,
                                                         data: data, observed: observed, progress: { _ in })
            }
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
        keyChange: PendingUploadQueue.KeyChange? = nil
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
            keyChange: keyChange,
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
        keyChange: PendingUploadQueue.KeyChange? = nil,
        environment: Environment
    ) async throws -> SaveResult {
        if reference.isReadOnly {
            throw SaveError.databaseIsReadOnly
        }

        let keyChange = newCompositeKey == nil ? nil : (keyChange ?? Self.keyChange ?? PendingUploadQueue.KeyChange(
            keyFileBookmarkData: reference.keyFileBookmarkData, keyFileFilename: reference.keyFileFilename))
        guard reference.cloudSyncMetadata != nil else {
            throw SaveError.saveContextUnavailable
        }

        let backgroundTaskHandle = await environment.beginBackgroundTask("CloudDatabaseSaving")
        defer {
            Task { @MainActor in
                environment.endBackgroundTask(backgroundTaskHandle)
            }
        }

        let mergeContext = Self.mergeContext
        let rekeyTicket = Self.rekeyTicket
        let saveTicket = Self.saveTicket
        if let mergeContext {
            guard newCompositeKey == nil, encryptionSettings == nil else { throw SaveError.saveContextUnavailable }
            try mergeContext.begin(reference: reference, remoteSHA512: reconciledRemoteSHA512)
        }
        do { return try await Task.detached(priority: .utility) {
            try await Self.$mergeContext.withValue(mergeContext) { try await Self.$rekeyTicket.withValue(rekeyTicket) { try await Self.$saveTicket.withValue(saveTicket) { try await saveOffMain(
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
                keyChange: keyChange,
                environment: environment
            ) } } }
        }.value } catch {
            let requiresRecovery: Bool
            do {
                let journal = try PendingUploadQueue.readJournal(for: reference.id, environment: environment.queue)
                for stored in journal where stored.marker.journalVersion != nil {
                    _ = try PendingUploadQueue.readImmutablePayload(stored, environment: environment.queue)
                }
                requiresRecovery = journal.contains {
                    [.prepared, .attempting, .confirmed, .recoveryRequired, .invalid].contains(CloudJournalDecision.state(of: $0.marker)) || $0.marker.keyChange != nil
                }
            } catch { requiresRecovery = true }
            if requiresRecovery { throw CloudSaveRecoveryWarning() }
            throw error
        }
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
        keyChange: PendingUploadQueue.KeyChange?,
        environment: Environment
    ) async throws -> SaveResult {
        let existing = try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue) {
            try PendingUploadQueue.recoverLocalCommits(for: reference.id, environment: environment.queue)
            return try PendingUploadQueue.readJournal(for: reference.id, environment: environment.queue)
        }
        guard CloudJournalDecision.permitsMutation(existing.map(\.marker), changingKey: keyChange != nil),
              mergeContext != nil || !existing.contains(where: { $0.marker.journalVersion == nil }) else {
            throw SaveError.saveContextUnavailable
        }
        let cacheURL = environment.cacheURL(reference)
        let currentData = try mergeContext?.readBeforeEncryption() ?? environment.readData(cacheURL)
        let currentSHA512 = FileDigest.sha512(currentData)
        let localBaseline = mergeContext?.localBaseline ?? baseline
        guard localBaseline.covers(currentSHA512) else {
            return .conflict(remoteSHA512: currentSHA512, remoteData: currentData)
        }

        // A rekey is online-only; no journal or local mutation precedes this probe.
        if newCompositeKey != nil {
            guard keyChange != nil else { throw SaveError.saveContextUnavailable }
            let remoteMetadata = try await environment.getMetadata(reference)
            let remoteBytes = try await environment.downloadRemoteData(reference)
            guard baseline.covers(FileDigest.sha512(remoteBytes)) else {
                return .conflict(remoteSHA512: FileDigest.sha512(remoteBytes), remoteData: remoteBytes)
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

        let ticket = keyChange == nil ? nil : Self.rekeyTicket
        let saveTicket = keyChange == nil ? Self.saveTicket : nil
        if let mergeContext, let saveTicket, mergeContext.operationID != saveTicket.operationID {
            throw SaveError.saveContextUnavailable
        }
        ticket?.prepare(FileDigest.sha512(newData))
        saveTicket?.prepare(FileDigest.sha512(newData))
        var intent: PendingUploadQueue.StoredMarker?
        let replacement = try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue) {
            try mergeContext?.validateBeforePreparation()
            let latest = try environment.readData(cacheURL)
            guard FileDigest.sha512(latest) == currentSHA512 else { return LocalDatabaseSaver.ReplaceOutcome.changed(currentData: latest) }
            guard let latestReference = DatabaseListStore.databases.first(where: { $0.id == reference.id }) else {
                throw SaveError.saveContextUnavailable
            }
            guard latestReference.cloudSyncMetadata?.keyEpoch == reference.cloudSyncMetadata?.keyEpoch,
                  latestReference.lastMasterKeyChangeAt == reference.lastMasterKeyChangeAt else { throw SaveError.saveContextUnavailable }
            var prepared = try PendingUploadQueue.prepare(
                reference: mergeContext?.ownerReference ?? reference, currentData: currentData, intendedData: newData,
                cacheURL: cacheURL, keyChange: keyChange,
                remoteBaseSHA512: baseline.reconciledRemoteSHA512, authenticatedMergeSources: mergeContext?.sources, operationID: mergeContext?.operationID ?? ticket?.operationID ?? saveTicket?.operationID ?? UUID(), environment: environment.queue
            )
            intent = prepared
            if keyChange != nil { return .replaced() }
            let outcome: LocalDatabaseSaver.ReplaceOutcome
            do { outcome = try environment.replaceFile(newData, cacheURL, currentSHA512, reference) }
            catch let failure as LocalSaveBeforeReplacementFailure {
                guard (try? PendingUploadQueue.dropIfUnchanged(prepared, environment: environment.queue)) == true else { throw CloudSaveRecoveryWarning() }
                throw failure
            }
            let didReplace: Bool
            switch outcome {
            case .replaced, .replacedWithoutConfirmedDurability, .replacedWithUnconfirmedBookkeeping: didReplace = true
            case .changed, .indeterminate: didReplace = false
            }
            guard didReplace else {
                if case .changed = outcome {
                    _ = try PendingUploadQueue.dropIfUnchanged(prepared, environment: environment.queue)
                }
                return outcome
            }
            prepared.marker.openTimeSHA512 = FileDigest.sha512(newData)
            guard let finalized = try? PendingUploadQueue.finalize(prepared, environment: environment.queue) else {
                intent = prepared
                return .replacedWithUnconfirmedBookkeeping()
            }
            intent = finalized
            guard case .published? = try? PendingUploadQueue.recoverLocalCommit(finalized, environment: environment.queue) else {
                return .replacedWithUnconfirmedBookkeeping()
            }
            return outcome
        }
        if case .changed(let bytes) = replacement { return .conflict(remoteSHA512: FileDigest.sha512(bytes), remoteData: bytes) }
        guard let intent else { throw SaveError.saveContextUnavailable }
        if case .indeterminate = replacement { return .indeterminate(scope: .sharedCopy) }
        if keyChange != nil {
            guard let result = try await deliver(intent, reference: reference, environment: environment) else {
                if DatabaseListStore.databases.first(where: { $0.id == reference.id })?.cloudSyncMetadata?.keyEpoch == keyChange?.epoch {
                    throw SaveError.rekeyAppliedRemotely
                }
                throw SaveError.saveContextUnavailable
            }
            switch result {
            case .saved: break
            case .retained(let updated):
                let observed = try PendingUploadQueue.readJournal(for: reference.id, environment: environment.queue).first { $0.id == intent.id }
                let installed = keyChange.flatMap { change in
                    updated.lastMasterKeyChangeAt.map { date in
                        intent.marker.binding?.matchesInstalled(reference: updated, operationID: intent.id, keyChange: change, committedAt: date) == true
                    }
                } == true
                guard (observed?.marker.confirmedAt != nil || installed),
                      (try? environment.readData(cacheURL)).map(FileDigest.sha512) == FileDigest.sha512(newData) else {
                    return .indeterminate(scope: .sharedCopy)
                }
                return .committedWithoutConfirmedDurability(newSHA512: FileDigest.sha512(newData), expressKey: expressKey, scope: .recoveryRecord)
            case .conflict: throw CloudProviderError.conflict(remoteRev: nil)
            }
        } else {
            if let mergeContext {
                if case .replaced = replacement { try mergeContext.recordDurableOutput(replacement, sha512: FileDigest.sha512(newData)) }
                // The merge's own drain must not take its lease before the exact source handoff ends.
                mergeContext.deferEnqueuedNotification(environment.queue.postDarwinNotification)
            } else {
                PendingUploadQueue.postEnqueuedNotification(environment: environment.queue)
            }
        }
        try? environment.pruneBackups(reference, 5)
        switch replacement {
        case .replacedWithoutConfirmedDurability: return .committedWithoutConfirmedDurability(newSHA512: FileDigest.sha512(newData), expressKey: expressKey, scope: .sharedCopy)
        case .replacedWithUnconfirmedBookkeeping: return .committedWithoutConfirmedDurability(newSHA512: FileDigest.sha512(newData), expressKey: expressKey, scope: .recoveryRecord)
        case .indeterminate: return .indeterminate(scope: .sharedCopy)
        case .replaced, .changed: return .saved(newSHA512: FileDigest.sha512(newData), expressKey: expressKey)
        }
    }

    private static func recordIssue(_ error: Error, reference: DatabaseReference) {
        guard let metadata = reference.cloudSyncMetadata else { return }
        DatabaseListStore.updateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: metadata, observedReference: reference) {
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

    /// Confirmed delivery reconciles local durability without another provider request.
    private static func deliverJournal(
        _ snapshot: PendingUploadQueue.StoredMarker, reference: DatabaseReference,
        environment: Environment = .live
    ) async throws -> PendingUploadPushResult? {
        var reference = reference
        guard var stored = try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue, {
            try DatabaseListStore.recoverCloudKeyFilePreference(for: reference.id, queue: environment.queue)
            try PendingUploadQueue.recoverLocalCommits(for: reference.id, environment: environment.queue)
            guard let currentReference = try DatabaseListStore.readDatabasesStrict().first(where: { $0.id == reference.id }) else {
                throw SaveError.saveContextUnavailable
            }
            reference = currentReference
            try PendingUploadQueue.preserveLegacyPayloads(for: reference, environment: environment.queue)
            guard let current = try PendingUploadQueue.readJournal(for: reference.id, environment: environment.queue).first(where: { $0.id == snapshot.id }) else {
                return nil as PendingUploadQueue.StoredMarker?
            }
            return try PendingUploadQueue.recoverPrepared(current, environment: environment.queue)
        }) else { return nil }
        let isInstalledRekey = stored.marker.confirmedAt.flatMap { date in
            stored.marker.keyChange.flatMap { change in
                stored.marker.binding?.matchesInstalled(reference: reference, operationID: stored.id, keyChange: change, committedAt: date)
            }
        } == true
        guard PendingUploadQueue.hasBoundAuthority(stored, reference: reference) || isInstalledRekey else {
            if stored.marker.binding == nil, stored.marker.journalVersion == nil,
               stored.marker.isPayloadFinalized != false,
               stored.marker.uploadAttemptID == nil || stored.marker.attemptIsFenced == true {
                _ = try PendingUploadQueue.markConflicted(stored, environment: environment.queue)
                return .conflict(remoteRev: nil)
            }
            return .retained(updatedReference: reference)
        }
        guard let binding = stored.marker.binding,
              reference.cloudSyncMetadata?.localHeadOperationID == binding.baseline?.headOperationID
                || reference.cloudSyncMetadata?.localHeadOperationID == stored.id
                || PendingUploadQueue.localDescendantOwner(of: stored, reference: reference, environment: environment.queue) != nil else {
            return .retained(updatedReference: reference)
        }
        if stored.marker.confirmedAt != nil {
            return try recoverConfirmed(stored, reference: reference, environment: environment)
        }
        let marker = stored.marker
        let all = try PendingUploadQueue.readJournal(for: reference.id, environment: environment.queue)
        let bytes = try marker.intendedPayloadPath == nil
            ? environment.readData(environment.cacheURL(reference))
            : PendingUploadQueue.readImmutablePayload(stored, environment: environment.queue)
        let payloadSHA = marker.intendedPayloadSHA512 ?? marker.openTimeSHA512
        let siblings = all.filter { $0.id != stored.id }
        let decision = CloudJournalDecision.delivery(.init(marker: marker, siblings: siblings.map(\.marker),
            siblingIDs: Set(siblings.map(\.id)), epoch: reference.cloudSyncMetadata?.keyEpoch, lastMasterKeyChangeAt: reference.lastMasterKeyChangeAt,
            payloadMatches: FileDigest.sha512(bytes) == payloadSHA))
        switch decision {
        case .reconcile: return try recoverConfirmed(stored, reference: reference, environment: environment)
        case .retain: return .retained(updatedReference: reference)
        case .conflict:
            try PendingUploadQueue.markDatabaseConflicted(for: reference.id, environment: environment.queue)
            return .conflict(remoteRev: nil)
        case .dispatch: break
        }
        let remoteMetadata = try await environment.getMetadata(reference)
        let baseUnchanged = reference.cloudSyncMetadata.map {
            CloudJournalDecision.trustedBaseUnchanged(marker: stored.marker, recorded: $0, remote: remoteMetadata,
                revisionIsContentIdentity: environment.revisionIdentifiesContent(reference, remoteMetadata.rev))
        } ?? false
        if !baseUnchanged {
            let remoteBytes = try await environment.downloadRemoteData(reference)
            let remoteSHA = FileDigest.sha512(remoteBytes)
            guard remoteSHA == marker.remoteBaseSHA512 else {
                if reference.cloudProviderKind == .googleDrive {
                    stored.marker.uploadRecoveryIssue = .conflict
                    stored.marker.isConflicted = true
                    _ = try PendingUploadQueue.update(stored, environment: environment.queue)
                } else {
                    try PendingUploadQueue.markDatabaseConflicted(for: reference.id, environment: environment.queue)
                }
                return .conflict(remoteRev: remoteMetadata.rev)
            }
        }
        let expectedRev = remoteMetadata.rev
        guard environment.writeGuarantee(reference, expectedRev, bytes.count) != .disabled else {
            throw CloudProviderError.invalidConfiguration
        }
        try Task.checkCancellation()
        guard let dispatch = CloudJournalDecision.transition(from: CloudJournalDecision.state(of: stored.marker), on: .dispatch) else {
            return .retained(updatedReference: reference)
        }
        var response: CloudFileMetadata?
        do {
            for effect in dispatch.effects {
                switch effect {
                case .persist:
                    stored.marker.expectedRev = expectedRev
                    stored.marker.uploadAttemptID = UUID()
                    stored.marker.attemptIsFenced = false
                    stored = try PendingUploadQueue.update(stored, environment: environment.queue)
                case .upload:
                    if let result = try await environment.uploadObserved?(reference, bytes, remoteMetadata) {
                        response = result
                    } else {
                        response = try await environment.upload(reference, bytes, expectedRev, { _ in })
                    }
                default: throw SaveError.saveContextUnavailable
                }
            }
        }
        catch {
            if let recovery = error as? CloudUploadRecovery {
                stored.marker.uploadRecoveryIssue = recovery.syncIssue
                stored.marker.observedUploadRevision = recovery.observedRevision
                switch recovery {
                case .preflightConflict(let remoteRevision):
                    stored.marker.isConflicted = true
                    stored.marker.attemptIsFenced = true
                    _ = try PendingUploadQueue.update(stored, environment: environment.queue)
                    return .conflict(remoteRev: remoteRevision)
                default:
                    _ = try PendingUploadQueue.update(stored, environment: environment.queue)
                    throw recovery
                }
            }
            if let failure = error as? CloudUploadFailure, failure.provesNoCommit,
               let rejected = CloudJournalDecision.transition(from: .attempting, on: .rejectedBeforeCommit) {
                for effect in rejected.effects {
                    guard effect == .persist else { throw SaveError.saveContextUnavailable }
                    stored.marker.attemptIsFenced = true
                    stored = try PendingUploadQueue.update(stored, environment: environment.queue)
                }
            }
            throw error
        }
        guard let response, let acknowledged = CloudJournalDecision.transition(from: .attempting, on: .acknowledged) else {
            throw SaveError.saveContextUnavailable
        }
        for effect in acknowledged.effects {
            switch effect {
            case .persist:
                stored.marker.confirmedRemoteRev = response.rev
                stored.marker.confirmedRemoteHash = response.contentHash
                stored.marker.confirmedAt = .now
                stored = try PendingUploadQueue.update(stored, environment: environment.queue)
            case .publishReference: return try finishDelivery(stored, reference: reference, bytes: bytes, environment: environment)
            default: throw SaveError.saveContextUnavailable
            }
        }
        throw SaveError.saveContextUnavailable
    }

    /// Completes only local reconciliation of an already-confirmed journal; never contacts a provider.
    static func recoverConfirmed(
        _ snapshot: PendingUploadQueue.StoredMarker, reference: DatabaseReference,
        environment: Environment = .live
    ) throws -> PendingUploadPushResult? {
        guard let stored = try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue, {
            try PendingUploadQueue.preserveLegacyPayloads(for: reference, environment: environment.queue)
            return PendingUploadQueue.listMarkers(for: reference.id, environment: environment.queue).first(where: { $0.id == snapshot.id })
        }), stored.marker.confirmedAt != nil else { return nil }
        guard stored.marker.intendedPayloadPath != nil,
              stored.marker.isPayloadFinalized == true || stored.marker.keyChange != nil else {
            throw SaveError.saveContextUnavailable
        }
        do {
            let bytes = try journalPayload(stored, environment: environment)
            let result = try finishDelivery(stored, reference: reference, bytes: bytes, environment: environment)
            if stored.marker.keyChange != nil {
                if case .saved = result { RekeyTicket.complete(stored.id) }
                else { RekeyTicket.signal(stored.id) }
            }
            return result
        } catch {
            if stored.marker.keyChange != nil {
                RekeyTicket.signal(stored.id)
                throw SaveError.rekeyAppliedRemotely
            }
            throw error
        }
    }

    private static func journalPayload(_ stored: PendingUploadQueue.StoredMarker, environment: Environment) throws -> Data {
        try PendingUploadQueue.readImmutablePayload(stored, environment: environment.queue)
    }

    /// Caller holds the commit lock and has established the payload owner's current head and epoch.
    private static func restoreConfirmedCache(
        _ owner: PendingUploadQueue.StoredMarker, reference: DatabaseReference, bytes: Data,
        allowMissing: Bool = true, beforeReplacement: () -> Void = {}, environment: Environment
    ) throws {
        let cacheURL = environment.cacheURL(reference)
        let payloadSHA = FileDigest.sha512(bytes)
        let previous = try? environment.readData(cacheURL)
        let previousSHA = previous.map(FileDigest.sha512)
        guard previousSHA == payloadSHA || (previousSHA != nil && previousSHA == owner.marker.predecessorSHA512)
            || (allowMissing && previous == nil) else { throw SaveError.saveContextUnavailable }
        beforeReplacement()
        if previousSHA != payloadSHA {
            if let previous {
                let hasOtherPending = PendingUploadQueue.listMarkers(for: reference.id, environment: environment.queue).contains { $0.id != owner.id }
                let filename = backupFilename(for: .now)
                let retainedFilename = hasOtherPending ? String(filename.dropLast(5)) + DatabaseListStore.retainedBackupSuffix + ".kdbx" : filename
                let backupURL = environment.backupDirectoryURL(reference).appendingPathComponent(retainedFilename)
                try environment.createDirectory(backupURL.deletingLastPathComponent())
                try environment.writeBackup(previous, backupURL)
                let outcome = try environment.replaceFile(bytes, cacheURL, previousSHA, reference)
                switch outcome {
                case .replaced, .replacedWithoutConfirmedDurability, .replacedWithUnconfirmedBookkeeping: break
                case .changed, .indeterminate: throw SaveError.saveContextUnavailable
                }
            } else {
                guard try environment.installMissingCache(bytes, cacheURL) else { throw SaveError.saveContextUnavailable }
            }
        }
        guard FileDigest.sha512(try environment.readData(cacheURL)) == payloadSHA else {
            throw SaveError.saveContextUnavailable
        }
    }

    private static func verifiedCacheReference(
        owner: PendingUploadQueue.StoredMarker, referenceID: UUID, environment: Environment
    ) -> DatabaseReference? {
        guard let current = try? DatabaseListStore.readDatabasesStrict().first(where: { $0.id == referenceID }),
              PendingUploadQueue.hasBoundAuthority(owner, reference: current)
                || (owner.marker.keyChange.flatMap { change in
                    owner.marker.confirmedAt.flatMap { date in
                        owner.marker.binding?.matchesInstalled(reference: current, operationID: owner.id, keyChange: change, committedAt: date)
                    }
                } == true),
              current.cloudSyncMetadata?.keyEpoch == owner.marker.keyEpoch,
              current.cloudSyncMetadata?.localHeadOperationID == owner.id,
              (try? environment.readData(environment.cacheURL(current))).map(FileDigest.sha512) == (owner.marker.intendedPayloadSHA512 ?? owner.marker.openTimeSHA512) else { return nil }
        return current
    }

    private static func finishDelivery(
        _ stored: PendingUploadQueue.StoredMarker, reference: DatabaseReference,
        bytes: Data, environment: Environment
    ) throws -> PendingUploadPushResult {
        do {
            if stored.marker.keyChange != nil {
                let snapshot = try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue) {
                    guard let exact = try PendingUploadQueue.readJournal(for: reference.id, environment: environment.queue).first(where: { $0.id == stored.id }),
                          exact.marker == stored.marker else { throw SaveError.rekeyAppliedRemotely }
                    return exact
                }
                let publication = DatabaseListStore.publishConfirmedCloudRekey(snapshot, cache: environment.cacheURL(reference), bytes: bytes,
                    queue: environment.queue, registryIO: environment.rekeyRegistryIO, replacementIO: environment.rekeyReplacementIO,
                    backup: { current, previous in
                        let directory = environment.backupDirectoryURL(current)
                        try environment.createDirectory(directory)
                        try environment.writeBackup(previous, directory.appendingPathComponent(backupFilename(for: environment.now())))
                    }, deleteOldKeys: { current in
                        KeychainService.deleteCompositeKey(for: current.id)
                        if let legacy = current.legacyKeychainFilename { KeychainService.deleteLegacyCompositeKey(forFilename: legacy) }
                    })
                switch publication {
                case .durable(let updated): return .saved(updatedReference: updated)
                case .retirementUnconfirmed(let updated): return .retained(updatedReference: updated)
                case .cacheUnconfirmed, .registryNotPublished, .registryUnconfirmed:
                    return .retained(updatedReference: reference)
                case .rejected: throw SaveError.rekeyAppliedRemotely
                }
            }
            return try PendingUploadQueue.withCommitLock(for: reference.id, environment: environment.queue) {
                let payloadSHA = FileDigest.sha512(bytes)
                try PendingUploadQueue.recoverLocalCommits(for: reference.id, environment: environment.queue)
                guard var current = try DatabaseListStore.readDatabasesStrict().first(where: { $0.id == reference.id }) else {
                    throw SaveError.saveContextUnavailable
                }
                let descendant = stored.marker.keyChange == nil
                    ? try PendingUploadQueue.localDescendantOwner(of: stored, reference: current, environment: environment.queue) : nil
                let completion = CloudJournalDecision.completion(.init(marker: stored.marker, operationID: stored.id,
                    head: current.cloudSyncMetadata?.localHeadOperationID, epoch: current.cloudSyncMetadata?.keyEpoch,
                    lastMasterKeyChangeAt: current.lastMasterKeyChangeAt, hasVerifiedDescendant: descendant != nil))
                guard completion != .reject else { throw SaveError.saveContextUnavailable }
                if let rekey = stored.marker.keyChange {
                    guard let binding = stored.marker.binding, let committedAt = stored.marker.confirmedAt,
                          binding.matchesInstalled(reference: current, operationID: stored.id, keyChange: rekey, committedAt: committedAt),
                          (try? environment.readData(environment.cacheURL(current))).map(FileDigest.sha512) == stored.marker.intendedPayloadSHA512 else {
                        throw SaveError.rekeyAppliedRemotely
                    }
                }
                guard PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue).contains(where: {
                    $0.id == stored.id && $0.marker == stored.marker
                }) else { throw SaveError.saveContextUnavailable }
                let owner: PendingUploadQueue.StoredMarker
                if stored.marker.keyChange != nil {
                    owner = stored
                } else {
                    if completion == .restoreHead { owner = stored }
                    else {
                        guard completion == .restoreDescendant, let descendant else { throw SaveError.saveContextUnavailable }
                        owner = descendant
                    }
                    let ownerBytes = try journalPayload(owner, environment: environment)
                    try restoreConfirmedCache(owner, reference: current, bytes: ownerBytes, environment: environment)
                }
                do {
                    try environment.synchronizeCacheFile(environment.cacheURL(current))
                    try environment.synchronizeCacheDirectory(environment.cacheURL(current).deletingLastPathComponent())
                }
                catch { return .retained(updatedReference: current) }
                guard let latest = verifiedCacheReference(owner: owner, referenceID: current.id, environment: environment) else {
                    throw SaveError.saveContextUnavailable
                }
                current = latest
                var ancestors = Set(stored.marker.absorbedOperationIDs ?? [])
                if let predecessor = stored.marker.predecessorOperationID { ancestors.insert(predecessor) }
                ancestors.remove(stored.id)
                let pendingIDs = Set(try environment.queue.listDirectory(stored.fileURL.deletingLastPathComponent())
                    .filter { $0.pathExtension == "json" }
                    .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
                if !ancestors.isDisjoint(with: pendingIDs) { return .retained(updatedReference: current) }
                let cacheSHA = owner.marker.intendedPayloadSHA512 ?? owner.marker.openTimeSHA512
                if cacheSHA == payloadSHA, current.cloudSyncMetadata?.localHeadOperationID == stored.id,
                   let observed = current.cloudSyncMetadata {
                    let remaining = PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue).filter { $0.id != stored.id }
                    let publication = DatabaseListStore.compareAndUpdateCloudSyncMetadata(for: current.id, ifUnchangedFrom: observed, observedReference: current, mutate: {
                        if let rev = stored.marker.confirmedRemoteRev { $0.remoteRev = rev }
                        if let hash = stored.marker.confirmedRemoteHash { $0.remoteContentHash = hash }
                        $0.remoteModifiedAt = stored.marker.confirmedAt
                        $0.lastSyncedAt = remaining.isEmpty ? stored.marker.confirmedAt : nil
                        $0.lastSyncIssue = nil
                    })
                    guard case .published(let updated) = publication else { throw SaveError.saveContextUnavailable }
                    current = updated
                }
                // A confirmed parent transfers its exact remote ancestry before its journal can disappear.
                for var child in PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue)
                where child.marker.predecessorOperationID == stored.id || child.marker.absorbedOperationIDs?.contains(stored.id) == true {
                    child.marker.expectedRev = stored.marker.confirmedRemoteRev
                    child.marker.baseRev = stored.marker.confirmedRemoteRev
                    child.marker.remoteBaseSHA512 = payloadSHA
                    _ = try PendingUploadQueue.update(child, environment: environment.queue)
                }
                guard verifiedCacheReference(owner: owner, referenceID: current.id, environment: environment) != nil else {
                    throw SaveError.saveContextUnavailable
                }
                guard let reconciled = CloudJournalDecision.transition(from: CloudJournalDecision.state(of: stored.marker), on: .localReconciled) else {
                    throw SaveError.saveContextUnavailable
                }
                for effect in reconciled.effects {
                    guard effect == .retire else { throw SaveError.saveContextUnavailable }
                    if try !PendingUploadQueue.dropIfUnchanged(stored, environment: environment.queue),
                       PendingUploadQueue.listMarkers(for: current.id, environment: environment.queue).contains(where: { $0.id == stored.id }) {
                        return .retained(updatedReference: current)
                    }
                }
                return .saved(updatedReference: current)
            }
        } catch {
            if stored.marker.keyChange != nil { throw SaveError.rekeyAppliedRemotely }
            throw error
        }
    }

    private static func synchronizeCacheFile(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func installMissingCache(_ bytes: Data, _ cacheURL: URL) throws -> Bool {
        let directory = cacheURL.deletingLastPathComponent()
        guard let anchor = AppGroupContainer.resolvedURL else { throw CocoaError(.fileWriteNoPermission) }
        try createDurableDirectory(at: directory, anchor: anchor)
        let stagedURL = directory.appendingPathComponent(".commit-recovery-\(UUID().uuidString).kdbx")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try writeAtomicallyAndDurably(bytes, to: stagedURL)
        // An intervening writer wins; never replace a cache that appeared after the missing-file read.
        guard Darwin.link(stagedURL.path, cacheURL.path) == 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    /// Whether the remote head differs from the state this save was based on —
    /// the conflict-versus-upload gate. A recorded rev makes it exact. A nil
    /// rev is common (pre-rev-tracking references, offline opens, ETag-less
    /// WebDAV) and there a bare `remote.rev != expectedRev` passes vacuously,
    /// turning the upload into an unconditional overwrite (Dropbox
    /// `WriteMode.overwrite`, OneDrive `conflictBehavior=replace` without
    /// `If-Match`). So nil falls back to metadata: the reported content hash
    /// must match the recorded one, and an unrecorded rev is conflict-suspect.
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
        try await downloadRemoteSnapshot(provider: provider, metadata: metadata).data
    }

    static func downloadRemoteSnapshot(
        provider: CloudProvider, metadata: CloudSyncMetadata,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (data: Data, metadata: CloudFileMetadata?) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let observed = try await provider.download(
            accountId: metadata.accountId,
            fileId: metadata.fileId,
            to: tempURL,
            progress: progress
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
        return (try Data(contentsOf: tempURL), observed)
    }
}
