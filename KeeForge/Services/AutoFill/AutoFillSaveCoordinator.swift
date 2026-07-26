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
        var saveDraft: @Sendable (DatabaseDraft, DatabaseReference, Data, Data) async throws -> SaveResult
        var relativePathForURL: @Sendable (URL) throws -> String
        /// Writes the marker durably WITHOUT posting the Darwin drain
        /// notification: a provisional marker is enqueued before its payload
        /// exists in the cache, so waking the main-app drainer at that point
        /// would only race the save. `notifyPendingUploadEnqueued` fires once
        /// the payload is in place.
        var enqueuePendingUpload: @Sendable (PendingUploadQueue.Marker) throws -> PendingUploadQueue.StoredMarker
        /// CAS-updates the provisional marker with the saved payload's SHA-512.
        /// Throws `PendingUploadQueue.UpdateError.markerNoLongerExists` when a
        /// concurrent drain already completed (and dropped) the provisional
        /// marker.
        var finalizePendingUpload: @Sendable (PendingUploadQueue.StoredMarker) throws -> Void
        /// Best-effort removal of a provisional marker whose save never
        /// rewrote the cache (conflict or thrown error).
        var dropPendingUpload: @Sendable (PendingUploadQueue.StoredMarker) -> Void
        /// Drops markers for the database whose recorded payload SHA-512
        /// equals the given base SHA — provably superseded by the save being
        /// enqueued (M3). The excluded id is the just-enqueued marker itself.
        var dropSupersededPendingUploads: @Sendable (_ databaseId: UUID, _ payloadSHA512: Data, _ excludedMarkerID: UUID) -> Void
        var notifyPendingUploadEnqueued: @Sendable () -> Void
        var resolveReference: @Sendable (UUID) -> DatabaseReference?
        /// Publishes the given entries as credential identities owned by the
        /// database with the given `DatabaseReference.id`.
        var populateCredentialStore: @Sendable (UUID, [KPEntry]) -> Void
        var now: @Sendable () -> Date

        static let live = Environment(
            generatePassword: {
                PasswordGenerator.generate()
            },
            saveDraft: { draft, reference, compositeKey, openTimeSHA512 in
                let result = try await LocalDatabaseSaver.save(
                    draft: draft,
                    reference: reference,
                    compositeKey: compositeKey,
                    openTimeSHA512: openTimeSHA512
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
        compositeKey: Data,
        openTimeSHA512: Data,
        environment: Environment = .live
    ) async throws -> SaveResult {
        let cleanDraft = DatabaseDraft(rootGroup: rootGroup, meta: meta, sessionKey: sessionKey)
        let parentGroupID = rootGroup.groups.first?.id ?? rootGroup.id
        let workingDraft = try cleanDraft.apply(
            .createEntry(parentGroupID: parentGroupID, draft: draftPayload)
        )

        // Cloud-backed saves use a two-phase marker so that, at every instant,
        // bytes in the shared cache that have not reached the cloud are covered
        // by a durable marker (the marker's presence is what gates the
        // pre-overwrite backup in every sync-down/cache-refresh path):
        //
        //   1. enqueue provisional marker recording the BASE bytes' SHA-512
        //      (fsync'd temp+rename — durable before step 2 starts)
        //   2. saveDraft: SHA-check, backup, atomically replace cache with the
        //      new payload
        //   3. finalize: CAS-update the marker to the payload's SHA-512, then
        //      post the Darwin drain notification
        //
        // Crash-at-every-step: after 1 the cache still holds the base bytes,
        // which match the marker's recorded SHA — a drain re-pushes content
        // byte-identical to what this device already derived from (harmless),
        // then drops the marker. A crash inside 2 leaves either the base bytes
        // (same as above; saveDraft's replacement is atomic) or the new
        // payload; in the latter case, and between 2 and 3, the marker's
        // recorded SHA mismatches the cache, which every consumer treats as a
        // visible conflict — never a silent push of wrong bytes, and the
        // marker's presence still forces a backup before any overwrite. If the
        // save returns .conflict or throws, the cache was never rewritten and
        // the stale provisional marker is dropped (a crash before that drop
        // degrades to the harmless re-push above).
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
                // M3: an older marker whose recorded payload hashes to this
                // save's base bytes is provably contained in this save — drop
                // it (after the new marker is durable, so the cache's
                // unuploaded bytes are never uncovered).
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

    /// Completes phase 3 of the two-phase pending-upload marker (see the
    /// ordering comment in `saveNewEntry`). When the CAS update reports the
    /// provisional marker gone, a concurrent drain in the main app already
    /// pushed the base payload and dropped the file — or the database was
    /// removed. Removal ends the story; otherwise the just-saved bytes are
    /// still unuploaded, so a fresh marker is enqueued for them. The refreshed
    /// reference supplies the store's current revision as the push CAS, while
    /// `baseRev` stays `nil`: this path cannot prove what content the remote
    /// head holds, and a nil base rev makes the drainer surface any conflict
    /// instead of ever auto-rebasing.
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
            replacementMarker.expectedRev = refreshedReference.expectedCloudRevision
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
