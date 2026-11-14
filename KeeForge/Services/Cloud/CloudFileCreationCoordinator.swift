import Darwin
import Foundation

/// Create-only delivery retains encrypted ownership before any provider mutation.
enum CloudFileCreationCoordinator {
    typealias Intent = PendingUploadQueue.CreationIntent
    struct RecoveryRequired: Error, LocalizedError {
        let operationID: UUID
        var errorDescription: String? { String(localized: "Cloud creation needs recovery. Keep the encrypted copy and review pending cloud creations before trying again.") }
    }
    struct Environment: Sendable {
        var queue: PendingUploadQueue.Environment = .live
        var createFile: @Sendable (String, String, String, Data) async throws -> CloudCreatedFile = { providerID, accountID, path, bytes in
            guard let provider = CloudProviderRegistry.provider(for: providerID), provider.isAuthenticated(accountId: accountID) else { throw CloudUploadFailure(underlying: .notAuthenticated, outcome: .notDispatched) }
            return try await provider.createFile(accountId: accountID, path: path, data: bytes, progress: { _ in })
        }
        var publish: @Sendable (DatabaseReference, Data) throws -> DatabaseReference = { try DatabaseListStore.registerCloudCreation($0, encryptedBytes: $1) }
        static let live = Environment()
    }

    static func assertDestinationAvailable(provider: String, accountID: String, target: String, environment: Environment = .live) throws {
        if let pending = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: {
            $0.provider == provider && $0.accountID == accountID && $0.target == target
        }) { throw RecoveryRequired(operationID: pending.operationID) }
    }

    static func create(
        operationID: UUID, ownerDatabaseID: UUID, provider: String, accountID: String,
        target: String, bytes: Data, referenceTemplate: DatabaseReference,
        isConflictCopy: Bool = false, environment: Environment = .live
    ) async throws -> DatabaseReference {
        let lease = try acquireLease(operationID, environment)
        defer { releaseLease(lease); environment.queue.postDarwinNotification() }
        let intent = try withReservationLock(environment) {
            let records = try PendingUploadQueue.listCreations(includingCompleted: true, environment: environment.queue)
            let sha = FileDigest.sha512(bytes)
            if let existing = records.first(where: { $0.operationID == operationID }) {
                guard existing.ownerDatabaseID == ownerDatabaseID, existing.provider == provider,
                      existing.accountID == accountID, existing.target == target,
                      existing.payloadSHA512 == sha, existing.referenceTemplate == referenceTemplate else { throw RecoveryRequired(operationID: operationID) }
                return existing
            }
            guard !records.contains(where: { $0.phase != .completed && $0.provider == provider && $0.accountID == accountID && $0.target == target }) else {
                throw RecoveryRequired(operationID: operationID)
            }
            let payload = PendingUploadQueue.creationPayloadURL(ownerDatabaseID: ownerDatabaseID, operationID: operationID, environment: environment.queue)
            try environment.queue.createDirectory(payload.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: payload.path) {
                guard try environment.queue.readData(payload) == bytes else { throw RecoveryRequired(operationID: operationID) }
            } else { try environment.queue.writeMarkerAtomically(bytes, payload) }
            var intent = Intent(operationID: operationID, ownerDatabaseID: ownerDatabaseID, provider: provider,
                accountID: accountID, target: target, payloadSHA512: sha,
                payloadPath: try PendingUploadQueue.makeRelativeAppGroupPath(for: payload, environment: environment.queue),
                referenceTemplate: referenceTemplate, isConflictCopy: isConflictCopy)
            intent.isPaused = true
            try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
            return intent
        }
        return try await deliver(intent, environment: environment)
    }

    static func resume(operationID: UUID, unpausing: Bool = true, environment: Environment = .live) async throws -> DatabaseReference {
        guard unpausing else { throw RecoveryRequired(operationID: operationID) }
        let lease = try acquireLease(operationID, environment)
        defer { releaseLease(lease) }
        guard let intent = try PendingUploadQueue.listCreations(includingCompleted: true, environment: environment.queue).first(where: { $0.operationID == operationID }) else { throw CloudProviderError.fileNotFound }
        try environment.queue.removeItem(PendingUploadQueue.creationPauseURL(intent, environment: environment.queue))
        return try await deliver(intent, environment: environment)
    }

    static func cancel(operationID: UUID, environment: Environment = .live) throws {
        guard let intent = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: { $0.operationID == operationID }) else { return }
        try PendingUploadQueue.requestCreationPause(intent, environment: environment.queue)
    }

    static func export(_ intent: Intent, environment: Environment = .live) throws -> Data {
        let expected = PendingUploadQueue.creationPayloadURL(ownerDatabaseID: intent.ownerDatabaseID, operationID: intent.operationID, environment: environment.queue)
        guard intent.payloadPath == (try PendingUploadQueue.makeRelativeAppGroupPath(for: expected, environment: environment.queue)) else { throw RecoveryRequired(operationID: intent.operationID) }
        let bytes = try environment.queue.readData(expected)
        guard FileDigest.sha512(bytes) == intent.payloadSHA512 else { throw RecoveryRequired(operationID: intent.operationID) }
        return bytes
    }

    static func addReferenceOnly(for snapshot: Intent, selection: CloudDatabaseSelection, environment: Environment = .live) throws -> DatabaseReference {
        let lease = try acquireLease(snapshot.operationID, environment)
        defer { releaseLease(lease) }
        return try withReservationLock(environment) {
            guard let current = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: { $0.operationID == snapshot.operationID }),
                  current == snapshot, current.phase == .attempting, current.receipt == nil,
                  selection.provider == current.provider, selection.account.id == current.accountID else { throw RecoveryRequired(operationID: snapshot.operationID) }
            let reference = DatabaseListStore.addCloud(provider: selection.provider, accountId: selection.account.id, file: selection.file)
            guard DatabaseListStore.databases.contains(where: { $0.id == reference.id }) else { throw RecoveryRequired(operationID: snapshot.operationID) }
            return reference
        }
    }

    static func assertMutationAllowed(for reference: DatabaseReference, environment: Environment = .live) throws {
        try PendingUploadQueue.assertCreationAllowsMutation(reference, environment: environment.queue)
    }

    private static func deliver(_ original: Intent, environment: Environment) async throws -> DatabaseReference {
        var intent = original
        if intent.phase == .attempting { throw RecoveryRequired(operationID: intent.operationID) }
        if intent.phase == .completed {
            guard let receipt = intent.receipt,
                  let stored = DatabaseListStore.databases.first(where: { $0.id == receipt.id }),
                  stored.cloudSyncMetadata?.fileId == receipt.cloudSyncMetadata?.fileId,
                  stored.cloudSyncMetadata?.accountId == receipt.cloudSyncMetadata?.accountId,
                  stored.cloudSyncMetadata?.provider == receipt.cloudSyncMetadata?.provider else { throw RecoveryRequired(operationID: intent.operationID) }
            return stored
        }
        let bytes = try export(intent, environment: environment)
        if intent.receipt == nil {
            try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: PendingUploadQueue.creationPauseURL(intent, environment: environment.queue).path) else { throw RecoveryRequired(operationID: intent.operationID) }
            intent.phase = .attempting
            try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
            let created: CloudCreatedFile
            do { created = try await environment.createFile(intent.provider, intent.accountID, intent.target, bytes) }
            catch {
                if let failure = error as? CloudUploadFailure, failure.provesNoCommit {
                    intent.phase = .prepared
                    try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
                }
                throw RecoveryRequired(operationID: intent.operationID)
            }
            var reference = intent.referenceTemplate
            reference.source = .cloud(CloudSyncMetadata(provider: intent.provider, accountId: intent.accountID,
                fileId: created.file.id, displayPath: created.file.path, remoteContentHash: created.metadata.contentHash,
                remoteModifiedAt: created.metadata.modifiedDate, remoteRev: created.metadata.rev, lastSyncedAt: .now, lastSyncIssue: nil))
            reference.updateCloudSyncMetadata { $0.localHeadOperationID = intent.operationID }
            intent.receipt = reference
            intent.phase = .confirmed
            try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
        }
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: PendingUploadQueue.creationPauseURL(intent, environment: environment.queue).path), let receipt = intent.receipt else { throw RecoveryRequired(operationID: intent.operationID) }
        let registered = try environment.publish(receipt, bytes)
        intent.phase = .completed
        intent.receipt = registered
        try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
        return registered
    }

    private static func withReservationLock<T>(_ environment: Environment, _ body: () throws -> T) throws -> T {
        let root = environment.queue.appGroupContainerURL().appendingPathComponent("pending-upload-locks", isDirectory: true)
        try environment.queue.createDirectory(root)
        let fd = open(root.appendingPathComponent("creations.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private static func acquireLease(_ id: UUID, _ environment: Environment) throws -> Int32 {
        let root = environment.queue.appGroupContainerURL().appendingPathComponent("pending-upload-locks", isDirectory: true)
        try environment.queue.createDirectory(root)
        let fd = open(root.appendingPathComponent("creation-\(id).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw RecoveryRequired(operationID: id) }
        return fd
    }
    private static func releaseLease(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
}
