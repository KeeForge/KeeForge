import AuthenticationServices
import CryptoKit
import Foundation
import SiteMatching

enum AutoFillSaveCoordinator {
    struct SaveOutcome: Sendable {
        let savedRootGroup: KPGroup
        let newSHA512: Data
        let enqueuedPendingUpload: Bool
        var warningScope: SaveEffectScope = .databaseFile
    }

    enum SaveResult: Sendable {
        case saved(SaveOutcome)
        case committedWithoutConfirmedDurability(SaveOutcome)
        case indeterminate(SaveEffectScope)
        case conflict
    }

    struct Environment: Sendable {
        var generatePassword: @Sendable () -> String
        var saveDraft: @Sendable (DatabaseDraft, DatabaseReference, SymmetricKey, Data) async throws -> SaveResult
        /// Publishes the given entries as credential identities owned by the
        /// database with the given `DatabaseReference.id`.
        var populateCredentialStore: @Sendable (UUID, [KPEntry]) -> Void

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
                    kdfPolicy: .autoFillExtension,
                    environment: .autoFillExtension
                )
                switch result {
                case .saved(let newSHA512, _, _):
                    return .saved(
                        SaveOutcome(
                            savedRootGroup: draft.rootGroup,
                            newSHA512: newSHA512,
                            enqueuedPendingUpload: false
                        )
                    )
                case .committedWithoutConfirmedDurability(let newSHA512, _, _, let scope):
                    return .committedWithoutConfirmedDurability(SaveOutcome(
                        savedRootGroup: draft.rootGroup, newSHA512: newSHA512,
                        enqueuedPendingUpload: false, warningScope: scope
                    ))
                case .indeterminate(let scope): return .indeterminate(scope)
                case .conflict:
                    return .conflict
                }
            },
            populateCredentialStore: { databaseID, entries in
                CredentialIdentityStoreManager.populate(with: entries, for: databaseID)
            }
        )
    }

    static func initialDraft(
        for serviceIdentifier: ASCredentialServiceIdentifier,
        username: String?,
        password: String? = nil,
        environment: Environment = .live
    ) -> EntryDraftPayload {
        let request = SiteRequest(serviceIdentifier)
        let suppliedTitle: String
        if case .app = request {
            suppliedTitle = appDisplayName(for: serviceIdentifier)
        } else {
            suppliedTitle = request.host?.name ?? serviceIdentifier.identifier
        }
        // A fill resolves `{REF:…}` in the title when the username is empty,
        // and the requesting app or website chose this value.
        let title = FieldReferenceResolver.containsReference(suppliedTitle) ? "" : suppliedTitle
        return EntryDraftPayload(
            title: title,
            username: username ?? "",
            password: password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? password ?? ""
                : environment.generatePassword(),
            url: request.website?.url ?? "",
            notes: ""
        )
    }

    private static func appDisplayName(for serviceIdentifier: ASCredentialServiceIdentifier) -> String {
        if #available(iOS 26.2, macOS 26.2, *) {
            return serviceIdentifier.displayName ?? ""
        }
        return ""
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
            edit ?? .createEntry(
                parentGroupID: destinationGroup(
                    in: rootGroup,
                    preferredGroupID: reference.autoFillDestinationGroupID
                ).id,
                draft: draftPayload
            )
        )

        let saveResult = try await environment.saveDraft(
            workingDraft, reference, compositeKey, openTimeSHA512
        )

        switch saveResult {
        case .saved(let outcome), .committedWithoutConfirmedDurability(let outcome):
            // Defensive: a database with AutoFill disabled must neither become
            // the active AutoFill database nor publish identities, even if the
            // extension somehow saved into it (slice 03 of the selectable-
            // AutoFill epic makes disabled databases unreachable there).
            let unconfirmed: Bool
            if case .committedWithoutConfirmedDurability = saveResult { unconfirmed = true } else { unconfirmed = false }
            if unconfirmed {
                return .committedWithoutConfirmedDurability(SaveOutcome(
                    savedRootGroup: outcome.savedRootGroup, newSHA512: outcome.newSHA512,
                    enqueuedPendingUpload: reference.isCloudBacked, warningScope: outcome.warningScope
                ))
            }
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
        case .indeterminate(let scope):
            return .indeterminate(scope)
        case .conflict:
            return .conflict
        }
    }

    /// The group new AutoFill entries go into: the configured one while it
    /// still exists outside the recycle bin, otherwise the database's
    /// top-level group. Never the synthetic Root, whose entries other KeePass
    /// apps cannot read.
    static func destinationGroup(in rootGroup: KPGroup, preferredGroupID: UUID?) -> KPGroup {
        let topLevelGroup = rootGroup.groups.first ?? rootGroup
        guard let preferredGroupID else { return topLevelGroup }

        func find(in group: KPGroup) -> KPGroup? {
            guard group.id != rootGroup.recycleBinUUID else { return nil }
            if group.id == preferredGroupID { return group }
            return group.groups.lazy.compactMap(find(in:)).first
        }
        return rootGroup.groups.lazy.compactMap(find(in:)).first ?? topLevelGroup
    }

    static func credentialStoreEntries(from root: KPGroup) -> [KPEntry] {
        let entries = root.autoFillEntries(excludingGroupID: root.recycleBinUUID)
        return entries.filter { !$0.isExpired() }
    }
}
