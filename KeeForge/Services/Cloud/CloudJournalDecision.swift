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
        guard marker.journalVersion != nil else { return .legacy }
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

    static func permitsMutation(_ markers: [PendingUploadQueue.Marker], changingKey: Bool) -> Bool {
        guard !markers.contains(where: {
            [.invalid, .prepared, .attempting, .recoveryRequired].contains(state(of: $0)) || $0.keyChange != nil
                || (state(of: $0) == .legacy && $0.isPayloadFinalized != true)
        }) else { return false }
        return !changingKey || markers.isEmpty
    }

    static func trustedBaseUnchanged(
        marker: PendingUploadQueue.Marker, recorded: CloudSyncMetadata, remote: CloudFileMetadata
    ) -> Bool {
        guard state(of: marker) == .ready, marker.uploadAttemptID == nil || marker.attemptIsFenced == true,
              marker.remoteBaseSHA512 != nil else { return false }
        if let expected = marker.expectedRev, let rev = remote.rev { return expected == rev }
        if let hash = recorded.remoteContentHash, let observed = remote.contentHash { return hash == observed }
        return false
    }
}
