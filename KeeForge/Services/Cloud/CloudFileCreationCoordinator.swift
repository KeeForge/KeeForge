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
    enum RecoveryError: LocalizedError {
        case unavailable, uncertain, registrationRejected, registrationUnconfirmed

        var errorDescription: String? {
            switch self {
            case .uncertain:
                String(localized: "Cloud creation may have succeeded. Open Cloud Recovery to keep or recover the encrypted copy.")
            case .unavailable, .registrationRejected, .registrationUnconfirmed:
                String(localized: "Cloud recovery could not finish. Keep the encrypted copy and reopen Cloud Recovery.")
            }
        }
    }
    struct NotDispatched: Error {
        let underlying: CloudProviderError
    }
    struct UncertainCreation: LocalizedError {
        let underlying: any Error
        var errorDescription: String? { String(localized: "Cloud creation may have succeeded. Open Cloud Recovery to keep or recover the encrypted copy.") }
    }

    struct RecoveryActions: Equatable {
        let export: Bool
        let retry: Bool
        let complete: Bool
        let discard: Bool
        static func forPhase(_ phase: PendingUploadQueue.CreationIntent.Phase) -> RecoveryActions {
            switch phase {
            case .prepared: .init(export: true, retry: true, complete: false, discard: true)
            case .attempting: .init(export: true, retry: false, complete: false, discard: false)
            case .confirmed: .init(export: true, retry: false, complete: true, discard: false)
            case .completed: .init(export: false, retry: false, complete: false, discard: false)
            }
        }
    }

    struct Environment: Sendable {
        var queue: PendingUploadQueue.Environment = .live
        var createFile: @Sendable (String, String, String, Data) async throws -> CloudCreatedFile = { providerID, accountID, path, bytes in
            guard let provider = CloudProviderRegistry.provider(for: providerID), provider.isAuthenticated(accountId: accountID) else {
                throw NotDispatched(underlying: .notAuthenticated)
            }
            return try await provider.createFile(accountId: accountID, path: path, data: bytes, progress: { _ in })
        }
        var afterAttemptPersisted: @Sendable () -> Void = {}
        var register: @Sendable (PendingUploadQueue.StoredCreation, Data, PendingUploadQueue.Environment) -> DatabaseListStore.CloudCreationRegistrationOutcome = {
            DatabaseListStore.registerCloudCreation($0, bytes: $1, queue: $2)
        }
        static let live = Environment()
    }

    static func create(operationID: UUID, provider: String, accountID: String, target: String, bytes: Data,
                       referenceTemplate: DatabaseReference, isConflictCopy: Bool = false, conflictBatchID: UUID? = nil,
                       lifetime: CloudCreationLifetime = CloudCreationLifetime(), environment: Environment = .live) async throws -> DatabaseReference {
        let existing = try PendingUploadQueue.listCreations(environment: environment.queue).first { $0.intent.operationID == operationID }
        let stored: PendingUploadQueue.StoredCreation
        if let existing {
            guard existing.intent.provider == provider, existing.intent.accountID == accountID, existing.intent.target == target,
                  existing.intent.referenceTemplate == referenceTemplate, existing.intent.isConflictCopy == isConflictCopy,
                  existing.intent.conflictBatchID == conflictBatchID, existing.intent.payloadSHA512 == FileDigest.sha512(bytes) else { throw RecoveryError.unavailable }
            stored = existing
        } else {
            stored = try PendingUploadQueue.prepareCreation(operationID: operationID, provider: provider, accountID: accountID,
                target: target, payload: bytes, referenceTemplate: referenceTemplate, isConflictCopy: isConflictCopy,
                conflictBatchID: conflictBatchID, environment: environment.queue)
        }
        guard stored.intent.phase == .prepared else { throw RecoveryError.uncertain }
        try Task.checkCancellation()
        try lifetime.claim()
        let attempting = try PendingUploadQueue.transitionCreation(stored, to: .attempting, environment: environment.queue)
        environment.afterAttemptPersisted()
        do {
            try Task.checkCancellation()
            try lifetime.claim()
        } catch {
            do { _ = try PendingUploadQueue.restoreCreationAfterNoCommit(attempting, environment: environment.queue) }
            catch { throw UncertainCreation(underlying: error) }
            throw error
        }
        let response: CloudCreatedFile
        do { response = try await environment.createFile(provider, accountID, target, bytes) }
        catch let proof as NotDispatched {
            do { _ = try PendingUploadQueue.restoreCreationAfterNoCommit(attempting, environment: environment.queue) }
            catch { throw UncertainCreation(underlying: error) }
            throw proof.underlying
        }
        catch let proof as CloudCreationNotDispatched {
            do { _ = try PendingUploadQueue.restoreCreationAfterNoCommit(attempting, environment: environment.queue) }
            catch { throw UncertainCreation(underlying: error) }
            throw proof.underlying
        }
        catch let proof as CloudUploadFailure where proof.provesNoCommit {
            do { _ = try PendingUploadQueue.restoreCreationAfterNoCommit(attempting, environment: environment.queue) }
            catch { throw UncertainCreation(underlying: error) }
            throw proof.underlying
        }
        catch { throw UncertainCreation(underlying: error) }
        guard !response.file.id.isEmpty else { throw UncertainCreation(underlying: RecoveryError.uncertain) }
        var receipt = referenceTemplate
        var metadata = CloudSyncMetadata(provider: provider, accountId: accountID, fileId: response.file.id,
            displayPath: response.file.path, remoteContentHash: response.metadata.contentHash,
            remoteModifiedAt: response.metadata.modifiedDate, remoteRev: response.metadata.rev,
            lastSyncedAt: response.metadata.modifiedDate, lastSyncIssue: nil)
        metadata.localHeadOperationID = operationID
        receipt.source = .cloud(metadata)
        let confirmed: PendingUploadQueue.StoredCreation
        do { confirmed = try PendingUploadQueue.transitionCreation(attempting, to: .confirmed, receipt: receipt, environment: environment.queue) }
        catch { throw UncertainCreation(underlying: error) }
        try Task.checkCancellation()
        try lifetime.claim()
        return try complete(confirmed, environment: environment)
    }

    static func retryPrepared(operationID: UUID, lifetime: CloudCreationLifetime = CloudCreationLifetime(),
                              environment: Environment = .live) async throws -> DatabaseReference {
        guard let stored = try PendingUploadQueue.listCreations(environment: environment.queue).first(where: { $0.intent.operationID == operationID }),
              stored.intent.phase == .prepared else { throw RecoveryError.unavailable }
        let bytes = try PendingUploadQueue.readCreationPayload(stored, environment: environment.queue)
        return try await create(operationID: operationID, provider: stored.intent.provider, accountID: stored.intent.accountID,
            target: stored.intent.target, bytes: bytes, referenceTemplate: stored.intent.referenceTemplate,
            isConflictCopy: stored.intent.isConflictCopy, conflictBatchID: stored.intent.conflictBatchID, lifetime: lifetime, environment: environment)
    }

    static func resumeKnownRegistration(operationID: UUID, environment: Environment = .live) throws -> DatabaseReference {
        let stored = try PendingUploadQueue.readCreation(operationID, environment: environment.queue)
        guard stored.intent.phase == .confirmed else { throw RecoveryError.unavailable }
        return try complete(stored, environment: environment)
    }

    static func export(operationID: UUID, environment: Environment = .live) throws -> Data {
        let stored = try PendingUploadQueue.readCreation(operationID, environment: environment.queue)
        return try PendingUploadQueue.readCreationPayload(stored, environment: environment.queue)
    }

    private static func complete(_ stored: PendingUploadQueue.StoredCreation, environment: Environment) throws -> DatabaseReference {
        guard let receipt = stored.intent.receipt else { throw RecoveryError.unavailable }
        if stored.intent.isConflictCopy {
            _ = try PendingUploadQueue.readCreationPayload(stored, environment: environment.queue)
            _ = try PendingUploadQueue.transitionCreation(stored, to: .completed, environment: environment.queue)
            try? PendingUploadQueue.cleanCompletedConflictCopyAttempts(environment: environment.queue)
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
