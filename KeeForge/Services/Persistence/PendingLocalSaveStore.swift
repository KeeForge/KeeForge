import Darwin
import Foundation

/// Immutable encrypted AutoFill snapshots, exact receipts and permanent removal fencing.
enum PendingLocalSaveStore {
    struct PendingSave: Sendable, Equatable {
        let databaseID: UUID
        let fileURL: URL
    }

    struct NodeIdentity: Codable, Sendable, Equatable {
        let device: Int64
        let inode: UInt64
    }

    struct FileIdentity: Codable, Sendable, Equatable {
        let node: NodeIdentity
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64
        let birthSeconds: Int64
        let birthNanos: Int64
    }

    enum FileObservation: Codable, Sendable, Equatable {
        case present(FileIdentity, parent: NodeIdentity)
        case missing(ancestor: [String], identity: NodeIdentity)
        case unavailable
    }

    struct Receipt: Codable, Sendable, Equatable, Identifiable {
        let relativePath: String
        let identity: FileIdentity
        let parentIdentity: NodeIdentity
        let digest: Data
        var id: String {
            relativePath + "-" + String(identity.node.inode) + "-" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    struct SourceSnapshot: Codable, Sendable, Equatable, Identifiable {
        let relativePath: String
        let observation: FileObservation
        let receipt: Receipt?
        var id: String { relativePath }
    }

    struct KeyFileAssociation: Codable, Sendable, Equatable {
        let bookmarkData: Data?
        let filename: String?
        let changedAt: Date
    }

    struct TargetIdentity: Codable, Sendable, Equatable {
        let canonicalPath: String
        let file: NodeIdentity
        let parent: NodeIdentity
    }

    enum Purpose: Codable, Sendable, Equatable {
        case merge
        case masterKeyChange(KeyFileAssociation?)
        var isMasterKeyChange: Bool {
            if case .masterKeyChange = self { return true }
            return false
        }
    }

    struct Admission: Codable, Sendable, Equatable {
        let operationID: UUID
        let purpose: Purpose
        let sources: [Receipt]
        let target: TargetIdentity
        let baseline: Data
        let observedMasterKeyChangeAt: Date?
        var intendedSHA512: Data?
    }

    struct Token: Sendable, Equatable {
        let databaseID: UUID
        let admission: Admission
        let ownerVersion = 1
    }

    struct CommitReceipt: Sendable, Equatable {
        let databaseID: UUID
        let admission: Admission
        let sha512: Data
        var targetDurabilityConfirmed = false
        var installedTarget: TargetIdentity?
        let ownerVersion = 1
        var operationID: UUID { admission.operationID }
        var purpose: Purpose { admission.purpose }
    }

    private enum Operation: Codable, Equatable {
        case idle
        case admitted(Admission)
        case recoveryRequired(Admission)
        var admission: Admission? {
            switch self {
            case .idle: nil
            case .admitted(let value), .recoveryRequired(let value): value
            }
        }
    }

    private enum Epoch: Codable, Equatable {
        case unobserved, known(Date?, UUID)
        var id: UUID? { if case .known(_, let id) = self { return id }; return nil }
    }

    struct PlannedTarget: Codable, Sendable, Equatable {
        let operationID: UUID
        let sha512: Data
    }
    struct KeyEpochEvidence: Codable, Sendable, Equatable {
        let epochID: UUID
        let association: KeyFileAssociation
        let associationRegistrySHA512: Data
        var target: TargetIdentity
        var sha512: Data
        var targetDurabilityUnconfirmed: Bool
        var pending: PlannedTarget?
    }
    struct TargetWriteObservation: Sendable {
        let target: TargetIdentity
        let sha512: Data
        let durabilityConfirmed: Bool
    }
    struct AuthorizedWrite<Value> {
        let value: Value
        let bookkeeping: ResolutionOutcome
    }
    private enum SourcePhase: Codable, Equatable { case provisional, eligible(Receipt) }
    private struct SourceRecord: Codable {
        let id: UUID
        let relativePath: String
        let intendedSHA512: Data
        let epochID: UUID?
        var phase: SourcePhase = .provisional
    }

    private struct OwnerState: Codable {
        let version: Int
        var removed: Bool
        var epoch: Epoch = .unobserved
        var sources: [SourceRecord] = []
        var operation: Operation = .idle
        var keyEvidence: KeyEpochEvidence?
        var retirementID: UUID?
        var retiringEntries: [SourceSnapshot]?
    }

    struct PreparedSource: Sendable {
        let sourceID: UUID
        let save: PendingSave
        let receipt: Receipt
    }

    enum AcceptanceOutcome: Sendable, Equatable { case accepted, acceptedWithoutConfirmedDurability, notAccepted }
    enum ResolutionOutcome: Sendable, Equatable { case resolved, resolvedVisibleWithoutConfirmedDurability, retainedForRecovery }

    struct StorageIO: Sendable {
        var fileIO: @Sendable (URL) -> DurableFileWriteIO = { _ in .init() }
        var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
        var synchronize: @Sendable (URL) throws -> Void = synchronizeDirectory
    }

    struct AdmissionPublicationFailure: Error {
        let token: Token
        let underlying: any Error
    }

    struct SourcePreparationFailure: Error, LocalizedError {
        var errorDescription: String? {
            String(localized: "KeeForge could not confirm the encrypted AutoFill snapshot. This save did not change the shared copy or original database. Open Database Details in KeeForge to recover or discard the pending snapshot.")
        }
    }

    struct RecoverySnapshot: Sendable, Equatable {
        let databaseID: UUID
        let receipts: [Receipt]
        let isRevoked: Bool
        let retirementID: UUID?
        let admission: Admission?
        let sourcePublicationPending: Bool
        let keyEvidence: KeyEpochEvidence?
        let ownerObservation: FileObservation
        let entries: [SourceSnapshot]
        let ownerUnavailable: Bool
        var keyAssociationForRecovery: KeyFileAssociation? {
            if let evidence = keyEvidence { return evidence.association }
            if let admission, case .masterKeyChange(let association) = admission.purpose { return association }
            return nil
        }
        func requiresAssociationRecovery(for reference: DatabaseReference) -> Bool {
            guard let association = keyEvidence?.association else { return false }
            return reference.lastMasterKeyChangeAt != association.changedAt
                || reference.keyFileBookmarkData != association.bookmarkData || reference.keyFileFilename != association.filename
        }
        var needsRecovery: Bool { isRevoked || retirementID != nil || admission != nil || sourcePublicationPending || keyEvidence?.pending != nil || ownerUnavailable || entries.contains { $0.receipt == nil } }
    }

    enum OwnershipError: Error, LocalizedError, Equatable {
        case recoveryRequired, sourceChanged, removed, targetChanged
        var errorDescription: String? {
            if case .targetChanged = self {
                return String(localized: "The database file changed since it was opened. Reload the database and try again.")
            }
            return String(localized: "AutoFill changes need recovery. Open Database Details to export their original encrypted snapshots or deliberately discard them before trying again.")
        }
    }

    @TaskLocal private static var ownerContainer: URL?
    @TaskLocal static var saveToken: Token?
    @TaskLocal static var keyFileAssociation: KeyFileAssociation?
    static let didChange = Notification.Name("KeeForge.pendingLocalSavesChanged")

    static func prepareSource(
        _ encryptedBytes: Data, for databaseID: UUID, masterKeyChangedAt: Date? = nil,
        baseCacheSHA512: Data, now: Date = .now, sourceID: UUID = UUID(), io: StorageIO = .init()
    ) throws -> PreparedSource {
        do {
            return try withLock(for: databaseID) {
                try requireNotRemoved(databaseID)
                var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
                var compatible = true
                do { try checkEpoch(&state, expected: masterKeyChangedAt) } catch { compatible = false }
                let canAccept = compatible && state.retirementID == nil
                    && state.operation.admission?.purpose.isMasterKeyChange != true
                    && state.keyEvidence?.pending == nil
                    && !state.sources.contains(where: { $0.phase == .provisional })
                    && cacheBelongsToEpoch(baseCacheSHA512, state: state)
                let payloadRoot = directoryURL(for: databaseID)
                try createDurableDirectory(at: payloadRoot, anchor: ownerContainer ?? payloadRoot)
                let directory = payloadRoot.appendingPathComponent(sourceID.uuidString, isDirectory: true)
                guard Darwin.mkdir(directory.path, S_IRWXU) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try io.synchronize(directory)
                try io.synchronize(payloadRoot)
                let names = Set(try sourceURLs(databaseID).map(\.lastPathComponent) + state.sources.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent })
                var date = now
                var name = LocalDatabaseSaver.backupFilename(for: date)
                while names.contains(name) {
                    date.addTimeInterval(0.000_001)
                    name = LocalDatabaseSaver.backupFilename(for: date)
                }
                let path = sourceID.uuidString + "/" + name
                let intended = FileDigest.sha512(encryptedBytes)
                state.sources.append(SourceRecord(id: sourceID, relativePath: path, intendedSHA512: intended,
                    epochID: canAccept ? state.epoch.id : nil))
                // Provisional ownership is durable before the payload can become observable.
                try persist(state, databaseID: databaseID, io: io)
                let url = directory.appendingPathComponent(name)
                switch writeWithDurabilityOutcome(encryptedBytes, to: url, publication: .exclusive, io: io.fileIO(url)) {
                case .durable: break
                case .notPublished, .publishedWithoutConfirmedDurability: throw SourcePreparationFailure()
                }
                let receipt = try receipt(at: url, databaseID: databaseID)
                guard canAccept, receipt.digest == intended else { throw OwnershipError.sourceChanged }
                changed()
                return PreparedSource(sourceID: sourceID, save: PendingSave(databaseID: databaseID, fileURL: url), receipt: receipt)
            }
        } catch { throw SourcePreparationFailure() }
    }

    static func activateSource(_ prepared: PreparedSource, io: StorageIO = .init()) -> AcceptanceOutcome {
        do {
            return try withLock(for: prepared.save.databaseID) {
                let id = prepared.save.databaseID
                try requireNotRemoved(id)
                var state = try loadState(id) ?? OwnerState(version: 1, removed: false)
                guard let index = state.sources.firstIndex(where: { $0.id == prepared.sourceID }),
                      state.sources[index].relativePath == prepared.receipt.relativePath,
                      state.sources[index].intendedSHA512 == prepared.receipt.digest,
                      state.sources[index].epochID == state.epoch.id, state.sources[index].epochID != nil,
                      state.operation.admission?.purpose.isMasterKeyChange != true else { return .notAccepted }
                try validate(prepared.receipt, databaseID: id)
                if case .eligible(let receipt) = state.sources[index].phase {
                    return receipt == prepared.receipt ? .acceptedWithoutConfirmedDurability : .notAccepted
                }
                let cache = sharedCopyURL(for: id)
                guard FileDigest.sha512(try Data(contentsOf: cache)) == prepared.receipt.digest else { return .notAccepted }
                state.sources[index].phase = .eligible(prepared.receipt)
                switch try publish(state, databaseID: id, io: io) {
                case .durable: return .accepted
                case .publishedWithoutConfirmedDurability: return .acceptedWithoutConfirmedDurability
                case .notPublished: return .notAccepted
                }
            }
        } catch { return .notAccepted }
    }

    /// Legacy timestamp.kdbx files remain readable; new snapshots have a unique parent.
    static func saves(for databaseID: UUID) -> [PendingSave] {
        (try? withLock(for: databaseID) {
            let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            return try sourceURLs(databaseID).filter { url in
                let path = relativePath(url, databaseID: databaseID)
                if !path.contains("/") { return true }
                guard let source = state.sources.first(where: { $0.relativePath == path }),
                      source.epochID == state.epoch.id, source.epochID != nil, case .eligible(let expected) = source.phase else { return false }
                return (try? receipt(at: url, databaseID: databaseID)) == expected
            }.map { PendingSave(databaseID: databaseID, fileURL: $0) }
        }) ?? []
    }

    static func hasSaves(for databaseID: UUID) -> Bool {
        do {
            return try withLock(for: databaseID) {
                let state = try loadState(databaseID)
                return try state?.retirementID != nil || state?.operation.admission != nil || state?.keyEvidence?.pending != nil || state?.sources.isEmpty == false || !sourceURLs(databaseID).isEmpty
            }
        } catch { return true }
    }

    static func hasSourcePayloads(for databaseID: UUID) -> Bool {
        do {
            return try withLock(for: databaseID) {
                let state = try loadState(databaseID)
                return try (state?.sources.contains { if case .eligible = $0.phase { return true }; return false } ?? false)
                    || sourceURLs(databaseID).contains { !relativePath($0, databaseID: databaseID).contains("/") }
            }
        } catch { return true }
    }

    /// Read bytes and identity together; the merge later admits exactly this receipt.
    static func read(_ source: PendingSave) throws -> (data: Data, receipt: Receipt) {
        try withLock(for: source.databaseID) {
            let state = try loadState(source.databaseID) ?? OwnerState(version: 1, removed: false)
            guard try !tombstoned(source.databaseID), !state.removed, state.operation == .idle,
                  state.retirementID == nil, state.keyEvidence?.pending == nil else { throw OwnershipError.recoveryRequired }
            let receipt = try receipt(at: source.fileURL, databaseID: source.databaseID)
            if receipt.relativePath.contains("/") {
                guard state.sources.contains(where: { $0.relativePath == receipt.relativePath && $0.phase == .eligible(receipt)
                    && $0.epochID == state.epoch.id && $0.epochID != nil }) else { throw OwnershipError.recoveryRequired }
            }
            let data = try Data(contentsOf: sourceURL(receipt.relativePath, databaseID: source.databaseID))
            guard FileDigest.sha512(data) == receipt.digest else { throw OwnershipError.sourceChanged }
            return (data, receipt)
        }
    }

    static func validateWriteContext(
        for databaseID: UUID, token: Token?, expectedMasterKeyChangeAt: Date?, enforcesEpoch: Bool,
        isMasterKeyChange: Bool, preparesSource: Bool
    ) throws {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            if enforcesEpoch && !preparesSource { try checkEpoch(&state, expected: expectedMasterKeyChangeAt) }
            guard state.retirementID == nil else { throw OwnershipError.recoveryRequired }
            if let token {
                guard case .admitted(let admission) = state.operation, admission == token.admission else { throw OwnershipError.recoveryRequired }
            } else {
                guard preparesSource || state.operation == .idle else { throw OwnershipError.recoveryRequired }
            }
            if isMasterKeyChange {
                guard state.operation == .idle, state.sources.isEmpty, try sourceURLs(databaseID).isEmpty else { throw OwnershipError.recoveryRequired }
            }
        }
    }

    static func admit(
        _ receipts: [Receipt], for databaseID: UUID, target: TargetIdentity,
        baseline: Data, masterKeyChangedAt: Date?, io: StorageIO = .init()
    ) throws -> Token {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.operation == .idle, state.retirementID == nil, state.keyEvidence?.pending == nil,
                  !state.sources.contains(where: { $0.phase == .provisional || $0.epochID != state.epoch.id }) else { throw OwnershipError.recoveryRequired }
            try checkEpoch(&state, expected: masterKeyChangedAt)
            for receipt in receipts { try validateEligible(receipt, state: state, databaseID: databaseID) }
            let admission = Admission(operationID: UUID(), purpose: .merge, sources: receipts,
                target: target, baseline: baseline, observedMasterKeyChangeAt: masterKeyChangedAt)
            state.operation = .admitted(admission)
            try persist(state, databaseID: databaseID, io: io)
            return Token(databaseID: databaseID, admission: admission)
        }
    }

    /// Coordination precedes flock; target observation and replacement stay under the same flock.
    static func withWriteAuthorization<T>(
        for databaseID: UUID, token: Token?, expectedMasterKeyChangeAt: Date?, enforcesEpoch: Bool,
        isMasterKeyChange: Bool, association: KeyFileAssociation?, prepared: PreparedSource?,
        intendedSHA512: Data, observeTarget: () throws -> (TargetIdentity, Data),
        targetIsSharedCopy: Bool, observeEffect: () -> TargetWriteObservation?,
        io: StorageIO = .init(), _ replace: (CommitReceipt?) throws -> T
    ) throws -> AuthorizedWrite<T> {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.retirementID == nil else { throw OwnershipError.recoveryRequired }
            let previousEpoch = state.epoch
            if enforcesEpoch { try checkEpoch(&state, expected: expectedMasterKeyChangeAt) }
            let (target, baseline) = try observeTarget()
            if let evidence = state.keyEvidence {
                try validateKeyTarget(evidence, target: target, sha512: baseline, sharedCopy: targetIsSharedCopy, state: state)
                guard evidence.pending == nil else { throw OwnershipError.recoveryRequired }
            }
            var committed: CommitReceipt?
            if let token {
                guard token.databaseID == databaseID, case .admitted(var admission) = state.operation,
                      admission == token.admission, target == admission.target, baseline == admission.baseline else {
                    throw OwnershipError.targetChanged
                }
                for receipt in admission.sources { try validateEligible(receipt, state: state, databaseID: databaseID) }
                admission.intendedSHA512 = intendedSHA512
                state.operation = .recoveryRequired(admission)
                try persist(state, databaseID: databaseID, io: io)
                committed = CommitReceipt(databaseID: databaseID, admission: admission, sha512: intendedSHA512)
            } else if isMasterKeyChange {
                guard state.operation == .idle, state.sources.isEmpty, try sourceURLs(databaseID).isEmpty else {
                    throw OwnershipError.recoveryRequired
                }
                let admission = Admission(operationID: UUID(), purpose: .masterKeyChange(association), sources: [],
                    target: target, baseline: baseline, observedMasterKeyChangeAt: expectedMasterKeyChangeAt,
                    intendedSHA512: intendedSHA512)
                state.operation = .recoveryRequired(admission)
                switch try publish(state, databaseID: databaseID, io: io) {
                case .durable: break
                case .notPublished(let error): throw error
                case .publishedWithoutConfirmedDurability(let error):
                    throw AdmissionPublicationFailure(token: Token(databaseID: databaseID, admission: admission), underlying: error)
                }
                committed = CommitReceipt(databaseID: databaseID, admission: admission, sha512: intendedSHA512)
            } else {
                guard state.operation == .idle || targetIsSharedCopy else { throw OwnershipError.recoveryRequired }
                if state.epoch != previousEpoch { try persist(state, databaseID: databaseID, io: io) }
            }
            if state.keyEvidence != nil, !isMasterKeyChange, !targetIsSharedCopy {
                state.keyEvidence?.pending = PlannedTarget(operationID: UUID(), sha512: intendedSHA512)
                try persist(state, databaseID: databaseID, io: io)
            }
            if let prepared {
                guard prepared.save.databaseID == databaseID,
                      state.sources.contains(where: { $0.id == prepared.sourceID && $0.phase == .provisional
                        && $0.intendedSHA512 == prepared.receipt.digest && $0.epochID == state.epoch.id && $0.epochID != nil }) else {
                    throw OwnershipError.sourceChanged
                }
                try validate(prepared.receipt, databaseID: databaseID)
            }
            let value = try replace(committed)
            var bookkeeping = ResolutionOutcome.resolved
            if var evidence = state.keyEvidence, !isMasterKeyChange, !targetIsSharedCopy, let observed = observeEffect() {
                evidence.target = observed.target
                evidence.sha512 = observed.sha512
                evidence.targetDurabilityUnconfirmed = !observed.durabilityConfirmed
                evidence.pending = nil
                state.keyEvidence = evidence
                do { bookkeeping = try resolution(publish(state, databaseID: databaseID, io: io)) }
                catch { bookkeeping = .retainedForRecovery }
            }
            return AuthorizedWrite(value: value, bookkeeping: bookkeeping)
        }
    }

    static func releaseAfterProvenNoReplacement(_ token: Token, io: StorageIO = .init()) -> ResolutionOutcome {
        do {
            return try withLock(for: token.databaseID) {
                try requireNotRemoved(token.databaseID)
                var state = try loadState(token.databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.version == token.ownerVersion, let admission = state.operation.admission,
                      admission.operationID == token.admission.operationID, admission.sources == token.admission.sources else { throw OwnershipError.sourceChanged }
                state.operation = .idle
                return try resolution(publish(state, databaseID: token.databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func complete(_ commit: CommitReceipt, observeTarget: () throws -> (TargetIdentity, Data), io: StorageIO = .init()) -> ResolutionOutcome {
        do {
            return try withLock(for: commit.databaseID) {
                try requireNotRemoved(commit.databaseID)
                var state = try loadState(commit.databaseID) ?? OwnerState(version: 1, removed: false)
                guard commit.targetDurabilityConfirmed, state.version == commit.ownerVersion,
                      case .recoveryRequired(let admission) = state.operation, admission == commit.admission,
                      admission.intendedSHA512 == commit.sha512, admission.purpose == .merge,
                      let installed = commit.installedTarget else { throw OwnershipError.sourceChanged }
                let (target, sha) = try observeTarget()
                guard target == installed, sha == commit.sha512, target.canonicalPath == admission.target.canonicalPath,
                      target.parent == admission.target.parent else { throw OwnershipError.targetChanged }
                for receipt in admission.sources { try validate(receipt, databaseID: commit.databaseID) }
                for receipt in admission.sources {
                    try removeDurably(receipt.relativePath, databaseID: commit.databaseID, io: io)
                }
                let consumed = Set(admission.sources.map(\.relativePath))
                state.sources.removeAll { consumed.contains($0.relativePath) }
                // All admitted namespaces are confirmed removed before idle can become visible.
                state.operation = .idle
                return try resolution(publish(state, databaseID: commit.databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func withCachePublicationAuthorization<T>(
        for databaseID: UUID, sha512: Data, _ publish: () throws -> T
    ) throws -> T {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            guard !state.sources.contains(where: { if case .eligible = $0.phase { return true }; return false }),
                  try !sourceURLs(databaseID).contains(where: { !relativePath($0, databaseID: databaseID).contains("/") }) else {
                throw OwnershipError.sourceChanged
            }
            if let admission = state.operation.admission, admission.purpose.isMasterKeyChange {
                guard admission.intendedSHA512 == sha512 else { throw OwnershipError.targetChanged }
            } else if let evidence = state.keyEvidence {
                guard evidence.sha512 == sha512 || evidence.pending?.sha512 == sha512 else { throw OwnershipError.targetChanged }
            }
            return try publish()
        }
    }

    static func permitsPublishingReadCopy(sha512: Data, for databaseID: UUID) -> Bool {
        do {
            return try withLock(for: databaseID) {
                try requireNotRemoved(databaseID)
                let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.operation.admission?.purpose.isMasterKeyChange != true,
                      state.keyEvidence?.pending == nil else { return false }
                return state.keyEvidence == nil || state.keyEvidence?.sha512 == sha512
            }
        } catch { return false }
    }

    static func validateObservedKeyContext(
        for databaseID: UUID, target: TargetIdentity, sha512: Data, sharedCopy: Bool
    ) throws {
        try withLock(for: databaseID) {
            let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            if let evidence = state.keyEvidence {
                guard evidence.pending == nil else { throw OwnershipError.recoveryRequired }
                try validateKeyTarget(evidence, target: target, sha512: sha512, sharedCopy: sharedCopy, state: state)
            }
        }
    }

    static func withAssociationPublicationAuthorization<T>(
        for databaseID: UUID, operationID: UUID, association: KeyFileAssociation, _ publish: () throws -> T
    ) throws -> T {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            let barrierMatches: Bool
            if let admission = state.operation.admission, case .masterKeyChange(let expected) = admission.purpose {
                barrierMatches = admission.operationID == operationID && expected == association
            } else { barrierMatches = false }
            guard barrierMatches || (state.keyEvidence?.epochID == operationID && state.keyEvidence?.association == association) else {
                throw OwnershipError.sourceChanged
            }
            return try publish()
        }
    }

    static func validateReferenceAssociation(_ reference: DatabaseReference) throws {
        try withLock(for: reference.id) {
            if let evidence = try loadState(reference.id)?.keyEvidence {
                guard reference.lastMasterKeyChangeAt == evidence.association.changedAt,
                      reference.keyFileBookmarkData == evidence.association.bookmarkData,
                      reference.keyFileFilename == evidence.association.filename else { throw OwnershipError.recoveryRequired }
            }
        }
    }

    static func settleKeyPublication(
        _ commit: CommitReceipt, associationProof: DatabaseListStore.DurableKeyFileAssociationReceipt,
        observeTarget: () throws -> (TargetIdentity, Data), io: StorageIO = .init()
    ) -> ResolutionOutcome {
        do {
            return try withLock(for: commit.databaseID) {
                try requireNotRemoved(commit.databaseID)
                var state = try loadState(commit.databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.version == commit.ownerVersion, case .recoveryRequired(let admission) = state.operation,
                      admission == commit.admission, admission.sources.isEmpty,
                      case .masterKeyChange(let association) = admission.purpose, let association,
                      associationProof.databaseID == commit.databaseID, associationProof.operationID == commit.operationID,
                      associationProof.association == association, let installed = commit.installedTarget else { throw OwnershipError.recoveryRequired }
                let (target, sha) = try observeTarget()
                guard target == installed, sha == commit.sha512, target.canonicalPath == admission.target.canonicalPath,
                      target.parent == admission.target.parent else { throw OwnershipError.targetChanged }
                state.epoch = .known(association.changedAt, commit.operationID)
                state.keyEvidence = KeyEpochEvidence(epochID: commit.operationID, association: association,
                    associationRegistrySHA512: associationProof.registrySHA512, target: target, sha512: sha,
                    targetDurabilityUnconfirmed: !commit.targetDurabilityConfirmed)
                // Arrivals rejected by the key barrier remain recoverable under their original epoch.
                for index in state.sources.indices where state.sources[index].epochID != commit.operationID {
                    state.sources[index].phase = .provisional
                }
                state.operation = .idle
                return try resolution(publish(state, databaseID: commit.databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func confirmKeyEvidence(
        _ expected: KeyEpochEvidence, for databaseID: UUID,
        associationProof: DatabaseListStore.DurableKeyFileAssociationReceipt,
        observeTarget: () throws -> (TargetIdentity, Data), io: StorageIO = .init()
    ) -> ResolutionOutcome {
        do {
            return try withLock(for: databaseID) {
                try requireNotRemoved(databaseID)
                var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.keyEvidence == expected, state.epoch.id == expected.epochID,
                      associationProof.databaseID == databaseID, associationProof.operationID == expected.epochID,
                      associationProof.association == expected.association else {
                    throw OwnershipError.sourceChanged
                }
                let (target, sha) = try observeTarget()
                guard (target == expected.target && sha == expected.sha512)
                    || (target.canonicalPath == expected.target.canonicalPath && target.parent == expected.target.parent
                        && sha == expected.pending?.sha512) else { throw OwnershipError.targetChanged }
                var confirmed = expected
                confirmed.target = target
                confirmed.sha512 = sha
                confirmed.pending = nil
                state.keyEvidence = confirmed
                return try resolution(publish(state, databaseID: databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    private static func cacheBelongsToEpoch(_ sha512: Data, state: OwnerState) -> Bool {
        guard let evidence = state.keyEvidence else { return true }
        return sha512 == evidence.sha512 || state.sources.contains {
            $0.epochID == state.epoch.id && $0.intendedSHA512 == sha512
        }
    }
    private static func validateKeyTarget(
        _ evidence: KeyEpochEvidence, target: TargetIdentity, sha512: Data, sharedCopy: Bool, state: OwnerState
    ) throws {
        guard state.epoch.id == evidence.epochID else { throw OwnershipError.recoveryRequired }
        if sharedCopy {
            guard cacheBelongsToEpoch(sha512, state: state) else { throw OwnershipError.targetChanged }
        } else {
            guard target == evidence.target, sha512 == evidence.sha512 else { throw OwnershipError.targetChanged }
        }
    }

    static func validateRecoveryAdmission(_ admission: Admission, for databaseID: UUID) throws {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            guard try loadState(databaseID)?.operation.admission == admission else { throw OwnershipError.sourceChanged }
        }
    }

    static func targetIdentity(at url: URL) throws -> TargetIdentity {
        TargetIdentity(canonicalPath: url.standardizedFileURL.resolvingSymlinksInPath().path,
            file: try identity(at: url).node, parent: try identity(at: url.deletingLastPathComponent()).node)
    }

    static func recovery(for databaseID: UUID) throws -> RecoverySnapshot {
        try withLock(for: databaseID) {
            let ownerObservation = observe(stateURL(databaseID))
            let state = try? loadState(databaseID)
            let unavailable: Bool
            switch ownerObservation {
            case .missing: unavailable = false
            case .present: unavailable = state == nil
            case .unavailable: unavailable = true
            }
            var paths = Set((state?.retiringEntries?.map(\.relativePath) ?? [])
                + (state?.sources.map(\.relativePath) ?? []) + (state?.operation.admission?.sources.map(\.relativePath) ?? []))
            let root = directoryURL(for: databaseID)
            do {
                if try exists(root) {
                    guard case .present(let rootIdentity, _) = observe(root), rootIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { throw OwnershipError.sourceChanged }
                    for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        if url.pathExtension.lowercased() == "kdbx" { paths.insert(url.lastPathComponent) }
                        else if UUID(uuidString: url.lastPathComponent) != nil {
                            guard case .present(let parentIdentity, _) = observe(url), parentIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else {
                                paths.insert(url.lastPathComponent)
                                continue
                            }
                            do {
                                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) where child.pathExtension.lowercased() == "kdbx" {
                                    paths.insert(url.lastPathComponent + "/" + child.lastPathComponent)
                                }
                            } catch { paths.insert(url.lastPathComponent) }
                        }
                    }
                }
            } catch { paths.insert(".") }
            let entries = paths.sorted().map { path in
                let url = recoveryURL(path, databaseID: databaseID)
                return SourceSnapshot(relativePath: path, observation: observe(url),
                    receipt: try? receipt(at: url, databaseID: databaseID))
            }
            let receipts = entries.compactMap(\.receipt)
            let publicationPending = (state?.sources ?? []).contains { source in
                guard case .eligible(let expected) = source.phase else { return true }
                return source.epochID != state?.epoch.id || !receipts.contains(expected)
            } || entries.contains { entry in
                entry.relativePath.contains("/") && !(state?.sources.contains { $0.relativePath == entry.relativePath } ?? false)
            }
            return RecoverySnapshot(databaseID: databaseID, receipts: receipts,
                isRevoked: try tombstoned(databaseID) || state?.removed == true,
                retirementID: state?.retirementID, admission: state?.operation.admission,
                sourcePublicationPending: publicationPending, keyEvidence: state?.keyEvidence, ownerObservation: ownerObservation, entries: entries,
                ownerUnavailable: unavailable)
        }
    }

    static func export(_ receipt: Receipt, for databaseID: UUID) throws -> Data {
        try withLock(for: databaseID) {
            try validate(receipt, databaseID: databaseID)
            let data = try Data(contentsOf: sourceURL(receipt.relativePath, databaseID: databaseID))
            guard FileDigest.sha512(data) == receipt.digest else { throw OwnershipError.sourceChanged }
            return data
        }
    }

    static func exportKeyEpochCopy(_ expected: KeyEpochEvidence, for databaseID: UUID, at url: URL) throws -> Data {
        try withLock(for: databaseID) {
            guard try loadState(databaseID)?.keyEvidence == expected,
                  case .present(let identity, let parent) = observe(url), identity.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
                throw OwnershipError.sourceChanged
            }
            let bytes = try Data(contentsOf: url)
            let sha = FileDigest.sha512(bytes)
            guard observe(url) == .present(identity, parent: parent),
                  sha == expected.sha512 || sha == expected.pending?.sha512 else {
                throw OwnershipError.sourceChanged
            }
            return bytes
        }
    }

    /// Separate destructive consent applies only to this snapshot, never newer sources.
    static func discard(_ snapshot: RecoverySnapshot, io: StorageIO = .init()) throws -> ResolutionOutcome {
        return try withLock(for: snapshot.databaseID) {
            var state: OwnerState
            if snapshot.ownerUnavailable {
                try validateObservation(snapshot.ownerObservation, at: stateURL(snapshot.databaseID))
                try writeAtomicallyAndDurably(Data("removed".utf8), to: controlDirectory(snapshot.databaseID).appendingPathComponent(".tombstone"))
                state = OwnerState(version: 1, removed: true)
            } else {
                state = try loadState(snapshot.databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.retirementID == snapshot.retirementID,
                      state.operation.admission?.operationID == snapshot.admission?.operationID,
                      state.keyEvidence == snapshot.keyEvidence else { throw OwnershipError.sourceChanged }
            }
            guard snapshot.entries.allSatisfy({ validRecoveryPath($0.relativePath) }) else { throw OwnershipError.sourceChanged }
            for entry in snapshot.entries {
                try validateObservation(entry.observation, at: recoveryURL(entry.relativePath, databaseID: snapshot.databaseID))
            }
            if snapshot.keyEvidence?.pending != nil {
                try writeAtomicallyAndDurably(Data("removed".utf8), to: controlDirectory(snapshot.databaseID).appendingPathComponent(".tombstone"))
                state.removed = true
            }
            if let admission = state.operation.admission {
                if admission.purpose.isMasterKeyChange {
                    try writeAtomicallyAndDurably(Data("removed".utf8), to: controlDirectory(snapshot.databaseID).appendingPathComponent(".tombstone"))
                    state.removed = true
                }
                state.operation = .recoveryRequired(admission)
            }
            state.retirementID = UUID()
            state.retiringEntries = snapshot.entries
            try persist(state, databaseID: snapshot.databaseID, io: io)
            let removals = snapshot.entries.contains(where: { $0.relativePath == "." })
                ? snapshot.entries.filter { $0.relativePath == "." } : snapshot.entries
            for entry in removals {
                let url = recoveryURL(entry.relativePath, databaseID: snapshot.databaseID)
                if case .present = entry.observation {
                    try io.remove(url)
                    try io.synchronize(url.deletingLastPathComponent())
                }
            }
            let paths = Set(snapshot.entries.map(\.relativePath))
            state.sources.removeAll { paths.contains($0.relativePath) || paths.contains(".") }
            state.operation = .idle
            state.retirementID = nil
            state.retiringEntries = nil
            if state.removed { state.keyEvidence = nil }
            return try resolution(publish(state, databaseID: snapshot.databaseID, io: io))
        }
    }

    /// List-lock -> flock; revocation never deletes unresolved encrypted sources.
    static func revokeForRemoval(_ databaseID: UUID) throws -> Bool {
        try withLock(for: databaseID) {
            try writeAtomicallyAndDurably(Data("removed".utf8), to: controlDirectory(databaseID).appendingPathComponent(".tombstone"))
            var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            state.removed = true
            try persist(state, databaseID: databaseID)
            return try state.retirementID == nil && state.operation == .idle && state.sources.isEmpty
                && state.keyEvidence?.pending == nil
                && sourceURLs(databaseID).isEmpty
        }
    }

    static func isRevoked(_ databaseID: UUID) -> Bool {
        do { return try withLock(for: databaseID) { try tombstoned(databaseID) || loadState(databaseID)?.removed == true } }
        catch { return true }
    }

    static func moveToBackups(_ save: PendingSave, for reference: DatabaseReference) throws -> URL {
        // Resolve the backup location before acquiring flock (list-lock order).
        let backupDirectory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        return try withLock(for: save.databaseID) {
            try requireNotRemoved(save.databaseID)
            var state = try loadState(save.databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.operation == .idle, state.retirementID == nil else { throw OwnershipError.recoveryRequired }
            let receipt = try receipt(at: save.fileURL, databaseID: save.databaseID)
            let data = try Data(contentsOf: save.fileURL)
            try createDurableDirectory(at: backupDirectory, anchor: ownerContainer ?? backupDirectory)
            var date = Date.now
            var name = save.fileURL.deletingPathExtension().lastPathComponent
            var url = backupDirectory.appendingPathComponent("\(name)\(DatabaseListStore.retainedBackupSuffix).kdbx")
            while FileManager.default.fileExists(atPath: url.path) {
                name = (LocalDatabaseSaver.backupFilename(for: date) as NSString).deletingPathExtension
                date.addTimeInterval(0.000_001)
                url = backupDirectory.appendingPathComponent("\(name)\(DatabaseListStore.retainedBackupSuffix).kdbx")
            }
            let staging = backupDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staging) }
            try writeAtomicallyAndDurably(data, to: staging)
            guard Darwin.link(staging.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try synchronizeDirectory(backupDirectory)
            guard try Data(contentsOf: url) == data else { throw OwnershipError.sourceChanged }
            try validate(receipt, databaseID: save.databaseID)
            try FileManager.default.removeItem(at: save.fileURL)
            try synchronizeDirectory(save.fileURL.deletingLastPathComponent())
            state.sources.removeAll { $0.relativePath == receipt.relativePath }
            try persist(state, databaseID: save.databaseID)
            return url
        }
    }

    static func clearAll() {
        // Only test isolation resets permanent revocations; ordinary removal never unlinks locks.
        if AppGroupContainer.isRedirectedForTesting {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: AppGroupContainer.url.appendingPathComponent("pending-local-save-owners"))
        }
    }

    private static func withLock<T>(for databaseID: UUID, _ body: () throws -> T) throws -> T {
        guard let container = AppGroupContainer.resolvedURL else { throw OwnershipError.recoveryRequired }
        return try $ownerContainer.withValue(container) {
            let directory = controlDirectory(databaseID)
            try createDurableDirectory(at: directory, anchor: container)
            let fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(fd) }
            try protectDurableFile(at: directory.appendingPathComponent(".lock"), descriptor: fd)
            try synchronizeDirectory(directory)
            guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
            defer { flock(fd, LOCK_UN) }
            return try body()
        }
    }

    private static func sourceURLs(_ databaseID: UUID) throws -> [URL] {
        let directory = directoryURL(for: databaseID)
        var urls: [URL] = []
        guard try exists(directory) else { return [] }
        guard case .present(let rootIdentity, _) = observe(directory), rootIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { throw OwnershipError.sourceChanged }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            if url.pathExtension.lowercased() == "kdbx" { urls.append(url) }
            else if UUID(uuidString: url.lastPathComponent) != nil {
                guard case .present(let parentIdentity, _) = observe(url), parentIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { throw OwnershipError.sourceChanged }
                urls += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "kdbx" }
            }
        }
        return urls.sorted {
            ($0.lastPathComponent, $0.path) < ($1.lastPathComponent, $1.path)
        }
    }

    private static func relativePath(_ url: URL, databaseID: UUID) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent == databaseID.uuidString ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
    }

    private static func sourceURL(_ path: String, databaseID: UUID) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (parts.count == 1 || (parts.count == 2 && UUID(uuidString: String(parts[0])) != nil)),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.lowercased().hasSuffix(".kdbx") else { throw OwnershipError.sourceChanged }
        return directoryURL(for: databaseID).appendingPathComponent(path)
    }

    private static func identity(at url: URL) throws -> FileIdentity {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileIdentity(node: NodeIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino)),
            mode: UInt32(info.st_mode), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanos: Int64(info.st_birthtimespec.tv_nsec))
    }

    private static func observe(_ url: URL) -> FileObservation {
        guard let container = ownerContainer else { return .unavailable }
        let anchor = container.standardizedFileURL.resolvingSymlinksInPath()
        let lexicalAnchor = container.standardizedFileURL
        let lexicalTarget = url.standardizedFileURL
        let target = lexicalTarget.resolvingSymlinksInPath()
        let relative: ArraySlice<String>
        if lexicalTarget.pathComponents.starts(with: lexicalAnchor.pathComponents) {
            relative = lexicalTarget.pathComponents.dropFirst(lexicalAnchor.pathComponents.count)
        } else if lexicalTarget.pathComponents.starts(with: anchor.pathComponents) {
            relative = lexicalTarget.pathComponents.dropFirst(anchor.pathComponents.count)
        } else { return .unavailable }
        guard target.pathComponents == anchor.pathComponents + relative else { return .unavailable }
        do {
            let file = try identity(at: url)
            let parent = try identity(at: url.deletingLastPathComponent())
            guard parent.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { return .unavailable }
            return .present(file, parent: parent.node)
        } catch let error as POSIXError where error.code == .ENOENT {
            var ancestor = url.deletingLastPathComponent()
            while ancestor.standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: anchor.pathComponents) {
                do {
                    let parent = try identity(at: ancestor)
                    guard parent.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { return .unavailable }
                    let relative = Array(ancestor.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(anchor.pathComponents.count))
                    return .missing(ancestor: relative, identity: parent.node)
                } catch let error as POSIXError where error.code == .ENOENT { ancestor.deleteLastPathComponent() }
                catch { return .unavailable }
            }
            return .unavailable
        } catch { return .unavailable }
    }

    private static func validateObservation(_ expected: FileObservation, at url: URL) throws {
        guard expected != .unavailable, observe(url) == expected else { throw OwnershipError.sourceChanged }
    }

    private static func validRecoveryPath(_ path: String) -> Bool {
        if path == "." { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if parts.count == 1 { return UUID(uuidString: path) != nil || path.lowercased().hasSuffix(".kdbx") }
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && path.lowercased().hasSuffix(".kdbx")
    }

    private static func recoveryURL(_ path: String, databaseID: UUID) -> URL {
        path == "." ? directoryURL(for: databaseID) : directoryURL(for: databaseID).appendingPathComponent(path)
    }

    private static func receipt(at url: URL, databaseID: UUID) throws -> Receipt {
        let relative = relativePath(url, databaseID: databaseID)
        let resolved = try sourceURL(relative, databaseID: databaseID)
        guard case .present(let file, let parent) = observe(resolved),
              file.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else { throw OwnershipError.sourceChanged }
        let digest = FileDigest.sha512(try Data(contentsOf: resolved))
        guard case .present(let after, let afterParent) = observe(resolved), after == file, afterParent == parent else {
            throw OwnershipError.sourceChanged
        }
        return Receipt(relativePath: relative, identity: file, parentIdentity: parent, digest: digest)
    }

    private static func validate(_ expected: Receipt, databaseID: UUID) throws {
        guard try receipt(at: sourceURL(expected.relativePath, databaseID: databaseID), databaseID: databaseID) == expected else {
            throw OwnershipError.sourceChanged
        }
    }

    private static func exists(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private static func ownerData(_ databaseID: UUID) throws -> Data? {
        let url = stateURL(databaseID)
        return try exists(url) ? Data(contentsOf: url) : nil
    }
    private static func tombstoned(_ databaseID: UUID) throws -> Bool {
        try exists(controlDirectory(databaseID).appendingPathComponent(".tombstone"))
    }
    private static func loadState(_ databaseID: UUID) throws -> OwnerState? {
        guard let data = try ownerData(databaseID) else { return nil }
        let state = try JSONDecoder().decode(OwnerState.self, from: data)
        guard state.version == 1, (state.retirementID == nil) == (state.retiringEntries == nil) else { throw OwnershipError.recoveryRequired }
        guard (state.retiringEntries ?? []).allSatisfy({ validRecoveryPath($0.relativePath) }),
              Set(state.sources.map(\.id)).count == state.sources.count,
              Set(state.sources.map(\.relativePath)).count == state.sources.count else { throw OwnershipError.recoveryRequired }
        for source in state.sources {
            _ = try sourceURL(source.relativePath, databaseID: databaseID)
            guard source.relativePath.hasPrefix(source.id.uuidString + "/"), source.intendedSHA512.count == 64 else { throw OwnershipError.recoveryRequired }
            if case .eligible(let receipt) = source.phase {
                guard receipt.relativePath == source.relativePath, receipt.digest == source.intendedSHA512,
                      source.epochID != nil else { throw OwnershipError.recoveryRequired }
            }
        }
        if let admission = state.operation.admission {
            guard admission.baseline.count == 64, admission.intendedSHA512 == nil || admission.intendedSHA512?.count == 64,
                  Set(admission.sources.map(\.relativePath)).count == admission.sources.count,
                  !admission.purpose.isMasterKeyChange || admission.sources.isEmpty else { throw OwnershipError.recoveryRequired }
            for receipt in admission.sources {
                _ = try sourceURL(receipt.relativePath, databaseID: databaseID)
                guard receipt.digest.count == 64 else { throw OwnershipError.recoveryRequired }
            }
        }
        if let evidence = state.keyEvidence {
            guard state.epoch.id == evidence.epochID, evidence.sha512.count == 64,
                  evidence.associationRegistrySHA512.count == 64,
                  evidence.pending == nil || evidence.pending?.sha512.count == 64 else { throw OwnershipError.recoveryRequired }
        }
        return state
    }
    private static func publish(_ state: OwnerState, databaseID: UUID, io: StorageIO = .init()) throws -> DurableWriteOutcome {
        let url = stateURL(databaseID)
        let outcome = writeWithDurabilityOutcome(try JSONEncoder().encode(state), to: url, io: io.fileIO(url))
        changed()
        return outcome
    }
    private static func persist(_ state: OwnerState, databaseID: UUID, io: StorageIO = .init()) throws {
        switch try publish(state, databaseID: databaseID, io: io) {
        case .durable: return
        case .notPublished(let error), .publishedWithoutConfirmedDurability(let error): throw error
        }
    }
    private static func resolution(_ outcome: DurableWriteOutcome) -> ResolutionOutcome {
        switch outcome {
        case .durable: .resolved
        case .publishedWithoutConfirmedDurability: .resolvedVisibleWithoutConfirmedDurability
        case .notPublished: .retainedForRecovery
        }
    }
    private static func checkEpoch(_ state: inout OwnerState, expected: Date?) throws {
        switch state.epoch {
        case .unobserved: state.epoch = .known(expected, UUID())
        case .known(let current, _): guard current == expected else { throw OwnershipError.recoveryRequired }
        }
    }
    private static func validateEligible(_ receipt: Receipt, state: OwnerState, databaseID: UUID) throws {
        try validate(receipt, databaseID: databaseID)
        if receipt.relativePath.contains("/") {
            guard state.sources.contains(where: { $0.relativePath == receipt.relativePath && $0.phase == .eligible(receipt) && $0.epochID == state.epoch.id && $0.epochID != nil }) else {
                throw OwnershipError.recoveryRequired
            }
        }
    }
    private static func removeDurably(_ path: String, databaseID: UUID, io: StorageIO) throws {
        let url = try sourceURL(path, databaseID: databaseID)
        try io.remove(url)
        let parent = url.deletingLastPathComponent()
        try io.synchronize(parent)
        if UUID(uuidString: parent.lastPathComponent) != nil, parent.lastPathComponent != databaseID.uuidString,
           try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty {
            try io.remove(parent)
            try io.synchronize(parent.deletingLastPathComponent())
        }
    }
    static func sharedCopyURL(for databaseID: UUID) -> URL {
        (ownerContainer ?? AppGroupContainer.url).appendingPathComponent("databases", isDirectory: true)
            .appendingPathComponent(databaseID.uuidString + ".kdbx")
    }
    private static func requireNotRemoved(_ databaseID: UUID) throws {
        if try tombstoned(databaseID) || loadState(databaseID)?.removed == true { throw OwnershipError.removed }
        guard let anchor = ownerContainer else { throw OwnershipError.recoveryRequired }
        // A reader can observe a rename whose final sync failed; mutations reconfirm it while holding flock.
        let owner = stateURL(databaseID)
        if try exists(owner) {
            let handle = try FileHandle(forUpdating: owner)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        try createDurableDirectory(at: controlDirectory(databaseID), anchor: anchor)
    }
    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
    private static func stateURL(_ id: UUID) -> URL { controlDirectory(id).appendingPathComponent("owner.json") }
    private static func controlDirectory(_ id: UUID) -> URL {
        (ownerContainer ?? AppGroupContainer.url).appendingPathComponent("pending-local-save-owners", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private static var rootURL: URL { (ownerContainer ?? AppGroupContainer.url).appendingPathComponent("pending-local-saves", isDirectory: true) }
    private static func directoryURL(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
}
