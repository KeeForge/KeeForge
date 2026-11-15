import Foundation

/// Pure admission and transition policy; storage and provider calls belong to the adapters.
enum CloudJournalDecision {
    enum State: Equatable { case legacy, prepared, ready, attempting, confirmed, recoveryRequired, invalid }
    enum Event { case payloadInstalled, dispatch, acknowledged, rejectedBeforeCommit, localReconciled, interruption }
    enum Effect: Equatable { case persist, replaceCache, upload, publishReference, retire, retainForRecovery }
    struct Transition: Equatable {
        let state: State
        let effects: [Effect]
    }

    static func state(of marker: PendingUploadQueue.Marker) -> State {
        if let version = marker.journalVersion, version != 1 { return .invalid }
        if let binding = marker.binding, !binding.isRecognized { return .recoveryRequired }
        guard marker.journalVersion != nil else { return .legacy }
        guard marker.binding != nil else { return .recoveryRequired }
        guard marker.intendedPayloadPath != nil, marker.intendedPayloadSHA512 != nil,
              marker.localCommitBaseline != nil else { return .invalid }
        if marker.requiresLocalRecovery == true { return .recoveryRequired }
        if marker.confirmedAt != nil { return .confirmed }
        if marker.uploadAttemptID != nil && marker.attemptIsFenced != true { return .attempting }
        if marker.isPayloadFinalized == false && marker.keyChange == nil { return .prepared }
        guard marker.isPayloadFinalized == true || marker.keyChange != nil else { return .invalid }
        return .ready
    }

    static func transition(from state: State, on event: Event) -> Transition? {
        switch (state, event) {
        case (.prepared, .payloadInstalled): .init(state: .ready, effects: [.persist, .publishReference])
        case (.ready, .dispatch): .init(state: .attempting, effects: [.persist, .upload])
        case (.attempting, .acknowledged), (.ready, .acknowledged): .init(state: .confirmed, effects: [.persist, .publishReference])
        case (.attempting, .rejectedBeforeCommit): .init(state: .ready, effects: [.persist])
        case (.confirmed, .localReconciled): .init(state: .confirmed, effects: [.retire])
        case (.attempting, .interruption): .init(state: .attempting, effects: [.retainForRecovery])
        default: nil
        }
    }

    enum Delivery: Equatable { case reconcile, retain, conflict, dispatch }
    struct DeliverySnapshot {
        let marker: PendingUploadQueue.Marker
        let siblings: [PendingUploadQueue.Marker]
        let siblingIDs: Set<UUID>
        let epoch: UUID?
        let lastMasterKeyChangeAt: Date?
        let payloadMatches: Bool
    }

    static func delivery(_ snapshot: DeliverySnapshot) -> Delivery {
        let marker = snapshot.marker
        if marker.binding == nil || marker.binding?.isRecognized != true {
            if marker.uploadAttemptID != nil && marker.confirmedAt == nil && marker.attemptIsFenced != true { return .retain }
            return marker.journalVersion == nil && marker.isPayloadFinalized == true ? .conflict : .retain
        }
        if state(of: marker) == .confirmed { return .reconcile }
        if snapshot.siblings.contains(where: {
            $0.keyChange != nil || ($0.uploadAttemptID != nil && $0.confirmedAt == nil && $0.attemptIsFenced != true)
        }) { return .retain }
        if marker.uploadAttemptID == nil, marker.keyChange == nil,
           snapshot.siblings.contains(where: { $0.isConflicted }) { return .retain }
        if marker.requiresLocalRecovery == true { return .conflict }
        if let predecessor = marker.predecessorOperationID, snapshot.siblingIDs.contains(predecessor) { return .retain }
        guard marker.isPayloadFinalized == true || marker.keyChange != nil else {
            return marker.isPayloadFinalized == nil ? .conflict : .retain
        }
        guard snapshot.payloadMatches else { return .conflict }
        if marker.keyChange == nil,
           marker.keyEpoch != snapshot.epoch || (marker.keyEpoch == nil && snapshot.lastMasterKeyChangeAt.map { marker.createdAt < $0 } == true) {
            return .conflict
        }
        return transition(from: state(of: marker), on: .dispatch) == nil ? .retain : .dispatch
    }

    enum Completion: Equatable { case publishKeyEpoch, reconfirmKeyEpoch, restoreHead, restoreDescendant, reject }
    struct CompletionSnapshot {
        let marker: PendingUploadQueue.Marker
        let operationID: UUID
        let head: UUID?
        let epoch: UUID?
        let lastMasterKeyChangeAt: Date?
        let hasVerifiedDescendant: Bool
    }

    static func completion(_ snapshot: CompletionSnapshot) -> Completion {
        let marker = snapshot.marker
        guard state(of: marker) == .confirmed else { return .reject }
        if let change = marker.keyChange {
            if snapshot.epoch == change.epoch {
                return snapshot.head == snapshot.operationID ? .reconfirmKeyEpoch : .reject
            }
            return snapshot.lastMasterKeyChangeAt.map { $0 > marker.createdAt } == true ? .reject : .publishKeyEpoch
        }
        guard marker.keyEpoch == snapshot.epoch,
              !(marker.keyEpoch == nil && snapshot.lastMasterKeyChangeAt.map { marker.createdAt < $0 } == true) else { return .reject }
        if snapshot.head == snapshot.operationID { return .restoreHead }
        return snapshot.hasVerifiedDescendant ? .restoreDescendant : .reject
    }

    static func permitsAuthenticatedMergeSource(_ source: PendingUploadQueue.StoredMarker, reference: DatabaseReference) -> Bool {
        let marker = source.marker
        guard marker.databaseId == reference.id, marker.isPayloadFinalized == true,
              marker.confirmedAt == nil, marker.uploadAttemptID == nil || marker.attemptIsFenced == true,
              marker.intendedPayloadPath != nil, marker.intendedPayloadSHA512 != nil else { return false }
        if marker.journalVersion == nil && marker.binding == nil { return true }
        return state(of: marker) == .ready && marker.keyEpoch == reference.cloudSyncMetadata?.keyEpoch
            && marker.localCommitBaseline?.hasCompatibleEpoch(reference) == true
            && PendingUploadQueue.hasBoundAuthority(source, reference: reference)
    }

    static func permitsMutation(_ markers: [PendingUploadQueue.Marker], changingKey: Bool) -> Bool {
        guard !markers.contains(where: {
            [.invalid, .prepared, .attempting, .recoveryRequired].contains(state(of: $0)) || $0.keyChange != nil
                || (state(of: $0) == .legacy && $0.isPayloadFinalized != true)
        }) else { return false }
        return !changingKey || markers.isEmpty
    }

    static func trustedBaseUnchanged(
        marker: PendingUploadQueue.Marker, recorded: CloudSyncMetadata, remote: CloudFileMetadata,
        revisionIsContentIdentity: Bool
    ) -> Bool {
        guard state(of: marker) == .ready, marker.uploadAttemptID == nil || marker.attemptIsFenced == true,
              marker.remoteBaseSHA512 != nil else { return false }
        if marker.expectedRev == nil, marker.baseRev == nil { return false }
        if revisionIsContentIdentity, let expected = marker.expectedRev, let rev = remote.rev { return expected == rev }
        if let hash = recorded.remoteContentHash, let observed = remote.contentHash { return hash == observed }
        return false
    }
}
