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
        var enqueuePendingUpload: @Sendable (PendingUploadQueue.Marker) throws -> Void
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
                _ = try PendingUploadQueue.enqueue(marker)
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

        let saveResult = try await environment.saveDraft(
            workingDraft,
            reference,
            compositeKey,
            openTimeSHA512
        )

        switch saveResult {
        case .saved(let outcome):
            if reference.isCloudBacked {
                let cacheURL = DatabaseListStore.cacheLocation(for: reference)
                let relativePath = try environment.relativePathForURL(cacheURL)
                try await Task.detached(priority: .utility) {
                    try environment.enqueuePendingUpload(
                        PendingUploadQueue.Marker(
                            databaseId: reference.id,
                            encryptedBytesCacheURL: relativePath,
                            openTimeSHA512: outcome.newSHA512,
                            expectedRev: reference.expectedCloudRevision,
                            createdAt: environment.now(),
                            lastSyncError: nil
                        )
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
            return .conflict
        }
    }

    static func credentialStoreEntries(from root: KPGroup) -> [KPEntry] {
        let entries = root.autoFillEntries(excludingGroupID: root.recycleBinUUID)
        return entries.filter { !$0.isExpired() }
    }
}
