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
        var extractHeader: @Sendable (Data, Data) throws -> KDBXParser.Header
        var encryptDraft: @Sendable (DatabaseDraft, Data, KDBXParser.Header) throws -> Data
        var getMetadata: @Sendable (DatabaseReference) async throws -> CloudFileMetadata
        var upload: @Sendable (DatabaseReference, Data, String?, @escaping ProgressHandler) async throws -> CloudFileMetadata
        var downloadRemoteData: @Sendable (DatabaseReference) async throws -> Data
        var backupDirectoryURL: @Sendable (DatabaseReference) -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var writeBackup: @Sendable (Data, URL) throws -> Void
        var pruneBackups: @Sendable (DatabaseReference, Int) throws -> Void
        var now: @Sendable () -> Date
        var applyUploadedBytes: @Sendable (DatabaseReference, Data, CloudFileMetadata) throws -> DatabaseReference

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

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data,
        expectedRev: String?
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            expectedRev: expectedRev,
            environment: .live
        )
    }

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data,
        expectedRev: String?,
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
                openTimeSHA512: openTimeSHA512,
                expectedRev: expectedRev,
                environment: environment
            )
        }.value
    }

    private static func saveOffMain(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data,
        expectedRev: String?,
        environment: Environment
    ) async throws -> SaveResult {
        let cacheURL = environment.cacheURL(reference)
        let currentData = try environment.readData(cacheURL)
        let currentSHA512 = KDBXCrypto.sha512(currentData)
        guard currentSHA512 == openTimeSHA512 else {
            return .conflict(remoteSHA512: currentSHA512, remoteData: currentData)
        }

        let remoteMetadata = try await environment.getMetadata(reference)
        if let expectedRev, remoteMetadata.rev != expectedRev {
            return try await conflictResult(
                reference: reference,
                fallbackData: currentData,
                environment: environment
            )
        }

        let header = try environment.extractHeader(currentData, compositeKey)
        guard header.formatVersion.requiresReadOnlyMode == false else {
            throw SaveError.databaseIsReadOnly
        }
        let newData = try environment.encryptDraft(draft, compositeKey, header)

        do {
            let uploadedMetadata = try await environment.upload(reference, newData, expectedRev, { _ in })

            let backupDirectoryURL = environment.backupDirectoryURL(reference)
            try environment.createDirectory(backupDirectoryURL)

            let backupURL = backupDirectoryURL.appendingPathComponent(
                backupFilename(for: environment.now()),
                isDirectory: false
            )
            try environment.writeBackup(currentData, backupURL)

            _ = try environment.applyUploadedBytes(reference, newData, uploadedMetadata)
            try? environment.pruneBackups(reference, 5)

            return .saved(newSHA512: KDBXCrypto.sha512(newData))
        } catch let error as CloudProviderError {
            switch error {
            case .conflict:
                return try await conflictResult(
                    reference: reference,
                    fallbackData: currentData,
                    environment: environment
                )
            default:
                throw error
            }
        }
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

    private static func conflictResult(
        reference: DatabaseReference,
        fallbackData: Data,
        environment: Environment
    ) async throws -> SaveResult {
        let remoteData = (try? await environment.downloadRemoteData(reference)) ?? fallbackData
        return .conflict(
            remoteSHA512: KDBXCrypto.sha512(remoteData),
            remoteData: remoteData
        )
    }

    private static func pushPendingUploadOffMain(
        reference: DatabaseReference,
        encryptedBytes: Data,
        expectedRev: String?,
        environment: Environment
    ) async throws -> PendingUploadPushResult {
        let remoteMetadata = try await environment.getMetadata(reference)
        if let expectedRev, remoteMetadata.rev != expectedRev {
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
        return try Data(contentsOf: tempURL)
    }
}
