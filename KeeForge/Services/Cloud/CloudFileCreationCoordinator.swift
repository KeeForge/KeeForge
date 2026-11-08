import Darwin
import Foundation

/// The pending-upload delivery owner for create-only operations, including registration recovery.
enum CloudFileCreationCoordinator {
    typealias Intent = PendingUploadQueue.CreationIntent

    struct Environment: Sendable {
        var queue: PendingUploadQueue.Environment = .live
        var provider: @Sendable (String) -> (any CloudProvider)? = { CloudProviderRegistry.provider(for: $0) }
        var publish: @Sendable (DatabaseReference, Data) throws -> DatabaseReference = {
            try DatabaseListStore.registerCloudCreation($0, encryptedBytes: $1)
        }
        var completedReference: @Sendable (Intent) throws -> DatabaseReference = { intent in
            guard let receipt = intent.receipt,
                  let stored = DatabaseListStore.databases.first(where: { $0.id == receipt.id }),
                  stored.cloudSyncMetadata == receipt.cloudSyncMetadata,
                  stored.keyFileBookmarkData == receipt.keyFileBookmarkData,
                  stored.keyFileFilename == receipt.keyFileFilename,
                  let cache = DatabaseListStore.cachedDatabaseURL(for: stored),
                  KDBXCrypto.sha512(try Data(contentsOf: cache)) == intent.payloadSHA512 else {
                throw SaveError.saveContextUnavailable
            }
            return stored
        }
        static let live = Environment()
    }

    static func create(
        operationID: UUID, ownerDatabaseID: UUID, provider: String, accountID: String,
        target: CloudFileCreationTarget, bytes: Data, referenceTemplate: DatabaseReference,
        isConflictCopy: Bool = false, requestedTarget: CloudFileCreationTarget? = nil, environment: Environment = .live
    ) async throws -> DatabaseReference {
        let lease = try acquireLease(environment)
        defer { releaseLease(lease) }
        let records = try PendingUploadQueue.listCreations(includingCompleted: true, environment: environment.queue)
        let sha = KDBXCrypto.sha512(bytes)
        if let existing = records.first(where: { $0.operationID == operationID }) {
            guard existing.ownerDatabaseID == ownerDatabaseID, existing.provider == provider,
                  existing.accountID == accountID, existing.target == target,
                  existing.payloadSHA512 == sha, existing.referenceTemplate == referenceTemplate,
                  existing.isConflictCopy == isConflictCopy, existing.requestedTarget == requestedTarget else { throw CloudProviderError.conflict(remoteRev: nil) }
            return try await deliver(existing, environment: environment)
        }
        // A different preparation must never be fulfilled by an earlier key's ciphertext.
        guard !records.contains(where: {
            $0.phase != .completed && $0.provider == provider && $0.accountID == accountID &&
            $0.target == target
        }) else { throw CloudProviderError.conflict(remoteRev: nil) }
        let payloadURL = PendingUploadQueue.creationPayloadURL(ownerDatabaseID: ownerDatabaseID, operationID: operationID, environment: environment.queue)
        try environment.queue.createDirectory(payloadURL.deletingLastPathComponent())
        try environment.queue.writeMarkerAtomically(bytes, payloadURL)
        var intent = Intent(operationID: operationID, ownerDatabaseID: ownerDatabaseID, provider: provider,
            accountID: accountID, target: target, payloadSHA512: sha,
            payloadPath: try PendingUploadQueue.makeRelativeAppGroupPath(for: payloadURL, environment: environment.queue),
            referenceTemplate: referenceTemplate, isConflictCopy: isConflictCopy)
        intent.requestedTarget = requestedTarget
        try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
        environment.queue.postDarwinNotification()
        return try await deliver(intent, environment: environment)
    }

    static func resume(operationID: UUID, environment: Environment = .live) async throws -> DatabaseReference {
        let lease = try acquireLease(environment)
        defer { releaseLease(lease) }
        guard var intent = try PendingUploadQueue.listCreations(includingCompleted: true, environment: environment.queue).first(where: { $0.operationID == operationID }) else {
            throw CloudProviderError.fileNotFound
        }
        try environment.queue.removeItem(PendingUploadQueue.creationPauseURL(intent, environment: environment.queue))
        intent.isPaused = false
        try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
        return try await deliver(intent, environment: environment)
    }

    static func cancel(operationID: UUID, environment: Environment = .live) throws {
        guard let intent = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: { $0.operationID == operationID }) else { return }
        try PendingUploadQueue.requestCreationPause(intent, environment: environment.queue)
        let lease: Int32
        do { lease = try acquireLease(environment) } catch CloudProviderError.conflict { return }
        defer { releaseLease(lease) }
        guard let current = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: { $0.operationID == operationID }) else { return }
        try PendingUploadQueue.cancelCreation(current, environment: environment.queue)
    }

    private static func deliver(_ original: Intent, environment: Environment) async throws -> DatabaseReference {
        var intent = original
        if intent.phase == .completed { return try environment.completedReference(intent) }
        guard !intent.isPaused else { throw CloudProviderError.authenticationCancelled }
        do {
            let bytes = try environment.queue.readData(PendingUploadQueue.resolveAppGroupURL(for: intent.payloadPath, environment: environment.queue))
            guard KDBXCrypto.sha512(bytes) == intent.payloadSHA512 else { throw SaveError.saveContextUnavailable }
            if intent.receipt == nil {
                try Task.checkCancellation()
                guard let provider = environment.provider(intent.provider), provider.id == intent.provider,
                      provider.isAuthenticated(accountId: intent.accountID) else { throw CloudProviderError.notAuthenticated }
                if intent.phase == .prepared {
                    intent.creationID = try await provider.prepareFileCreationID(accountId: intent.accountID)
                    intent.phase = .reserved
                    try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
                }
                // A weak create-only transport cannot fence a previous ambiguous invocation.
                guard intent.phase != .attempting || intent.creationID != nil else { throw CloudProviderError.conflict(remoteRev: nil) }
                try Task.checkCancellation()
                guard !FileManager.default.fileExists(atPath: PendingUploadQueue.creationPauseURL(intent, environment: environment.queue).path) else { throw CloudProviderError.authenticationCancelled }
                guard provider.isAuthenticated(accountId: intent.accountID) else { throw CloudProviderError.notAuthenticated }
                let hadUnresolvedAttempt = intent.phase == .attempting
                intent.phase = .attempting
                try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
                let created: CloudCreatedFile
                do {
                    created = try await provider.createFile(accountId: intent.accountID, target: intent.target,
                        data: bytes, creationID: intent.creationID, progress: { _ in })
                } catch let failure as CloudUploadFailure {
                    if !hadUnresolvedAttempt && failure.provesNoCommit { intent.phase = .reserved }
                    throw failure
                } catch let error as CloudProviderError {
                    if !hadUnresolvedAttempt, intent.creationID == nil, case .conflict = error {
                        // A definite create-only collision permits a later explicitly numbered destination.
                        intent.phase = .reserved
                    }
                    throw error
                }
                if let id = intent.creationID, created.file.id != id { throw CloudProviderError.conflict(remoteRev: created.metadata.rev) }
                var reference = intent.referenceTemplate
                var metadata = CloudSyncMetadata(provider: intent.provider, accountId: intent.accountID,
                    fileId: created.file.id, displayPath: created.file.path, remoteContentHash: created.metadata.contentHash,
                    remoteModifiedAt: created.metadata.modifiedDate, remoteRev: created.metadata.rev,
                    lastSyncedAt: .now, lastSyncIssue: nil)
                metadata.localHeadOperationID = intent.operationID
                reference.source = .cloud(metadata)
                intent.receipt = reference
                intent.phase = .confirmed
                try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
                guard provider.isAuthenticated(accountId: intent.accountID) else { throw CloudProviderError.notAuthenticated }
            }
            try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: PendingUploadQueue.creationPauseURL(intent, environment: environment.queue).path) else { throw CloudProviderError.authenticationCancelled }
            guard let receipt = intent.receipt else { throw SaveError.saveContextUnavailable }
            let registered = try environment.publish(receipt, bytes)
            guard registered.id == receipt.id, registered.cloudSyncMetadata?.provider == intent.provider,
                  registered.cloudSyncMetadata?.accountId == intent.accountID,
                  registered.cloudSyncMetadata?.fileId == receipt.cloudSyncMetadata?.fileId else { throw SaveError.saveContextUnavailable }
            intent.phase = .completed
            intent.lastIssue = nil
            try PendingUploadQueue.storeCreation(intent, environment: environment.queue)
            // The durable list and cache now own these bytes; retain the small receipt for caller replay.
            try? environment.queue.removeItem(PendingUploadQueue.resolveAppGroupURL(for: intent.payloadPath, environment: environment.queue))
            return registered
        } catch {
            intent.lastIssue = CloudProviderError.issue(for: error)
            let issue = CloudProviderError.issue(for: error)
            if error is CancellationError || issue == .notAuthenticated || issue == .authenticationCancelled {
                intent.isPaused = true
            }
            try? PendingUploadQueue.storeCreation(intent, environment: environment.queue)
            throw error
        }
    }

    private static func acquireLease(_ environment: Environment) throws -> Int32 {
        let root = environment.queue.appGroupContainerURL().appendingPathComponent("pending-uploads", isDirectory: true)
        try environment.queue.createDirectory(root)
        let descriptor = Darwin.open(root.appendingPathComponent(".creations.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw CloudProviderError.conflict(remoteRev: nil)
        }
        return descriptor
    }

    private static func releaseLease(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
