import AuthenticationServices
import CryptoKit
import Foundation

enum AutoFillSaveCoordinator {
    struct SaveOutcome: Sendable {
        let savedRootGroup: KPGroup
        let newSHA512: Data
        let enqueuedPendingUpload: Bool
    }

    enum SaveResult: Sendable {
        case saved(SaveOutcome)
        case conflict
    }

    struct Environment: Sendable {
        var generatePassword: @Sendable () -> String
        var saveDraft: @Sendable (DatabaseDraft, DatabaseReference, SymmetricKey, Data) async throws -> SaveResult
        var relativePathForURL: @Sendable (URL) throws -> String
        /// Writes the marker durably WITHOUT posting the Darwin drain
        /// notification — the provisional marker precedes its payload, so
        /// waking the drainer here would only race the save.
        var enqueuePendingUpload: @Sendable (PendingUploadQueue.Marker) throws -> PendingUploadQueue.StoredMarker
        /// CAS-updates the provisional marker with the saved payload's SHA-512.
        /// Throws `markerNoLongerExists` if a concurrent drain dropped it.
        var finalizePendingUpload: @Sendable (PendingUploadQueue.StoredMarker) throws -> Void
        /// Best-effort removal of a provisional marker whose save never
        /// rewrote the cache (conflict or thrown error).
        var dropPendingUpload: @Sendable (PendingUploadQueue.StoredMarker) -> Void
        /// Drops markers whose recorded payload SHA-512 equals the given base
        /// SHA — provably superseded by the save being enqueued. The excluded
        /// id is the just-enqueued marker itself.
        var dropSupersededPendingUploads: @Sendable (_ databaseId: UUID, _ payloadSHA512: Data, _ excludedMarkerID: UUID) -> Void
        var notifyPendingUploadEnqueued: @Sendable () -> Void
        var resolveReference: @Sendable (UUID) -> DatabaseReference?
        /// Publishes the given entries as credential identities owned by the
        /// database with the given `DatabaseReference.id`.
        var populateCredentialStore: @Sendable (UUID, [KPEntry]) -> Void
        var now: @Sendable () -> Date

        static let live = Environment(
            generatePassword: {
                PasswordGenerator.generate(options: SettingsService.passwordGeneratorOptions)
            },
            saveDraft: { draft, reference, compositeKey, openTimeSHA512 in
                let result = try await LocalDatabaseSaver.save(
                    draft: draft,
                    reference: reference,
                    compositeKey: compositeKey,
                    openTimeSHA512: openTimeSHA512,
                    kdfPolicy: .autoFillExtension
                )
                switch result {
                case .saved(let newSHA512):
                    return .saved(
                        SaveOutcome(
                            savedRootGroup: draft.rootGroup,
                            newSHA512: newSHA512,
                            enqueuedPendingUpload: false
                        )
                    )
                case .conflict:
                    return .conflict
                }
            },
            relativePathForURL: { url in
                try PendingUploadQueue.makeRelativeAppGroupPath(for: url)
            },
            enqueuePendingUpload: { marker in
                try PendingUploadQueue.enqueue(marker, notifying: false)
            },
            finalizePendingUpload: { storedMarker in
                _ = try PendingUploadQueue.update(storedMarker)
            },
            dropPendingUpload: { storedMarker in
                try? PendingUploadQueue.drop(storedMarker)
            },
            dropSupersededPendingUploads: { databaseId, payloadSHA512, excludedMarkerID in
                PendingUploadQueue.dropMarkers(
                    withPayloadSHA512: payloadSHA512,
                    for: databaseId,
                    excluding: excludedMarkerID
                )
            },
            notifyPendingUploadEnqueued: {
                PendingUploadQueue.postEnqueuedNotification()
            },
            resolveReference: { databaseId in
                DatabaseListStore.databases.first(where: { $0.id == databaseId })
            },
            populateCredentialStore: { databaseID, entries in
                CredentialIdentityStoreManager.populate(with: entries, for: databaseID)
            },
            now: { .now }
        )
    }

    static func initialDraft(
        for serviceIdentifier: ASCredentialServiceIdentifier,
        username: String?,
        password: String? = nil,
        environment: Environment = .live
    ) -> EntryDraftPayload {
        let title = CredentialMatcher.searchTerm(for: serviceIdentifier) ?? serviceIdentifier.identifier
        return EntryDraftPayload(
            title: title,
            username: username ?? "",
            password: password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? password ?? ""
                : environment.generatePassword(),
            url: serviceIdentifier.identifier,
            notes: ""
        )
    }

    static func saveNewEntry(
        draftPayload: EntryDraftPayload,
        reference: DatabaseReference,
        rootGroup: KPGroup,
        meta: KPMeta,
        sessionKey: SymmetricKey,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        environment: Environment = .live,
        edit: EntryEdit? = nil
    ) async throws -> SaveResult {
        let cleanDraft = DatabaseDraft(rootGroup: rootGroup, meta: meta, sessionKey: sessionKey)
        let workingDraft = try cleanDraft.apply(
            edit ?? .createEntry(parentGroupID: rootGroup.groups.first?.id ?? rootGroup.id, draft: draftPayload)
        )

        // Two-phase marker so unuploaded cache bytes always have a covering
        // durable marker. Order is load-bearing:
        //   1. enqueue provisional marker recording the BASE bytes' SHA-512
        //   2. saveDraft: SHA-check, backup, atomic cache replace
        //   3. finalize: CAS marker to the payload SHA, then wake the drainer
        // A crash before the replace leaves cache == marker SHA, so a drain
        // re-pushes identical bytes; after it, the mismatch surfaces as a
        // conflict rather than a silent wrong push.
        var provisionalMarker: PendingUploadQueue.StoredMarker?
        if reference.isCloudBacked {
            let cacheURL = DatabaseListStore.cacheLocation(for: reference)
            let relativePath = try environment.relativePathForURL(cacheURL)
            provisionalMarker = try await Task.detached(priority: .utility) {
                let storedMarker = try environment.enqueuePendingUpload(
                    PendingUploadQueue.Marker(
                        databaseId: reference.id,
                        encryptedBytesCacheURL: relativePath,
                        openTimeSHA512: openTimeSHA512,
                        expectedRev: reference.expectedCloudRevision,
                        createdAt: environment.now(),
                        lastSyncError: nil,
                        baseRev: reference.expectedCloudRevision
                    )
                )
                // An older marker whose payload hashes to this save's base
                // bytes is contained in this save. Dropped only after the new
                // marker is durable, so the cache is never left uncovered.
                environment.dropSupersededPendingUploads(reference.id, openTimeSHA512, storedMarker.id)
                return storedMarker
            }.value
        }

        let saveResult: SaveResult
        do {
            saveResult = try await environment.saveDraft(
                workingDraft,
                reference,
                compositeKey,
                openTimeSHA512
            )
        } catch {
            // The saver replaces the cache atomically as its last fallible
            // step, so a throw means the cache still holds the base bytes;
            // the provisional marker is stale.
            if let provisionalMarker {
                await Task.detached(priority: .utility) {
                    environment.dropPendingUpload(provisionalMarker)
                }.value
            }
            throw error
        }

        switch saveResult {
        case .saved(let outcome):
            if var storedMarker = provisionalMarker {
                storedMarker.marker.openTimeSHA512 = outcome.newSHA512
                await Task.detached(priority: .utility) {
                    finalizeOrReplacePendingUpload(
                        storedMarker,
                        reference: reference,
                        environment: environment
                    )
                }.value
            }

            // Defensive: a database with AutoFill disabled must neither become
            // the active AutoFill database nor publish identities, even if the
            // extension somehow saved into it (slice 03 of the selectable-
            // AutoFill epic makes disabled databases unreachable there).
            if reference.autoFillEnabled {
                DatabaseListStore.activeAutoFillDatabaseID = reference.id
                environment.populateCredentialStore(reference.id, credentialStoreEntries(from: outcome.savedRootGroup))
            }

            return .saved(
                SaveOutcome(
                    savedRootGroup: outcome.savedRootGroup,
                    newSHA512: outcome.newSHA512,
                    enqueuedPendingUpload: reference.isCloudBacked
                )
            )
        case .conflict:
            // The saver's open-time SHA gate refused to touch the cache, so
            // the provisional marker never had a payload to cover.
            if let provisionalMarker {
                await Task.detached(priority: .utility) {
                    environment.dropPendingUpload(provisionalMarker)
                }.value
            }
            return .conflict
        }
    }

    /// Phase 3 of the two-phase marker. A failed CAS means something else
    /// dropped the provisional marker while the saved bytes are still
    /// unuploaded, so a replacement is enqueued unless the database is gone.
    /// The replacement keeps the ORIGINAL `expectedRev` and a nil `baseRev`:
    /// this path cannot prove what the remote head holds, so its push must
    /// CAS-fail into a visible conflict rather than silently overwrite an app
    /// save that completed mid-flight.
    private static func finalizeOrReplacePendingUpload(
        _ storedMarker: PendingUploadQueue.StoredMarker,
        reference: DatabaseReference,
        environment: Environment
    ) {
        do {
            try environment.finalizePendingUpload(storedMarker)
            environment.notifyPendingUploadEnqueued()
        } catch {
            guard let refreshedReference = environment.resolveReference(reference.id),
                  refreshedReference.isCloudBacked else {
                return
            }

            var replacementMarker = storedMarker.marker
            replacementMarker.baseRev = nil
            replacementMarker.lastSyncError = nil
            if (try? environment.enqueuePendingUpload(replacementMarker)) != nil {
                environment.notifyPendingUploadEnqueued()
            }
        }
    }

    static func credentialStoreEntries(from root: KPGroup) -> [KPEntry] {
        let entries = root.autoFillEntries(excludingGroupID: root.recycleBinUUID)
        return entries.filter { !$0.isExpired() }
    }
}
