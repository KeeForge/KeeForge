import SwiftUI

struct CloudRecoveryView: View {
    @State private var uploads: [PendingUploadQueue.StoredMarker] = []
    @State private var creations: [PendingUploadQueue.StoredCreation] = []
    @State private var creationLifetime: CloudCreationLifetime
    @State private var references: [UUID: DatabaseReference] = [:]
    @State private var failure: String?
    @State private var busy = false
    @State private var exporting = false
    @State private var document = KDBXExportDocument(data: Data())
    @State private var filename = "KeeForge.kdbx"
    @State private var creationToDiscard: PendingUploadQueue.StoredCreation?

    init(creationLifetime: CloudCreationLifetime = CloudCreationLifetime()) {
        _creationLifetime = State(initialValue: creationLifetime)
    }

    var body: some View {
        List {
            Section {
                Text("A cloud request may still be running. Keep an encrypted copy. Uncertain requests will not be sent again automatically.")
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            ForEach(creations, id: \.intent.operationID) { stored in
                Section(stored.intent.referenceTemplate.displayName) {
                    let actions = CloudFileCreationCoordinator.RecoveryActions.forPhase(stored.intent.phase)
                    if stored.intent.phase == .attempting {
                        Text("This cloud creation may already have happened. Keep an encrypted copy; it cannot be retried safely.")
                    } else if stored.intent.phase == .confirmed {
                        Text("The cloud file was created. Finish recovery to complete this operation.")
                    } else {
                        Text("This cloud creation has not been sent. You can retry it or export its encrypted copy.")
                    }
                    if actions.export {
                        Button("Export Encrypted Copy") {
                            let id = stored.intent.operationID
                            let name = stored.intent.referenceTemplate.filename
                            perform { (try CloudFileCreationCoordinator.export(operationID: id), name) }
                        }
                        .macPlainRowButton()
                        .accessibilityIdentifier("cloud.recovery.creation.\(stored.intent.operationID.uuidString).export")
                    }
                    if actions.retry {
                        Button("Retry Cloud Creation") { runCreation(stored.intent.operationID, retry: true) }
                            .macPlainRowButton()
                            .accessibilityIdentifier("cloud.recovery.creation.\(stored.intent.operationID.uuidString).retry")
                    }
                    if actions.complete {
                        Button("Finish Cloud Recovery") { runCreation(stored.intent.operationID, retry: false) }
                            .macPlainRowButton()
                            .accessibilityIdentifier("cloud.recovery.creation.\(stored.intent.operationID.uuidString).finish")
                    }
                    if actions.discard {
                        Button("Discard Changes", role: .destructive) { creationToDiscard = stored }
                            .macPlainRowButton()
                            .accessibilityIdentifier("cloud.recovery.creation.\(stored.intent.operationID.uuidString).discard")
                    }
                }
            }
            ForEach(uploads, id: \.id) { stored in
                Section(references[stored.marker.databaseId]?.displayName ?? stored.marker.detachedFilename ?? String(localized: "Cloud")) {
                    if let issue = CloudJournalDecision.driveUploadRecoveryIssue(for: stored.marker) {
                        Text(issue.localizedDescription)
                    }
                    Button("Export Encrypted Copy") {
                        let reference = references[stored.marker.databaseId]
                        perform {
                            let data = try PendingUploadQueue.readImmutablePayload(stored)
                            let name = reference.map { DatabaseExportService.currentCopyFilename(for: $0, date: .now) }
                                ?? stored.marker.detachedFilename ?? "KeeForge copy \(Int(Date().timeIntervalSince1970)).kdbx"
                            return (data, name)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cloud Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task { await reload() }
        .onDisappear { creationLifetime.cancel() }
        .alert("Discard changes?", isPresented: Binding(
            get: { creationToDiscard != nil }, set: { if !$0 { creationToDiscard = nil } }
        ), presenting: creationToDiscard) { stored in
            Button("Discard Changes", role: .destructive) { discardCreation(stored) }
            Button("Cancel", role: .cancel) { creationToDiscard = nil }
        } message: { _ in
            Text("This encrypted copy will be deleted. Export it first if you want to keep it.")
        }
        .fileExporter(isPresented: $exporting, document: document,
            contentType: DocumentPickerService.databaseContentType, defaultFilename: filename) { result in
                if case .failure(let error) = result { failure = error.localizedDescription }
            }
    }

    private func reload() async {
        failure = nil
        do {
            let listing = try await Task.detached {
                try? PendingUploadQueue.cleanCompletedCreationPayloads()
                try? PendingUploadQueue.cleanCompletedConflictCopyAttempts()
                return try PendingUploadQueue.listCreationsForRecovery()
            }.value
            creations = listing.records.filter { $0.intent.phase != .completed }
            if listing.hasUnreadableRecords {
                failure = String(localized: "The cloud recovery record is unavailable or has changed. Keep your encrypted copies and reopen Cloud Recovery.")
            }
        } catch {
            creations = []
            failure = error.localizedDescription
        }
        references = await Task.detached {
            Dictionary(uniqueKeysWithValues: DatabaseListStore.databases.map { ($0.id, $0) })
        }.value
        do {
            let available = references
            uploads = try await Task.detached {
                let records = try PendingUploadQueue.readJournal()
                let legacyIDs = Set(records.filter {
                    $0.marker.journalVersion == nil && $0.marker.binding == nil
                        && $0.marker.isPayloadFinalized == true && $0.marker.intendedPayloadPath == nil
                }.map { $0.marker.databaseId })
                for id in legacyIDs {
                    guard let reference = available[id] else { continue }
                    try PendingUploadQueue.withCommitLock(for: id) {
                        try PendingUploadQueue.preserveLegacyPayloads(for: reference)
                    }
                }
                return try PendingUploadQueue.readJournal()
            }.value
        } catch {
            failure = error.localizedDescription
            uploads = await Task.detached {
                PendingUploadQueue.listMarkers().filter { CloudJournalDecision.state(of: $0.marker) != .invalid }
            }.value
        }
    }

    private func runCreation(_ operationID: UUID, retry: Bool) {
        busy = true
        failure = nil
        let lifetime = creationLifetime
        Task {
            do {
                _ = try await Task.detached {
                    if retry { return try await CloudFileCreationCoordinator.retryPrepared(operationID: operationID, lifetime: lifetime) }
                    try lifetime.claim()
                    return try CloudFileCreationCoordinator.resumeKnownRegistration(operationID: operationID)
                }.value
            } catch { failure = error.localizedDescription }
            busy = false
            let actionFailure = failure
            await reload()
            if let actionFailure { failure = actionFailure }
        }
    }

    private func discardCreation(_ stored: PendingUploadQueue.StoredCreation) {
        creationToDiscard = nil
        busy = true
        failure = nil
        let lifetime = creationLifetime
        Task {
            do {
                try await Task.detached {
                    try lifetime.claim()
                    try PendingUploadQueue.discardPreparedCreation(stored)
                }.value
            } catch { failure = error.localizedDescription }
            busy = false
            let actionFailure = failure
            await reload()
            if let actionFailure { failure = actionFailure }
        }
    }

    private func perform(_ operation: @escaping @Sendable () throws -> (Data, String)) {
        busy = true
        Task {
            do {
                let result = try await Task.detached(operation: operation).value
                document = KDBXExportDocument(data: result.0)
                filename = result.1
                exporting = true
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}
