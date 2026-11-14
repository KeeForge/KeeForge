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
        case ordinarySave
        case masterKeyChange(KeyFileAssociation?)
        var isMasterKeyChange: Bool {
            if case .masterKeyChange = self { return true }
            return false
        }
    }

    // A pre-replacement failure must retain the previous commit's unresolved durability.
    struct PreviousOrdinaryCommit: Codable, Sendable, Equatable {
        let operationID: UUID
        let target: TargetIdentity
        let baseline: Data
        let observedMasterKeyChangeAt: Date?
        let commit: TargetCommit
    }

    struct Admission: Codable, Sendable, Equatable {
        let operationID: UUID
        let purpose: Purpose
        let sources: [Receipt]
        let target: TargetIdentity
        let baseline: Data
        let observedMasterKeyChangeAt: Date?
        var intendedSHA512: Data?
        var knownTarget: TargetCommit?
        var previousKnown: PreviousOrdinaryCommit?
    }

    struct Token: Sendable, Equatable {
        let databaseID: UUID
        let admission: Admission
        let ownerVersion = 1
    }

    struct CommitReceipt: Sendable, Equatable {
        let databaseID: UUID
        let admission: Admission?
        let sha512: Data
        var targetCommit: TargetCommit?
        var encryptedSnapshot: Data?
        var targetDurabilityConfirmed: Bool { targetCommit?.isConfirmed == true }
        var installedTarget: TargetIdentity? { targetCommit?.snapshot.target }
        let ownerVersion = 1
        let operationID: UUID
        var purpose: Purpose? { admission?.purpose }
        init(databaseID: UUID, admission: Admission? = nil, sha512: Data, operationID: UUID? = nil) {
            self.databaseID = databaseID
            self.admission = admission
            self.sha512 = sha512
            self.operationID = admission?.operationID ?? operationID ?? UUID()
        }
    }

    struct KeyFilePreference: Codable, Sendable, Equatable {
        let bookmarkData: Data?
        let filename: String?
        init(bookmarkData: Data?, filename: String?) { self.bookmarkData = bookmarkData; self.filename = filename }
        init(_ reference: DatabaseReference) { self.init(bookmarkData: reference.keyFileBookmarkData, filename: reference.keyFileFilename) }
    }
    struct PreferenceObservation: Codable, Sendable, Equatable {
        let databaseID: UUID
        let targetBookmarkData: Data?
        let preference: KeyFilePreference
        let masterKeyChangedAt: Date?
        let cloudIdentity: [String]?
        init(_ reference: DatabaseReference) {
            databaseID = reference.id
            targetBookmarkData = reference.bookmarkData
            preference = KeyFilePreference(reference)
            masterKeyChangedAt = reference.lastMasterKeyChangeAt
            cloudIdentity = reference.cloudSyncMetadata.map { [String(describing: $0.provider), $0.accountId, $0.fileId] }
        }
        func matches(_ reference: DatabaseReference, preference override: KeyFilePreference? = nil) -> Bool {
            let current = PreferenceObservation(reference)
            return databaseID == current.databaseID && targetBookmarkData == current.targetBookmarkData
                && masterKeyChangedAt == current.masterKeyChangedAt && cloudIdentity == current.cloudIdentity
                && current.preference == (override ?? preference)
        }
    }
    struct PreferenceIntent: Codable, Sendable, Equatable {
        let operationID: UUID
        let observation: PreferenceObservation
        let expectedEpochID: UUID?
        let expectedAssociationVersion: UUID?
        let desired: KeyFilePreference
    }
    struct PreferenceToken: Sendable {
        let operationID: UUID
        let observation: PreferenceObservation
        let expectedEpochID: UUID?
        let expectedAssociationVersion: UUID?
        let witness: KeyEpochEvidence?
    }
    enum PreferencePublication {
        case notStarted
        case intentUnconfirmed
        case registry(DurableWriteOutcome, PreferenceIntent)
    }

    private enum Operation: Codable, Equatable {
        case idle
        case admitted(Admission)
        case recoveryRequired(Admission)
        case preference(PreferenceIntent)
        var preferenceIntent: PreferenceIntent? { if case .preference(let value) = self { return value }; return nil }
        var admission: Admission? {
            switch self {
            case .idle, .preference: nil
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
    struct InstalledTarget: Codable, Sendable, Equatable {
        let target: TargetIdentity
        let sha512: Data
    }

    enum TargetCommit: Codable, Sendable, Equatable {
        case confirmed(InstalledTarget)
        case unconfirmed(InstalledTarget)
        var snapshot: InstalledTarget {
            switch self { case .confirmed(let value), .unconfirmed(let value): value }
        }
        var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
        var withoutConfirmation: TargetCommit { .unconfirmed(snapshot) }
    }

    enum KeyTargetState: Codable, Sendable, Equatable {
        case confirmed(InstalledTarget)
        case readyToRetire(InstalledTarget)
        case unconfirmed(InstalledTarget)
        case planned(previous: InstalledTarget, intent: PlannedTarget)

        init(_ commit: TargetCommit) {
            switch commit { case .confirmed(let value): self = .confirmed(value); case .unconfirmed(let value): self = .unconfirmed(value) }
        }
        var snapshot: InstalledTarget {
            switch self { case .confirmed(let value), .readyToRetire(let value), .unconfirmed(let value), .planned(let value, _): value }
        }
        var pending: PlannedTarget? { if case .planned(_, let intent) = self { return intent }; return nil }
        var isConfirmed: Bool {
            switch self { case .confirmed, .readyToRetire: true; case .unconfirmed, .planned: false }
        }
        var isReadyToRetire: Bool { if case .readyToRetire = self { return true }; return false }

        func finalized(with commit: TargetCommit, operationID: UUID? = nil) throws -> KeyTargetState {
            let observed = commit.snapshot
            if case .planned(let previous, let intent) = self {
                guard operationID == nil || operationID == intent.operationID,
                      observed.target.canonicalPath == previous.target.canonicalPath, observed.target.parent == previous.target.parent,
                      observed.sha512 == intent.sha512 || (operationID == nil && observed == previous) else { throw OwnershipError.targetChanged }
                // Recovery has no synchronization proof for the planned output.
                return KeyTargetState(operationID == nil ? commit.withoutConfirmation : commit)
            }
            guard observed == snapshot else { throw OwnershipError.targetChanged }
            return KeyTargetState(commit)
        }

        func recovered(at target: TargetIdentity, sha512: Data) throws -> KeyTargetState {
            let observed = InstalledTarget(target: target, sha512: sha512)
            return try finalized(with: isConfirmed ? .confirmed(observed) : .unconfirmed(observed))
        }
    }

    struct KeyEpochEvidence: Codable, Sendable, Equatable {
        let epochID: UUID
        var association: KeyFileAssociation
        var associationRegistrySHA512: Data
        var targetState: KeyTargetState
        var target: TargetIdentity { targetState.snapshot.target }
        var sha512: Data { targetState.snapshot.sha512 }
        var targetDurabilityUnconfirmed: Bool { !targetState.isConfirmed }
        var pending: PlannedTarget? { targetState.pending }
    }
    struct TargetWriteToken: Sendable {
        let databaseID: UUID
        let operationID: UUID
    }
    struct AuthorizedWrite<Value> {
        let value: Value
        let targetWrite: TargetWriteToken?
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
        var associationVersion: UUID?
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
        var admissionCoordinationCompletion: @Sendable () throws -> Void = {}
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
        let associationVersion: UUID?
        let preferenceIntent: PreferenceIntent?
        let ownerObservation: FileObservation
        let entries: [SourceSnapshot]
        let ownerUnavailable: Bool
        var recoveryKeyFileFilename: String? {
            if let preferenceIntent { return preferenceIntent.desired.filename }
            return keyAssociationForRecovery?.filename
        }
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
        var needsRecovery: Bool { preferenceIntent != nil || isRevoked || retirementID != nil || admission != nil || sourcePublicationPending || keyEvidence?.pending != nil || ownerUnavailable || entries.contains { $0.receipt == nil } }
    }

    enum OwnershipError: Error, LocalizedError, Equatable {
        case recoveryRequired, sourceChanged, removed, targetChanged
        var errorDescription: String? {
            if case .targetChanged = self {
                return String(localized: "The database file changed since it was opened. Reload the database and try again.")
            }
            return String(localized: "Local save recovery is required. Open Database Details to review the saved key record and recovery actions.")
        }
    }

    @TaskLocal private static var ownerContainer: URL?
    @TaskLocal static var saveToken: Token?
    @TaskLocal static var cacheCommit: CommitReceipt?
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

    static func requiresConflictRecovery(for reference: DatabaseReference) -> Bool {
        let databaseID = reference.id
        do {
            return try withLock(for: databaseID) {
                try requireNotRemoved(databaseID)
                let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
                if case .known(let date, _) = state.epoch, date != reference.lastMasterKeyChangeAt { return true }
                let hasPayload = try !sourceURLs(databaseID).isEmpty
                return state.operation != .idle || state.retirementID != nil || state.keyEvidence != nil
                    || !state.sources.isEmpty || hasPayload
            }
        } catch { return true }
    }

    static func hasSaves(for databaseID: UUID) -> Bool {
        do {
            return try withLock(for: databaseID) {
                let state = try loadState(databaseID)
                return try state?.retirementID != nil || state.map { $0.operation != .idle } == true || state?.keyEvidence?.pending != nil || state?.sources.isEmpty == false || !sourceURLs(databaseID).isEmpty
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
                let knownOrdinary = state.operation.admission.map { $0.purpose == .ordinarySave && $0.sources.isEmpty && $0.knownTarget != nil } == true
                guard preparesSource || state.operation == .idle || (!isMasterKeyChange && knownOrdinary) else { throw OwnershipError.recoveryRequired }
            }
            if isMasterKeyChange {
                guard state.operation == .idle, state.sources.isEmpty, try sourceURLs(databaseID).isEmpty else { throw OwnershipError.recoveryRequired }
            }
        }
    }

    static func admit(
        _ receipts: [Receipt], for databaseID: UUID, target: TargetIdentity,
        baseline: Data, masterKeyChangedAt: Date?, purpose: Purpose = .merge, io: StorageIO = .init()
    ) throws -> Token {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            var previousKnown: PreviousOrdinaryCommit?
            if state.operation != .idle {
                guard purpose == .ordinarySave, receipts.isEmpty, let previous = state.operation.admission,
                      previous.purpose == .ordinarySave, previous.sources.isEmpty, let known = previous.knownTarget,
                      known.snapshot.target == target, known.snapshot.sha512 == baseline,
                      previous.observedMasterKeyChangeAt == masterKeyChangedAt else { throw OwnershipError.recoveryRequired }
                previousKnown = PreviousOrdinaryCommit(operationID: previous.operationID, target: previous.target,
                    baseline: previous.baseline, observedMasterKeyChangeAt: previous.observedMasterKeyChangeAt, commit: known)
            }
            guard state.retirementID == nil, state.keyEvidence?.pending == nil,
                  !state.sources.contains(where: { $0.phase == .provisional || $0.epochID != state.epoch.id }) else { throw OwnershipError.recoveryRequired }
            try checkEpoch(&state, expected: masterKeyChangedAt)
            for receipt in receipts { try validateEligible(receipt, state: state, databaseID: databaseID) }
            guard purpose == .merge || (purpose == .ordinarySave && receipts.isEmpty) else { throw OwnershipError.recoveryRequired }
            let admission = Admission(operationID: UUID(), purpose: purpose, sources: receipts,
                target: target, baseline: baseline, observedMasterKeyChangeAt: masterKeyChangedAt, previousKnown: previousKnown)
            state.operation = .admitted(admission)
            let token = Token(databaseID: databaseID, admission: admission)
            switch try publish(state, databaseID: databaseID, io: io) {
            case .durable: return token
            case .notPublished(let error): throw error
            case .publishedWithoutConfirmedDurability(let error):
                throw AdmissionPublicationFailure(token: token, underlying: error)
            }
        }
    }

    /// Coordination precedes flock; target observation and replacement stay under the same flock.
    static func withWriteAuthorization<T>(
        for databaseID: UUID, token: Token?, expectedMasterKeyChangeAt: Date?, enforcesEpoch: Bool,
        isMasterKeyChange: Bool, association: KeyFileAssociation?, prepared: PreparedSource?,
        intendedSHA512: Data, observeTarget: () throws -> (TargetIdentity, Data),
        targetIsSharedCopy: Bool,
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
            var targetWrite: TargetWriteToken?
            if let evidence = state.keyEvidence, !isMasterKeyChange, !targetIsSharedCopy {
                let intent = PlannedTarget(operationID: UUID(), sha512: intendedSHA512)
                state.keyEvidence?.targetState = .planned(previous: evidence.targetState.snapshot, intent: intent)
                try persist(state, databaseID: databaseID, io: io)
                targetWrite = TargetWriteToken(databaseID: databaseID, operationID: intent.operationID)
                if committed == nil { committed = CommitReceipt(databaseID: databaseID, sha512: intendedSHA512, operationID: intent.operationID) }
            }
            if let prepared {
                guard prepared.save.databaseID == databaseID,
                      state.sources.contains(where: { $0.id == prepared.sourceID && $0.phase == .provisional
                        && $0.intendedSHA512 == prepared.receipt.digest && $0.epochID == state.epoch.id && $0.epochID != nil }) else {
                    throw OwnershipError.sourceChanged
                }
                try validate(prepared.receipt, databaseID: databaseID)
            }
            return AuthorizedWrite(value: try replace(committed), targetWrite: targetWrite)
        }
    }

    static func finishTargetWrite(
        _ token: TargetWriteToken, commit: TargetCommit, observeTarget: () throws -> (TargetIdentity, Data), io: StorageIO = .init()
    ) -> ResolutionOutcome {
        do {
            return try withLock(for: token.databaseID) {
                try requireNotRemoved(token.databaseID)
                var state = try loadState(token.databaseID) ?? OwnerState(version: 1, removed: false)
                guard let evidence = state.keyEvidence, evidence.pending?.operationID == token.operationID else { throw OwnershipError.sourceChanged }
                let (target, sha) = try observeTarget()
                guard InstalledTarget(target: target, sha512: sha) == commit.snapshot else { throw OwnershipError.targetChanged }
                state.keyEvidence?.targetState = try evidence.targetState.finalized(with: commit, operationID: token.operationID)
                return try resolution(publish(state, databaseID: token.databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func releaseAfterProvenNoReplacement(_ token: Token, io: StorageIO = .init()) -> ResolutionOutcome {
        do {
            return try withLock(for: token.databaseID) {
                try requireNotRemoved(token.databaseID)
                var state = try loadState(token.databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.version == token.ownerVersion, let admission = state.operation.admission,
                      admission.operationID == token.admission.operationID, admission.sources == token.admission.sources,
                      admission.target == token.admission.target, admission.baseline == token.admission.baseline,
                      admission.purpose == token.admission.purpose,
                      admission.observedMasterKeyChangeAt == token.admission.observedMasterKeyChangeAt,
                      admission.knownTarget == nil, admission.previousKnown == token.admission.previousKnown else { throw OwnershipError.sourceChanged }
                if let previous = admission.previousKnown {
                    state.operation = .recoveryRequired(Admission(operationID: previous.operationID, purpose: .ordinarySave,
                        sources: [], target: previous.target, baseline: previous.baseline,
                        observedMasterKeyChangeAt: previous.observedMasterKeyChangeAt,
                        intendedSHA512: previous.commit.snapshot.sha512, knownTarget: previous.commit))
                } else { state.operation = .idle }
                return try resolution(publish(state, databaseID: token.databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func recordKnownOrdinaryCommit(
        _ commit: CommitReceipt, observeTarget: () throws -> (TargetIdentity, Data), io: StorageIO = .init()
    ) -> ResolutionOutcome {
        do {
            return try withLock(for: commit.databaseID) {
                try requireNotRemoved(commit.databaseID)
                var state = try loadState(commit.databaseID) ?? OwnerState(version: 1, removed: false)
                guard case .recoveryRequired(var admission) = state.operation,
                      admission == commit.admission, admission.purpose == .ordinarySave, admission.sources.isEmpty,
                      let known = commit.targetCommit, known.snapshot.sha512 == admission.intendedSHA512 else { throw OwnershipError.sourceChanged }
                let (target, sha) = try observeTarget()
                guard target == known.snapshot.target, sha == known.snapshot.sha512 else { throw OwnershipError.targetChanged }
                admission.knownTarget = known
                admission.previousKnown = nil
                state.operation = .recoveryRequired(admission)
                return try resolution(publish(state, databaseID: commit.databaseID, io: io))
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
                      admission.intendedSHA512 == commit.sha512, (admission.purpose == .merge || admission.purpose == .ordinarySave),
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

    struct CacheReadLease: Sendable {
        let databaseID: UUID
        let epochID: UUID?
        let masterKeyChangedAt: Date?
        let reference: PreferenceObservation
    }

    static func captureCacheReadLease(for reference: DatabaseReference) throws -> CacheReadLease {
        try withLock(for: reference.id) {
            try requireNotRemoved(reference.id)
            let state = try loadState(reference.id) ?? OwnerState(version: 1, removed: false)
            if case .known(let date, _) = state.epoch, date != reference.lastMasterKeyChangeAt { throw OwnershipError.sourceChanged }
            return CacheReadLease(databaseID: reference.id, epochID: state.epoch.id, masterKeyChangedAt: reference.lastMasterKeyChangeAt, reference: PreferenceObservation(reference))
        }
    }

    struct ReadKeyPublication: Sendable {
        let lease: CacheReadLease
        let target: TargetIdentity
        let sha512: Data
        let sharedCopy: Bool
    }

    static func withKeyCommitPublicationAuthorization<T>(
        _ receipt: CommitReceipt, reference: DatabaseReference, _ publish: () throws -> T
    ) throws -> T {
        try withLock(for: receipt.databaseID) {
            try requireNotRemoved(receipt.databaseID)
            let state = try loadState(receipt.databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.version == receipt.ownerVersion, state.retirementID == nil,
                  let admission = receipt.admission, case .masterKeyChange(let association?) = admission.purpose,
                  let commit = receipt.targetCommit, commit.snapshot.sha512 == receipt.sha512,
                  admission.intendedSHA512 == receipt.sha512,
                  admission.target.canonicalPath == commit.snapshot.target.canonicalPath,
                  admission.target.parent == commit.snapshot.target.parent else { throw OwnershipError.sourceChanged }
            let ownsBarrier = state.operation.admission == admission
            let ownsEpoch = state.operation == .idle && state.epoch.id == receipt.operationID
                && state.keyEvidence?.pending == nil
                && (state.associationVersion == nil || state.associationVersion == receipt.operationID)
                && reference.lastMasterKeyChangeAt == association.changedAt
                && reference.keyFileBookmarkData == association.bookmarkData && reference.keyFileFilename == association.filename
            guard ownsBarrier || ownsEpoch else { throw OwnershipError.sourceChanged }
            if !ownsBarrier, let evidence = state.keyEvidence {
                guard evidence.epochID == receipt.operationID, evidence.targetState.snapshot == commit.snapshot else {
                    throw OwnershipError.sourceChanged
                }
            }
            return try publish()
        }
    }

    static func withReadKeyPublicationAuthorization<T>(_ read: ReadKeyPublication, _ publish: () throws -> T) throws -> T {
        try withLock(for: read.lease.databaseID) {
            try requireNotRemoved(read.lease.databaseID)
            let state = try loadState(read.lease.databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.epoch.id == read.lease.epochID, state.operation == .idle, state.retirementID == nil else { throw OwnershipError.recoveryRequired }
            if case .known(let date, _) = state.epoch, date != read.lease.masterKeyChangedAt { throw OwnershipError.sourceChanged }
            if let evidence = state.keyEvidence {
                guard evidence.pending == nil else { throw OwnershipError.recoveryRequired }
                try validateKeyTarget(evidence, target: read.target, sha512: read.sha512, sharedCopy: read.sharedCopy, state: state)
            }
            return try publish()
        }
    }

    static func withReferenceEpochAuthorization<T>(_ lease: CacheReadLease, _ publish: () throws -> T) throws -> T {
        try withLock(for: lease.databaseID) {
            try requireNotRemoved(lease.databaseID)
            let state = try loadState(lease.databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.epoch.id == lease.epochID, state.operation == .idle, state.retirementID == nil,
                  state.keyEvidence?.pending == nil else { throw OwnershipError.recoveryRequired }
            if case .known(let date, _) = state.epoch, date != lease.masterKeyChangedAt { throw OwnershipError.sourceChanged }
            return try publish()
        }
    }

    static func withCachePublicationAuthorization<T>(
        for databaseID: UUID, sha512: Data, lease: CacheReadLease? = nil, _ publish: () throws -> T
    ) throws -> T {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            if let lease {
                guard lease.databaseID == databaseID, lease.epochID == state.epoch.id else { throw OwnershipError.sourceChanged }
                if case .known(let date, _) = state.epoch, date != lease.masterKeyChangedAt { throw OwnershipError.sourceChanged }
            }
            if let admission = state.operation.admission, admission.purpose.isMasterKeyChange {
                guard admission.intendedSHA512 == sha512 else { throw OwnershipError.targetChanged }
            } else {
                guard state.retirementID == nil, state.sources.isEmpty, try sourceURLs(databaseID).isEmpty else { throw OwnershipError.recoveryRequired }
                if let admission = state.operation.admission, admission.purpose == .ordinarySave, admission.sources.isEmpty {
                    let supplied = cacheCommit
                    let known = admission.knownTarget ?? supplied.flatMap { proof in
                        proof.databaseID == databaseID && proof.ownerVersion == state.version
                            && proof.operationID == admission.operationID && proof.sha512 == sha512
                            && proof.admission?.purpose == .ordinarySave && proof.admission?.sources == admission.sources
                            && proof.admission?.target == admission.target && proof.admission?.baseline == admission.baseline
                            && proof.admission?.observedMasterKeyChangeAt == admission.observedMasterKeyChangeAt
                            && proof.admission?.intendedSHA512 == admission.intendedSHA512 ? proof.targetCommit : nil
                    }
                    guard let known, known.snapshot.sha512 == sha512, admission.intendedSHA512 == sha512 else { throw OwnershipError.targetChanged }
                } else if state.operation != .idle { throw OwnershipError.recoveryRequired }
                if let evidence = state.keyEvidence {
                    guard evidence.sha512 == sha512 || evidence.pending?.sha512 == sha512 else { throw OwnershipError.targetChanged }
                }
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

    static func capturePreference(_ observation: PreferenceObservation) throws -> PreferenceToken {
        try withLock(for: observation.databaseID) {
            try requireNotRemoved(observation.databaseID)
            let state = try loadState(observation.databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.operation == .idle, state.retirementID == nil, state.keyEvidence?.pending == nil,
                  state.keyEvidence == nil || state.keyEvidence?.association.changedAt == observation.masterKeyChangedAt else {
                throw OwnershipError.recoveryRequired
            }
            return PreferenceToken(operationID: UUID(), observation: observation, expectedEpochID: state.epoch.id,
                expectedAssociationVersion: state.associationVersion, witness: state.keyEvidence)
        }
    }

    static func withIdlePreferenceAuthorization<T>(_ token: PreferenceToken, _ publish: () throws -> T) throws -> T {
        try withLock(for: token.observation.databaseID) {
            try requireNotRemoved(token.observation.databaseID)
            let state = try loadState(token.observation.databaseID) ?? OwnerState(version: 1, removed: false)
            guard token.witness == nil, state.keyEvidence == nil, state.operation == .idle, state.retirementID == nil,
                  state.epoch.id == token.expectedEpochID else { throw OwnershipError.recoveryRequired }
            return try publish()
        }
    }

    static func recoverPreferenceToken(_ expected: PreferenceIntent) throws -> PreferenceToken {
        try withLock(for: expected.observation.databaseID) {
            try requireNotRemoved(expected.observation.databaseID)
            let state = try loadState(expected.observation.databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.operation.preferenceIntent == expected else { throw OwnershipError.sourceChanged }
            return PreferenceToken(operationID: expected.operationID, observation: expected.observation,
                expectedEpochID: expected.expectedEpochID, expectedAssociationVersion: expected.expectedAssociationVersion,
                witness: state.keyEvidence)
        }
    }

    static func withPreferencePublication(
        _ token: PreferenceToken, desired: KeyFilePreference, observeTarget: () throws -> (TargetIdentity, Data)?,
        io: StorageIO = .init(), _ writeRegistry: () -> DurableWriteOutcome
    ) throws -> PreferencePublication {
        try withLock(for: token.observation.databaseID) {
            let id = token.observation.databaseID
            try requireNotRemoved(id)
            var state = try loadState(id) ?? OwnerState(version: 1, removed: false)
            guard state.epoch.id == token.expectedEpochID, state.associationVersion == token.expectedAssociationVersion,
                  state.keyEvidence == token.witness, state.keyEvidence?.pending == nil, state.retirementID == nil else { throw OwnershipError.sourceChanged }
            if let witness = token.witness {
                guard let (target, sha) = try observeTarget(), target == witness.target, sha == witness.sha512 else { throw OwnershipError.targetChanged }
            }
            let intent = PreferenceIntent(operationID: token.operationID, observation: token.observation,
                expectedEpochID: token.expectedEpochID, expectedAssociationVersion: token.expectedAssociationVersion, desired: desired)
            if let existing = state.operation.preferenceIntent {
                guard existing == intent else { throw OwnershipError.sourceChanged }
            } else {
                guard state.operation == .idle else { throw OwnershipError.recoveryRequired }
                state.operation = .preference(intent)
                switch try publish(state, databaseID: id, io: io) {
                case .notPublished: return .notStarted
                case .publishedWithoutConfirmedDurability: return .intentUnconfirmed
                case .durable: break
                }
            }
            return .registry(writeRegistry(), intent)
        }
    }

    static func releaseUnpublishedPreference(_ intent: PreferenceIntent, io: StorageIO = .init()) -> ResolutionOutcome {
        do {
            return try withLock(for: intent.observation.databaseID) {
                try requireNotRemoved(intent.observation.databaseID)
                var state = try loadState(intent.observation.databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.operation.preferenceIntent == intent else { throw OwnershipError.sourceChanged }
                state.operation = .idle
                return try resolution(publish(state, databaseID: intent.observation.databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func finishPreference(
        _ token: PreferenceToken, proof: DatabaseListStore.DurablePreferenceReceipt, io: StorageIO = .init()
    ) -> ResolutionOutcome {
        let intent = proof.intent
        do {
            return try withLock(for: intent.observation.databaseID) {
                let id = intent.observation.databaseID
                try requireNotRemoved(id)
                var state = try loadState(id) ?? OwnerState(version: 1, removed: false)
                guard state.operation.preferenceIntent == intent, intent.operationID == token.operationID,
                      state.epoch.id == token.expectedEpochID, state.associationVersion == token.expectedAssociationVersion,
                      state.keyEvidence == token.witness else { throw OwnershipError.sourceChanged }
                if let witness = state.keyEvidence {
                    state.keyEvidence?.association = KeyFileAssociation(bookmarkData: intent.desired.bookmarkData,
                        filename: intent.desired.filename, changedAt: witness.association.changedAt)
                    state.keyEvidence?.associationRegistrySHA512 = proof.registrySHA512
                }
                state.associationVersion = intent.operationID
                state.operation = .idle
                return try resolution(publish(state, databaseID: id, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func withAssociationPublicationAuthorization<T>(
        for databaseID: UUID, operationID: UUID, association: KeyFileAssociation,
        expectedWitness: KeyEpochEvidence?, expectedAssociationVersion: UUID?, observeTarget: () throws -> (TargetIdentity, Data), _ publish: () throws -> T
    ) throws -> T {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            let state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            let barrierMatches: Bool
            if let admission = state.operation.admission, case .masterKeyChange(let expected) = admission.purpose {
                barrierMatches = admission.operationID == operationID && expected == association
            } else { barrierMatches = false }
            guard state.operation.preferenceIntent == nil, barrierMatches || (state.keyEvidence?.epochID == operationID && state.keyEvidence?.association == association) else {
                throw OwnershipError.sourceChanged
            }
            if !barrierMatches {
                guard let expectedWitness, state.keyEvidence == expectedWitness,
                      state.associationVersion == expectedAssociationVersion else { throw OwnershipError.sourceChanged }
            }
            let (target, sha) = try observeTarget()
            if barrierMatches, let admission = state.operation.admission {
                guard target.canonicalPath == admission.target.canonicalPath, target.parent == admission.target.parent,
                      sha == admission.intendedSHA512 else { throw OwnershipError.targetChanged }
            } else if let evidence = state.keyEvidence {
                guard (target == evidence.target && sha == evidence.sha512)
                    || (target.canonicalPath == evidence.target.canonicalPath && target.parent == evidence.target.parent
                        && sha == evidence.pending?.sha512) else { throw OwnershipError.targetChanged }
            }
            return try publish()
        }
    }

    static func validateReferenceAssociation(_ reference: DatabaseReference) throws {
        try withLock(for: reference.id) {
            try requireNotRemoved(reference.id)
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
                      associationProof.association == association, let installed = commit.installedTarget,
                      let targetCommit = commit.targetCommit, targetCommit.snapshot.sha512 == commit.sha512 else { throw OwnershipError.recoveryRequired }
                let (target, sha) = try observeTarget()
                guard target == installed, sha == commit.sha512, target.canonicalPath == admission.target.canonicalPath,
                      target.parent == admission.target.parent else { throw OwnershipError.targetChanged }
                state.epoch = .known(association.changedAt, commit.operationID)
                state.associationVersion = commit.operationID
                state.keyEvidence = KeyEpochEvidence(epochID: commit.operationID, association: association,
                    associationRegistrySHA512: associationProof.registrySHA512, targetState: KeyTargetState(targetCommit))
                // Arrivals rejected by the key barrier remain recoverable under their original epoch.
                for index in state.sources.indices where state.sources[index].epochID != commit.operationID {
                    state.sources[index].phase = .provisional
                }
                state.operation = .idle
                return try publishSettledState(state, databaseID: commit.databaseID, io: io)
            }
        } catch { return .retainedForRecovery }
    }

    static func confirmKeyEvidence(
        _ expected: KeyEpochEvidence, for databaseID: UUID, expectedAssociationVersion: UUID?,
        associationProof: DatabaseListStore.DurableKeyFileAssociationReceipt,
        observeTarget: () throws -> (TargetIdentity, Data), io: StorageIO = .init()
    ) -> ResolutionOutcome {
        do {
            return try withLock(for: databaseID) {
                try requireNotRemoved(databaseID)
                var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.operation.preferenceIntent == nil, state.keyEvidence == expected, state.epoch.id == expected.epochID,
                      state.associationVersion == expectedAssociationVersion,
                      associationProof.databaseID == databaseID, associationProof.operationID == expected.epochID,
                      associationProof.association == expected.association else {
                    throw OwnershipError.sourceChanged
                }
                let (target, sha) = try observeTarget()
                var confirmed = expected
                confirmed.targetState = try expected.targetState.recovered(at: target, sha512: sha)
                confirmed.associationRegistrySHA512 = associationProof.registrySHA512
                state.keyEvidence = confirmed
                return try resolution(publish(state, databaseID: databaseID, io: io))
            }
        } catch { return .retainedForRecovery }
    }

    static func certifySettledWitness(
        _ expected: KeyEpochEvidence, for databaseID: UUID,
        associationProof: DatabaseListStore.DurableKeyFileAssociationReceipt,
        observeTarget: () throws -> (TargetIdentity, Data), io: StorageIO = .init()
    ) -> ResolutionOutcome {
        do {
            return try withLock(for: databaseID) {
                try requireNotRemoved(databaseID)
                var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
                guard state.keyEvidence == expected, expected.targetState.isConfirmed,
                      associationProof.databaseID == databaseID, associationProof.operationID == expected.epochID,
                      associationProof.association == expected.association else { throw OwnershipError.sourceChanged }
                let (target, sha) = try observeTarget()
                guard target == expected.target, sha == expected.sha512 else { throw OwnershipError.targetChanged }
                state.keyEvidence?.associationRegistrySHA512 = associationProof.registrySHA512
                return try publishSettledState(state, databaseID: databaseID, io: io)
            }
        } catch { return .retainedForRecovery }
    }

    static func resumeCertifiedRetirement(_ expected: KeyEpochEvidence, for databaseID: UUID) -> ResolutionOutcome {
        do {
            return try withLock(for: databaseID) {
                guard expected.targetState.isReadyToRetire, try loadState(databaseID)?.keyEvidence == expected else { throw OwnershipError.sourceChanged }
                try requireNotRemoved(databaseID)
                return .resolved
            }
        }
        catch is RecoveryRecordWarning { return .resolvedVisibleWithoutConfirmedDurability }
        catch { return .retainedForRecovery }
    }

    private static func publishSettledState(_ initial: OwnerState, databaseID: UUID, io: StorageIO) throws -> ResolutionOutcome {
        var state = initial
        guard let evidence = state.keyEvidence, evidence.targetState.isConfirmed,
              state.operation == .idle, state.retirementID == nil,
              state.sources.isEmpty, try sourceURLs(databaseID).isEmpty else {
            return try resolution(publish(state, databaseID: databaseID, io: io))
        }
        // Target, association and receipts settled before this certificate; owner epoch must settle before withdrawal.
        state.keyEvidence?.targetState = .readyToRetire(evidence.targetState.snapshot)
        let certificate = try publish(state, databaseID: databaseID, io: io)
        guard case .durable = certificate else { return resolution(certificate) }
        state.keyEvidence = nil
        state.associationVersion = nil
        return try resolution(publish(state, databaseID: databaseID, io: io))
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
                sourcePublicationPending: publicationPending, keyEvidence: state?.keyEvidence,
                associationVersion: state?.associationVersion, preferenceIntent: state?.operation.preferenceIntent, ownerObservation: ownerObservation, entries: entries,
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

    static func exportKeyEpochCopy(_ expected: Admission, for databaseID: UUID, at url: URL) throws -> Data {
        try withLock(for: databaseID) {
            guard expected.purpose.isMasterKeyChange, expected.sources.isEmpty,
                  let sha = expected.intendedSHA512, try loadState(databaseID)?.operation.admission == expected,
                  case .present(let identity, let parent) = observe(url), identity.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
                throw OwnershipError.sourceChanged
            }
            let bytes = try Data(contentsOf: url)
            guard observe(url) == .present(identity, parent: parent), FileDigest.sha512(bytes) == sha else {
                throw OwnershipError.sourceChanged
            }
            return bytes
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
    static func discard(_ snapshot: RecoverySnapshot, abandonKeyRecord: Bool = false, io: StorageIO = .init()) throws -> ResolutionOutcome {
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
                      state.operation.preferenceIntent == snapshot.preferenceIntent,
                      state.keyEvidence == snapshot.keyEvidence else { throw OwnershipError.sourceChanged }
            }
            guard snapshot.entries.allSatisfy({ validRecoveryPath($0.relativePath) }) else { throw OwnershipError.sourceChanged }
            for entry in snapshot.entries {
                try validateObservation(entry.observation, at: recoveryURL(entry.relativePath, databaseID: snapshot.databaseID))
            }
            if abandonKeyRecord {
                guard snapshot.keyEvidence != nil, state.keyEvidence == snapshot.keyEvidence else { throw OwnershipError.sourceChanged }
            }
            if abandonKeyRecord || snapshot.keyEvidence?.pending != nil || snapshot.preferenceIntent != nil {
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
            if let previous = admission.previousKnown {
                guard admission.purpose == .ordinarySave, admission.sources.isEmpty, admission.knownTarget == nil,
                      previous.operationID != admission.operationID, previous.baseline.count == 64,
                      previous.target.canonicalPath == admission.target.canonicalPath,
                      previous.target.parent == admission.target.parent,
                      previous.commit.snapshot.target == admission.target,
                      previous.commit.snapshot.sha512 == admission.baseline,
                      previous.observedMasterKeyChangeAt == admission.observedMasterKeyChangeAt else { throw OwnershipError.recoveryRequired }
            }
            if let known = admission.knownTarget {
                guard case .recoveryRequired = state.operation else { throw OwnershipError.recoveryRequired }
                guard admission.purpose == .ordinarySave, admission.sources.isEmpty,
                      known.snapshot.sha512 == admission.intendedSHA512, known.snapshot.sha512.count == 64,
                      known.snapshot.target.canonicalPath == admission.target.canonicalPath,
                      known.snapshot.target.parent == admission.target.parent else { throw OwnershipError.recoveryRequired }
            }
            for receipt in admission.sources {
                _ = try sourceURL(receipt.relativePath, databaseID: databaseID)
                guard receipt.digest.count == 64 else { throw OwnershipError.recoveryRequired }
            }
        }
        if let preference = state.operation.preferenceIntent {
            guard state.keyEvidence != nil, preference.observation.databaseID == databaseID, preference.expectedEpochID == state.epoch.id,
                  preference.expectedAssociationVersion == state.associationVersion else { throw OwnershipError.recoveryRequired }
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
        var state = try loadState(databaseID)
        if try tombstoned(databaseID) || state?.removed == true { throw OwnershipError.removed }
        guard let anchor = ownerContainer else { throw OwnershipError.recoveryRequired }
        let owner = stateURL(databaseID)
        if try exists(owner) {
            let handle = try FileHandle(forUpdating: owner)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        try createDurableDirectory(at: controlDirectory(databaseID), anchor: anchor)
        if state?.keyEvidence?.targetState.isReadyToRetire == true {
            // Replayed certificates need owner durability/CAS, not a new permanent target comparison.
            state?.keyEvidence = nil
            if state?.operation.preferenceIntent == nil { state?.associationVersion = nil }
            guard let state else { throw OwnershipError.recoveryRequired }
            switch try publish(state, databaseID: databaseID) {
            case .durable: break
            case .publishedWithoutConfirmedDurability: throw RecoveryRecordWarning()
            case .notPublished(let error): throw error
            }
        }
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
