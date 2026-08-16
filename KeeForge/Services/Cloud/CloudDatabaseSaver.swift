import CryptoKit
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
        var encryptDraft: @Sendable (DatabaseDraft, SymmetricKey, KDBXParser.Header, KDFExecutionPolicy) throws -> Data
        var getMetadata: @Sendable (DatabaseReference) async throws -> CloudFileMetadata
        var upload: @Sendable (DatabaseReference, Data, String?, @escaping ProgressHandler) async throws -> CloudFileMetadata
        var downloadRemoteData: @Sendable (DatabaseReference) async throws -> Data
        var backupDirectoryURL: @Sendable (DatabaseReference) -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var writeBackup: @Sendable (Data, URL) throws -> Void
        var pruneBackups: @Sendable (DatabaseReference, Int) throws -> Void
        var now: @Sendable () -> Date
        var applyUploadedBytes: @Sendable (DatabaseReference, Data, CloudFileMetadata) throws -> DatabaseReference
        /// Drops pending AutoFill markers whose recorded payload SHA-512
        /// equals this save's open-time SHA-512. Defaulted so existing
        /// `Environment` literals keep compiling.
        var dropSupersededPendingUploads: @Sendable (_ databaseId: UUID, _ payloadSHA512: Data) -> Void = { databaseId, payloadSHA512 in
            PendingUploadQueue.dropMarkers(withPayloadSHA512: payloadSHA512, for: databaseId)
        }

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
            applyUploadedBytes: { reference, bytes, remoteMetadata in
                try CloudSyncCoordinator.applyUploadedBytesAfterSave(
                    reference: reference,
                    bytes: bytes,
                    remoteMetadata: remoteMetadata
                )
            }
        )
    }

    /// `newCompositeKey` rekeys the database: `compositeKey` still decrypts the
    /// cached file, `newCompositeKey` encrypts the uploaded bytes, and the
    /// result is verified to reopen with the new key before the upload.
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
        newCompositeKey: SymmetricKey? = nil
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
        environment: Environment
    ) async throws -> SaveResult {
        if reference.isReadOnly {
            throw SaveError.databaseIsReadOnly
        }

        guard reference.cloudSyncMetadata != nil else {
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
        environment: Environment
    ) async throws -> SaveResult {
        let cacheURL = environment.cacheURL(reference)
        let currentData = try environment.readData(cacheURL)
        let currentSHA512 = KDBXCrypto.sha512(currentData)
        guard baseline.covers(currentSHA512) else {
            return .conflict(remoteSHA512: currentSHA512, remoteData: currentData)
        }

        let remoteMetadata = try await environment.getMetadata(reference)
        var effectiveExpectedRev = expectedRev
        if let recordedMetadata = reference.cloudSyncMetadata,
           remoteHasDiverged(
               recorded: recordedMetadata,
               remote: remoteMetadata,
               expectedRev: expectedRev
           ) {
            // Revision tags can go stale on their own (OneDrive rewrites
            // cTag/eTag after async post-processing). A remote byte-identical
            // to what the user opened has no conflict to resolve: rebase onto
            // the fresh rev and proceed.
            let remoteData = try? await environment.downloadRemoteData(reference)
            guard let remoteData, baseline.covers(KDBXCrypto.sha512(remoteData)) else {
                let conflictData = remoteData ?? currentData
                return .conflict(remoteSHA512: KDBXCrypto.sha512(conflictData), remoteData: conflictData)
            }
            effectiveExpectedRev = remoteMetadata.rev
        }

        let header = try environment.extractHeader(currentData, compositeKey, kdfPolicy)
        guard header.formatVersion.requiresReadOnlyMode == false else {
            throw SaveError.databaseIsReadOnly
        }
        let newData = try environment.encryptDraft(draft, newCompositeKey ?? compositeKey, header, kdfPolicy)
        if let newCompositeKey {
            do {
                _ = try environment.extractHeader(newData, newCompositeKey, kdfPolicy)
            } catch {
                throw SaveError.rekeyVerificationFailed
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

        do {
            let uploadedMetadata = try await environment.upload(reference, newData, effectiveExpectedRev, { _ in })
            return try finishSave(
                reference: reference,
                newData: newData,
                uploadedMetadata: uploadedMetadata,
                openTimeSHA512: baseline.openTimeSHA512,
                rekeyed: newCompositeKey != nil,
                environment: environment
            )
        } catch let error as CloudProviderError {
            guard case .conflict = error else {
                throw error
            }

            // Same stale-tag guard for a provider-reported 412: byte-identical
            // remote content means the precondition failed on a mutated tag,
            // not a real edit. Refresh the rev and retry exactly once. The rev
            // must be captured BEFORE the byte check — an edit landing between
            // the two then fails the retry's If-Match instead of being
            // silently overwritten.
            let refreshedMetadata = try? await environment.getMetadata(reference)
            let remoteData = try? await environment.downloadRemoteData(reference)
            if let remoteData,
               baseline.covers(KDBXCrypto.sha512(remoteData)),
               let refreshedMetadata {
                do {
                    let uploadedMetadata = try await environment.upload(reference, newData, refreshedMetadata.rev, { _ in })
                    return try finishSave(
                        reference: reference,
                        newData: newData,
                        uploadedMetadata: uploadedMetadata,
                        openTimeSHA512: baseline.openTimeSHA512,
                        rekeyed: newCompositeKey != nil,
                        environment: environment
                    )
                } catch let retryError as CloudProviderError {
                    guard case .conflict = retryError else {
                        throw retryError
                    }
                }
            }

            let conflictData = remoteData ?? currentData
            return .conflict(remoteSHA512: KDBXCrypto.sha512(conflictData), remoteData: conflictData)
        }
    }

    private static func finishSave(
        reference: DatabaseReference,
        newData: Data,
        uploadedMetadata: CloudFileMetadata,
        openTimeSHA512: Data,
        rekeyed: Bool,
        environment: Environment
    ) throws -> SaveResult {
        // Markers whose payload hashes to this save's open-time SHA are
        // superseded by the upload above. Drop only AFTER
        // `applyUploadedBytes`: a concurrent AutoFill save's provisional
        // marker is what gates that call's pre-overwrite backup, so
        // dropping first would clobber its bytes uncovered.
        do {
            _ = try environment.applyUploadedBytes(reference, newData, uploadedMetadata)
        } catch {
            // After a rekey upload the remote already requires the new key;
            // a generic failure would read as "nothing changed". Callers key
            // off this to switch keychain/session to the key the remote needs.
            throw rekeyed ? SaveError.rekeyAppliedRemotely : error
        }
        environment.dropSupersededPendingUploads(reference.id, openTimeSHA512)
        try? environment.pruneBackups(reference, 5)

        return .saved(newSHA512: KDBXCrypto.sha512(newData))
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
        let remoteMetadata = try await environment.getMetadata(reference)
        if let recordedMetadata = reference.cloudSyncMetadata,
           remoteHasDiverged(
               recorded: recordedMetadata,
               remote: remoteMetadata,
               expectedRev: expectedRev
           ) {
            return .conflict(remoteRev: remoteMetadata.rev)
        }

        do {
            let uploadedMetadata = try await environment.upload(reference, encryptedBytes, expectedRev, { _ in })
            let updatedReference = try environment.applyUploadedBytes(reference, encryptedBytes, uploadedMetadata)
            return .saved(updatedReference: updatedReference)
        } catch let error as CloudProviderError {
            switch error {
            case .conflict(let remoteRev):
                return .conflict(remoteRev: remoteRev)
            default:
                throw error
            }
        }
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
