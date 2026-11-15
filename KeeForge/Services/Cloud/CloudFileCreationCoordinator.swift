import Foundation

final class CloudCreationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func cancel() { lock.lock(); defer { lock.unlock() }; active = false }
    // A claimed synchronous effect remains authorized if cancellation arrives afterward.
    func claim() throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
    }
}

// Only a response to this invocation can confirm its fenced attempt.
enum CloudFileCreationCoordinator {
    enum RecoveryError: Error { case unavailable, uncertain, registrationRejected, registrationUnconfirmed }

    struct Environment: Sendable {
        var queue: PendingUploadQueue.Environment = .live
        var createFile: @Sendable (String, String, String, Data) async throws -> CloudCreatedFile = { providerID, accountID, path, bytes in
            guard let provider = CloudProviderRegistry.provider(for: providerID), provider.isAuthenticated(accountId: accountID) else {
                throw CloudProviderError.notAuthenticated
            }
            return try await provider.createFile(accountId: accountID, path: path, data: bytes, progress: { _ in })
        }
        var register: @Sendable (PendingUploadQueue.StoredCreation, Data, PendingUploadQueue.Environment) -> DatabaseListStore.CloudCreationRegistrationOutcome = {
            DatabaseListStore.registerCloudCreation($0, bytes: $1, queue: $2)
        }
        static let live = Environment()
    }

    static func create(operationID: UUID, provider: String, accountID: String, target: String, bytes: Data,
                       referenceTemplate: DatabaseReference, isConflictCopy: Bool = false,
                       lifetime: CloudCreationLifetime = CloudCreationLifetime(), environment: Environment = .live) async throws -> DatabaseReference {
        let existing = try PendingUploadQueue.listCreations(environment: environment.queue).first { $0.intent.operationID == operationID }
        let stored: PendingUploadQueue.StoredCreation
        if let existing {
            guard existing.intent.provider == provider, existing.intent.accountID == accountID, existing.intent.target == target,
                  existing.intent.referenceTemplate == referenceTemplate, existing.intent.isConflictCopy == isConflictCopy,
                  existing.intent.payloadSHA512 == FileDigest.sha512(bytes) else { throw RecoveryError.unavailable }
            stored = existing
        } else {
            stored = try PendingUploadQueue.prepareCreation(operationID: operationID, provider: provider, accountID: accountID,
                target: target, payload: bytes, referenceTemplate: referenceTemplate, isConflictCopy: isConflictCopy, environment: environment.queue)
        }
        guard stored.intent.phase == .prepared else { throw RecoveryError.uncertain }
        try Task.checkCancellation()
        try lifetime.claim()
        let attempting = try PendingUploadQueue.transitionCreation(stored, to: .attempting, environment: environment.queue)
        try lifetime.claim()
        let response = try await environment.createFile(provider, accountID, target, bytes)
        guard !response.file.id.isEmpty else { throw RecoveryError.uncertain }
        var receipt = referenceTemplate
        var metadata = CloudSyncMetadata(provider: provider, accountId: accountID, fileId: response.file.id,
            displayPath: response.file.path, remoteContentHash: response.metadata.contentHash,
            remoteModifiedAt: response.metadata.modifiedDate, remoteRev: response.metadata.rev,
            lastSyncedAt: response.metadata.modifiedDate, lastSyncIssue: nil)
        metadata.localHeadOperationID = operationID
        receipt.source = .cloud(metadata)
        let confirmed = try PendingUploadQueue.transitionCreation(attempting, to: .confirmed, receipt: receipt, environment: environment.queue)
        try Task.checkCancellation()
        try lifetime.claim()
        return try complete(confirmed, environment: environment)
    }

    static func resumeKnownRegistration(operationID: UUID, environment: Environment = .live) throws -> DatabaseReference {
        guard let stored = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: { $0.intent.operationID == operationID }),
              stored.intent.phase == .confirmed else { throw RecoveryError.unavailable }
        return try complete(stored, environment: environment)
    }

    static func export(operationID: UUID, environment: Environment = .live) throws -> Data {
        guard let stored = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: { $0.intent.operationID == operationID }) else { throw RecoveryError.unavailable }
        return try PendingUploadQueue.readCreationPayload(stored, environment: environment.queue)
    }

    private static func complete(_ stored: PendingUploadQueue.StoredCreation, environment: Environment) throws -> DatabaseReference {
        guard let receipt = stored.intent.receipt else { throw RecoveryError.unavailable }
        if stored.intent.isConflictCopy {
            _ = try PendingUploadQueue.readCreationPayload(stored, environment: environment.queue)
            _ = try PendingUploadQueue.transitionCreation(stored, to: .completed, environment: environment.queue)
            return receipt
        }
        let bytes = try PendingUploadQueue.readCreationPayload(stored, environment: environment.queue)
        switch environment.register(stored, bytes, environment.queue) {
        case .durable: break
        case .rejected: throw RecoveryError.registrationRejected
        case .notPublished(let error): throw error
        case .visibleUnconfirmed: throw RecoveryError.registrationUnconfirmed
        }
        _ = try PendingUploadQueue.transitionCreation(stored, to: .completed, environment: environment.queue)
        return receipt
    }
}
