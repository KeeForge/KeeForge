import CryptoKit
import Foundation

struct DatabaseDraft: Sendable {
    enum DraftError: Error, LocalizedError, Equatable {
        case groupNotFound(UUID)
        case entryNotFound(UUID)
        case duplicateGroupName(parentGroupID: UUID, name: String)
        case protectedGroup(UUID)
        case historyVersionNotFound(entryID: UUID, index: Int)

        var errorDescription: String? {
            switch self {
            case .groupNotFound(let groupID):
                String(localized: "Group not found: \(groupID.uuidString)")
            case .entryNotFound(let entryID):
                String(localized: "Entry not found: \(entryID.uuidString)")
            case .duplicateGroupName(_, let name):
                String(localized: "\"\(name)\" already exists in this group.")
            case .protectedGroup:
                String(localized: "This group cannot be deleted.")
            case .historyVersionNotFound:
                String(localized: "That earlier version is no longer available.")
            }
        }
    }

    private enum RecycleBinUUIDOverride {
        case keep
        case value(UUID?)
    }

    private enum RecycleBinTarget {
        case existing(path: [UUID])
        case create(id: UUID)
    }

    private let originalRootGroupStorage: KPGroup
    private let currentRootGroupStorage: KPGroup
    private let originalMetaStorage: KPMeta
    private let currentMetaStorage: KPMeta
    private let sessionKey: SymmetricKey

    let pendingEdits: [EntryEdit]

    init(rootGroup: KPGroup, meta: KPMeta, sessionKey: SymmetricKey) {
        let originalRootGroupStorage = rootGroup.deepCopy()
        originalRootGroupStorage.recycleBinUUID = meta.recycleBinUUID

        self.originalRootGroupStorage = originalRootGroupStorage
        self.currentRootGroupStorage = originalRootGroupStorage
        self.originalMetaStorage = meta
        self.currentMetaStorage = meta
        self.sessionKey = sessionKey
        self.pendingEdits = []
    }

    private init(
        originalRootGroupStorage: KPGroup,
        currentRootGroupStorage: KPGroup,
        originalMetaStorage: KPMeta,
        currentMetaStorage: KPMeta,
        sessionKey: SymmetricKey,
        pendingEdits: [EntryEdit]
    ) {
        self.originalRootGroupStorage = originalRootGroupStorage
        self.currentRootGroupStorage = currentRootGroupStorage
        self.originalMetaStorage = originalMetaStorage
        self.currentMetaStorage = currentMetaStorage
        self.sessionKey = sessionKey
        self.pendingEdits = pendingEdits
    }

    var rootGroup: KPGroup {
        let rootGroup = currentRootGroupStorage.deepCopy()
        rootGroup.recycleBinUUID = currentMetaStorage.recycleBinUUID
        return rootGroup
    }

    var meta: KPMeta {
        currentMetaStorage
    }

    var writerSessionKey: SymmetricKey {
        sessionKey
    }

    var isDirty: Bool {
        !pendingEdits.isEmpty
    }

    func apply(_ edit: EntryEdit) throws -> DatabaseDraft {
        let updatedState: (rootGroup: KPGroup, meta: KPMeta)

        switch edit {
        case .createEntry(let parentGroupID, let draft):
            updatedState = try applyCreate(parentGroupID: parentGroupID, draft: draft)
        case .createGroup(let parentGroupID, let name):
            updatedState = try applyCreateGroup(parentGroupID: parentGroupID, name: name)
        case .updateEntry(let entryID, let draft):
            updatedState = try applyUpdate(entryID: entryID, draft: draft)
        case .deleteEntry(let entryID, let sendToRecycleBin):
            updatedState = try applyDelete(entryID: entryID, sendToRecycleBin: sendToRecycleBin)
        case .deleteGroup(let groupID, let sendToRecycleBin):
            updatedState = try applyDeleteGroup(groupID: groupID, sendToRecycleBin: sendToRecycleBin)
        case .setGroupSearchingEnabled(let groupID, let value):
            updatedState = try applySetGroupSearchingEnabled(groupID: groupID, value: value.modelValue)
        case .setGroupIcon(let groupID, let iconID):
            updatedState = try applySetGroupIcon(groupID: groupID, iconID: iconID)
        case .restoreEntryVersion(let entryID, let historyIndex):
            updatedState = try applyRestoreEntryVersion(entryID: entryID, historyIndex: historyIndex)
        }

        updatedState.rootGroup.recycleBinUUID = updatedState.meta.recycleBinUUID

        return DatabaseDraft(
            originalRootGroupStorage: originalRootGroupStorage,
            currentRootGroupStorage: updatedState.rootGroup,
            originalMetaStorage: originalMetaStorage,
            currentMetaStorage: updatedState.meta,
            sessionKey: sessionKey,
            pendingEdits: pendingEdits + [edit]
        )
    }

    func discardingEdits() -> DatabaseDraft {
        DatabaseDraft(
            originalRootGroupStorage: originalRootGroupStorage,
            currentRootGroupStorage: originalRootGroupStorage,
            originalMetaStorage: originalMetaStorage,
            currentMetaStorage: originalMetaStorage,
            sessionKey: sessionKey,
            pendingEdits: []
        )
    }

    private func applyCreate(
        parentGroupID: UUID,
        draft: EntryDraftPayload
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let parentGroupPath = pathToGroup(withID: parentGroupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(parentGroupID)
        }

        let timestamp = Date.now
        let newEntry = try makeCreatedEntry(from: draft, timestamp: timestamp)
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: parentGroupPath[...]) { group in
            var updatedEntries = group.entries
            updatedEntries.append(newEntry)
            return copyGroup(group, entries: updatedEntries)
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func applyCreateGroup(
        parentGroupID: UUID,
        name: String
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let parentGroupPath = pathToGroup(withID: parentGroupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(parentGroupID)
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: parentGroupPath[...]) { group in
            if group.groups.contains(where: { $0.name.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                throw DraftError.duplicateGroupName(parentGroupID: parentGroupID, name: trimmedName)
            }

            let timestamp = Date.now
            let newGroup = KPGroup(
                name: trimmedName,
                creationTime: timestamp,
                lastModificationTime: timestamp
            )
            var updatedGroups = group.groups
            updatedGroups.append(newGroup)
            return copyGroup(group, groups: updatedGroups)
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func applySetGroupSearchingEnabled(
        groupID: UUID,
        value: KPInheritableBool
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let groupPath = pathToGroup(withID: groupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(groupID)
        }

        let timestamp = Date.now
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: groupPath[...]) { group in
            // If the source file carried an `<EnableSearching>` whose value we
            // could not parse, the parser left it in `unknownXML`. Now that the
            // element is structured for this group, drop the preserved copy —
            // otherwise the writer emits both and the group ends up with two
            // `<EnableSearching>` children, which other KeePass clients may
            // resolve the other way round.
            var unknownXML = group.unknownXML
            unknownXML.removeDirectChildren(named: "EnableSearching")

            return KPGroup(
                id: group.id,
                name: group.name,
                iconID: group.iconID,
                customIconUUID: group.customIconUUID,
                tags: group.tags,
                hasTagsElement: group.hasTagsElement,
                entries: group.entries,
                groups: group.groups,
                isExpanded: group.isExpanded,
                searchingEnabled: value,
                creationTime: group.creationTime,
                lastModificationTime: timestamp,
                recycleBinUUID: group.recycleBinUUID,
                unknownXML: unknownXML
            )
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func applySetGroupIcon(
        groupID: UUID,
        iconID: Int
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let groupPath = pathToGroup(withID: groupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(groupID)
        }

        let timestamp = Date.now
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: groupPath[...]) { group in
            // A `<CustomIconUUID>` outranks `<IconID>` in KeePass, so the preserved element
            // has to go with the display copy or the chosen icon is never shown.
            var unknownXML = group.unknownXML
            unknownXML.removeDirectChildren(named: "CustomIconUUID")

            return KPGroup(
                id: group.id,
                name: group.name,
                iconID: iconID,
                customIconUUID: nil,
                tags: group.tags,
                hasTagsElement: group.hasTagsElement,
                entries: group.entries,
                groups: group.groups,
                isExpanded: group.isExpanded,
                searchingEnabled: group.searchingEnabled,
                creationTime: group.creationTime,
                lastModificationTime: timestamp,
                recycleBinUUID: group.recycleBinUUID,
                unknownXML: unknownXML
            )
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func applyUpdate(
        entryID: UUID,
        draft: EntryDraftPayload
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            throw DraftError.entryNotFound(entryID)
        }

        let timestamp = Date.now
        let updatedEntry = try makeUpdatedEntry(
            from: draft,
            originalEntry: entryLocation.entry,
            timestamp: timestamp
        )
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: entryLocation.groupPath[...]) { group in
            var updatedEntries = group.entries
            updatedEntries[entryLocation.entryIndex] = updatedEntry
            return copyGroup(group, entries: updatedEntries)
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    /// Makes a stored history version current again.
    ///
    /// The state being replaced is pushed onto the history first, so a restore is
    /// itself reversible and never destroys the version the user was looking at.
    ///
    /// Identity and provenance stay with the live entry rather than coming from the
    /// snapshot: `id` (so references elsewhere keep resolving), `creationTime` (the
    /// entry was created once, restoring is not re-creating it), and `unknownXML`.
    /// That last one matters — the live entry's preserved XML describes the element
    /// layout the writer round-trips today, including where `<History>` sits, so
    /// swapping in an older copy of it would rewrite structure the source app wrote.
    /// Everything the user can see or edit comes from the snapshot.
    /// Whether a restore would keep the state it replaces, i.e. whether it can be undone.
    ///
    /// `HistoryMaxItems`/`HistoryMaxSize` can discard the pushed snapshot, so the
    /// confirmation must not promise an undo without asking first. The snapshot is
    /// prepended and the trim only takes a prefix, so it survives exactly when the result
    /// is non-empty.
    func restoreKeepsReplacedState(entryID: UUID) -> Bool {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            return false
        }
        let current = entryLocation.entry
        return !trimmedHistory(
            appending: current.cloneForHistory(),
            existing: current.history,
            meta: currentMetaStorage
        ).isEmpty
    }

    private func applyRestoreEntryVersion(
        entryID: UUID,
        historyIndex: Int
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            throw DraftError.entryNotFound(entryID)
        }

        let current = entryLocation.entry
        guard current.history.indices.contains(historyIndex) else {
            throw DraftError.historyVersionNotFound(entryID: entryID, index: historyIndex)
        }
        let version = current.history[historyIndex]

        let restored = KPEntry(
            id: current.id,
            title: version.title,
            username: version.username,
            password: version.password,
            url: version.url,
            notes: version.notes,
            iconID: version.iconID,
            customIconUUID: version.customIconUUID,
            tags: version.tags,
            hasTagsElement: version.hasTagsElement,
            customFields: version.customFields,
            passkeyPrivateKey: version.passkeyPrivateKey,
            totpConfig: version.totpConfig,
            otpURL: version.otpURL,
            creationTime: current.creationTime,
            lastModificationTime: Date.now,
            expires: version.expires,
            expiryTime: version.expiryTime,
            history: trimmedHistory(
                appending: current.cloneForHistory(),
                existing: current.history,
                meta: currentMetaStorage
            ),
            unknownXML: current.unknownXML,
            protectedStringKeys: version.protectedStringKeys,
            attachments: version.attachments
        )

        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: entryLocation.groupPath[...]) { group in
            var updatedEntries = group.entries
            updatedEntries[entryLocation.entryIndex] = restored
            return copyGroup(group, entries: updatedEntries)
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func applyDelete(
        entryID: UUID,
        sendToRecycleBin: Bool
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            throw DraftError.entryNotFound(entryID)
        }

        let rootWithoutEntry = try rebuildGroup(in: currentRootGroupStorage, targetPath: entryLocation.groupPath[...]) { group in
            var updatedEntries = group.entries
            updatedEntries.remove(at: entryLocation.entryIndex)
            return copyGroup(group, entries: updatedEntries)
        }

        guard sendToRecycleBin else {
            var updatedMeta = currentMetaStorage
            updatedMeta.deletedObjects.append(
                KPDeletedObject(uuid: entryID, deletionTime: Date.now)
            )
            return (rootWithoutEntry, updatedMeta)
        }

        switch recycleBinTarget(in: rootWithoutEntry, meta: currentMetaStorage) {
        case .existing(let recycleBinPath):
            let updatedRootGroup = try rebuildGroup(in: rootWithoutEntry, targetPath: recycleBinPath[...]) { group in
                var updatedEntries = group.entries
                updatedEntries.append(entryLocation.entry)
                return copyGroup(group, entries: updatedEntries)
            }
            return (updatedRootGroup, currentMetaStorage)

        case .create(let recycleBinID):
            let recycleBinGroup = makeRecycleBinGroup(id: recycleBinID, entry: entryLocation.entry)
            let recycleBinParent = rootWithoutEntry.groups.first ?? rootWithoutEntry
            let recycleBinParentPath: [UUID] = recycleBinParent.id == rootWithoutEntry.id
                ? [rootWithoutEntry.id]
                : [rootWithoutEntry.id, recycleBinParent.id]

            let rootWithRecycleBin = try rebuildGroup(
                in: rootWithoutEntry,
                targetPath: recycleBinParentPath[...]
            ) { group in
                var updatedGroups = group.groups
                updatedGroups.append(recycleBinGroup)
                return copyGroup(group, groups: updatedGroups)
            }

            let updatedRootGroup = copyGroup(
                rootWithRecycleBin,
                recycleBinUUIDOverride: .value(recycleBinID)
            )
            var updatedMeta = currentMetaStorage
            updatedMeta.recycleBinUUID = recycleBinID
            updatedMeta.hasRecycleBinUUIDElement = true
            return (updatedRootGroup, updatedMeta)
        }
    }

    private func applyDeleteGroup(
        groupID: UUID,
        sendToRecycleBin: Bool
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard isProtectedGroupForDeletion(groupID, in: currentRootGroupStorage, meta: currentMetaStorage) == false else {
            throw DraftError.protectedGroup(groupID)
        }

        guard let groupLocation = findGroupLocation(groupID: groupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(groupID)
        }

        let rootWithoutGroup = try rebuildGroup(
            in: currentRootGroupStorage,
            targetPath: groupLocation.parentPath[...]
        ) { parentGroup in
            var updatedGroups = parentGroup.groups
            updatedGroups.remove(at: groupLocation.groupIndex)
            return copyGroup(parentGroup, groups: updatedGroups)
        }

        guard sendToRecycleBin else {
            var updatedMeta = currentMetaStorage
            updatedMeta.deletedObjects.append(
                contentsOf: deletedObjects(for: groupLocation.group, deletionTime: Date.now)
            )
            return (rootWithoutGroup, updatedMeta)
        }

        switch recycleBinTarget(in: rootWithoutGroup, meta: currentMetaStorage) {
        case .existing(let recycleBinPath):
            let updatedRootGroup = try rebuildGroup(in: rootWithoutGroup, targetPath: recycleBinPath[...]) { group in
                var updatedGroups = group.groups
                updatedGroups.append(groupLocation.group)
                return copyGroup(group, groups: updatedGroups)
            }
            return (updatedRootGroup, currentMetaStorage)

        case .create(let recycleBinID):
            let recycleBinGroup = makeRecycleBinGroup(id: recycleBinID, group: groupLocation.group)
            let recycleBinParent = rootWithoutGroup.groups.first ?? rootWithoutGroup
            let recycleBinParentPath: [UUID] = recycleBinParent.id == rootWithoutGroup.id
                ? [rootWithoutGroup.id]
                : [rootWithoutGroup.id, recycleBinParent.id]

            let rootWithRecycleBin = try rebuildGroup(
                in: rootWithoutGroup,
                targetPath: recycleBinParentPath[...]
            ) { group in
                var updatedGroups = group.groups
                updatedGroups.append(recycleBinGroup)
                return copyGroup(group, groups: updatedGroups)
            }

            let updatedRootGroup = copyGroup(
                rootWithRecycleBin,
                recycleBinUUIDOverride: .value(recycleBinID)
            )
            var updatedMeta = currentMetaStorage
            updatedMeta.recycleBinUUID = recycleBinID
            updatedMeta.hasRecycleBinUUIDElement = true
            return (updatedRootGroup, updatedMeta)
        }
    }

    private func makeCreatedEntry(
        from draft: EntryDraftPayload,
        timestamp: Date
    ) throws -> KPEntry {
        KPEntry(
            title: draft.title,
            username: draft.username,
            password: try EncryptedValue.encrypt(draft.password, using: sessionKey),
            url: draft.url,
            notes: draft.notes,
            tags: draft.tags,
            hasTagsElement: !draft.tags.isEmpty,
            customFields: activeCustomFields(from: draft),
            passkeyPrivateKey: try draftPasskeyPrivateKey(from: draft, fallback: nil),
            totpConfig: try makeTOTPConfig(from: draft.totpConfig),
            otpURL: draft.totpConfig?.keeOTPSource?.fieldName == "otp"
                ? draft.totpConfig?.keeOTPSource?.rawQuery
                : nil,
            creationTime: timestamp,
            lastModificationTime: timestamp
        )
    }

    private func makeUpdatedEntry(
        from draft: EntryDraftPayload,
        originalEntry: KPEntry,
        timestamp: Date
    ) throws -> KPEntry {
        let history = trimmedHistory(
            appending: originalEntry.cloneForHistory(),
            existing: originalEntry.history,
            meta: currentMetaStorage
        )

        return KPEntry(
            id: originalEntry.id,
            title: draft.title,
            username: draft.username,
            password: try EncryptedValue.encrypt(draft.password, using: sessionKey),
            url: draft.url,
            notes: draft.notes,
            iconID: originalEntry.iconID,
            tags: draft.tags,
            hasTagsElement: originalEntry.hasTagsElement || !draft.tags.isEmpty,
            customFields: activeCustomFields(from: draft),
            passkeyPrivateKey: try draftPasskeyPrivateKey(
                from: draft,
                fallback: originalEntry.passkeyPrivateKey
            ),
            totpConfig: try makeTOTPConfig(from: draft.totpConfig),
            otpURL: updatedOtpURL(draft: draft, originalEntry: originalEntry),
            creationTime: originalEntry.creationTime,
            lastModificationTime: timestamp,
            expires: originalEntry.expires,
            expiryTime: originalEntry.expiryTime,
            history: history,
            unknownXML: originalEntry.unknownXML,
            protectedStringKeys: preservedProtectedStringKeys(
                from: originalEntry,
                customFields: draft.customFields
            ),
            attachments: originalEntry.attachments
        )
    }

    private func updatedOtpURL(
        draft: EntryDraftPayload,
        originalEntry: KPEntry
    ) -> String? {
        guard let source = draft.totpConfig?.keeOTPSource else {
            return preservedOtpURL(draft: draft, originalEntry: originalEntry)
        }
        // A KeeOTP source in a custom-named field never owns the otp slot;
        // whatever the entry stored there must survive verbatim.
        return source.fieldName == "otp" ? source.rawQuery : originalEntry.otpURL
    }

    private func preservedOtpURL(
        draft: EntryDraftPayload,
        originalEntry: KPEntry
    ) -> String? {
        guard let url = originalEntry.otpURL,
              let draftConfig = draft.totpConfig,
              let originalConfig = originalEntry.totpConfig,
              let originalSecret = try? originalConfig.secret.decrypt(using: sessionKey)
        else {
            return nil
        }
        guard draftConfig.secret == originalSecret,
              draftConfig.period == originalConfig.period,
              draftConfig.digits == originalConfig.digits,
              draftConfig.algorithm == originalConfig.algorithm
        else {
            return nil
        }
        return url
    }

    private func makeTOTPConfig(
        from draft: EntryDraftPayload.TOTPConfiguration?
    ) throws -> TOTPConfig? {
        guard let draft, !draft.secret.isEmpty else {
            return nil
        }

        return TOTPConfig(
            secret: try EncryptedValue.encrypt(draft.secret, using: sessionKey),
            decodedSecret: try draft.decodedSecret.map { try EncryptedValue.encrypt($0, using: sessionKey) },
            keeOTPSource: draft.keeOTPSource,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm
        )
    }

    private func activeCustomFields(from draft: EntryDraftPayload) -> [String: String] {
        let activeSourceField = draft.totpConfig?.keeOTPSource?.fieldName
        let fields = draft.customFields.filter {
            $0.key != activeSourceField && !$0.key.hasPrefix("TimeOtp-")
                && $0.key != "TOTP Settings" && $0.key != "TOTP Seed"
                && $0.key != PasskeyCredential.privateKeyPEMKey
        }
        return fields
    }

    /// The passkey private key is stored session-key sealed outside
    /// customFields. A draft normally carries no PEM custom field (the edit
    /// form never exposes it), so the original sealed key is inherited; a PEM
    /// supplied through a hand-added custom field (paste-import) is sealed
    /// here instead of passing through as plaintext.
    private func draftPasskeyPrivateKey(
        from draft: EntryDraftPayload,
        fallback: EncryptedValue?
    ) throws -> EncryptedValue? {
        guard let pem = draft.customFields[PasskeyCredential.privateKeyPEMKey] else {
            return fallback
        }
        return try EncryptedValue.encrypt(pem, using: sessionKey)
    }

    private func preservedProtectedStringKeys(
        from entry: KPEntry,
        customFields: [String: String]
    ) -> Set<String> {
        // OTP source fields and the diverted passkey private key are
        // serialized outside customFields, so their protection flags must
        // survive edits alongside the editable keys.
        let editableKeys = Set(customFields.keys)
            .union(["Title", "UserName", "URL", "Notes", "otp", "OTP", "Otp"])
            .union([PasskeyCredential.privateKeyPEMKey])
        return entry.protectedStringKeys.intersection(editableKeys)
    }

    private func trimmedHistory(
        appending snapshot: KPEntry,
        existing: [KPEntry],
        meta: KPMeta
    ) -> [KPEntry] {
        let history = ([snapshot] + existing).map { $0.cloneForHistory() }

        // Which versions survive is decided by recency; the survivors keep their
        // storage order. Deciding by position instead would discard the newest
        // versions of a KeePass-authored file, whose `<History>` is oldest-first
        // where this app prepends, and reordering the array would rewrite a
        // foreign file's bytes on every save.
        var survivors = Set(history.indices)

        let maxItems = meta.resolvedHistoryMaxItems
        if maxItems >= 0, history.count > maxItems {
            survivors = Set(recencyOrderedIndices(of: history).prefix(maxItems))
        }

        let maxSize = meta.resolvedHistoryMaxSize
        if maxSize >= 0 {
            var retained: Set<Int> = []
            var sizeSoFar: Int64 = 0

            for index in recencyOrderedIndices(of: history) where survivors.contains(index) {
                let entrySize = estimatedHistorySize(for: history[index])
                if sizeSoFar + entrySize > maxSize {
                    break
                }
                retained.insert(index)
                sizeSoFar += entrySize
            }

            survivors = retained
        }

        return history.indices.filter { survivors.contains($0) }.map { history[$0] }
    }

    /// Storage indices newest first, matching `DatabaseViewModel.history(forEntryID:)`:
    /// versions without a timestamp sort last, and ties fall back to storage order so
    /// second-resolution KDBX timestamps still give a total order.
    private func recencyOrderedIndices(of history: [KPEntry]) -> [Int] {
        history.indices.sorted { lhs, rhs in
            switch (history[lhs].lastModificationTime, history[rhs].lastModificationTime) {
            case let (left?, right?): return left == right ? lhs < rhs : left > right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs < rhs
            }
        }
    }

    private func estimatedHistorySize(for entry: KPEntry) -> Int64 {
        var size = Int64(256)
        size += Int64(entry.title.utf8.count)
        size += Int64(entry.username.utf8.count)
        size += Int64(entry.url.utf8.count)
        size += Int64(entry.notes.utf8.count)
        size += Int64(entry.tags.joined(separator: ",").utf8.count)
        size += Int64(entry.otpURL?.utf8.count ?? 0)

        if let password = try? entry.password.decrypt(using: sessionKey) {
            size += Int64(password.utf8.count)
        } else {
            size += Int64(entry.password.sealedData.count)
        }

        for (key, value) in entry.customFields {
            size += Int64(key.utf8.count + value.utf8.count)
        }

        if let passkeyPrivateKey = entry.passkeyPrivateKey {
            // Sealed size approximates the PEM length without decrypting.
            size += Int64(passkeyPrivateKey.sealedData.count)
        }

        if let totpConfig = entry.totpConfig {
            if let secret = try? totpConfig.secret.decrypt(using: sessionKey) {
                size += Int64(secret.utf8.count)
            } else {
                size += Int64(totpConfig.secret.sealedData.count)
            }
            size += Int64(String(totpConfig.period).utf8.count)
            size += Int64(String(totpConfig.digits).utf8.count)
            size += Int64(totpConfig.algorithm.rawValue.utf8.count)
        }

        for node in entry.unknownXML.nodes {
            size += Int64(node.xml.utf8.count)
            size += Int64(node.path.joined(separator: "/").utf8.count)
        }

        for key in entry.protectedStringKeys {
            size += Int64(key.utf8.count)
        }

        return size
    }

    private func recycleBinTarget(in rootGroup: KPGroup, meta: KPMeta) -> RecycleBinTarget {
        if let recycleBinID = meta.recycleBinUUID ?? rootGroup.recycleBinUUID {
            if let recycleBinPath = pathToGroup(withID: recycleBinID, in: rootGroup) {
                return .existing(path: recycleBinPath)
            }
            return .create(id: recycleBinID)
        }

        return .create(id: UUID())
    }

    /// Group name written into the database when a recycle bin is created.
    /// Localized to the UI language, matching KeePass 2.x, KeePassXC,
    /// KeePassium, and Strongbox; clients locate the bin via
    /// Meta/RecycleBinUUID, so the name itself is cosmetic.
    static var localizedRecycleBinName: String {
        String(localized: "Recycle Bin")
    }

    private func makeRecycleBinGroup(id: UUID, entry: KPEntry) -> KPGroup {
        let timestamp = Date.now
        return KPGroup(
            id: id,
            name: Self.localizedRecycleBinName,
            iconID: 43,
            entries: [entry],
            creationTime: timestamp,
            lastModificationTime: timestamp
        )
    }

    private func makeRecycleBinGroup(id: UUID, group: KPGroup) -> KPGroup {
        let timestamp = Date.now
        return KPGroup(
            id: id,
            name: Self.localizedRecycleBinName,
            iconID: 43,
            groups: [group],
            creationTime: timestamp,
            lastModificationTime: timestamp
        )
    }

    private func isProtectedGroupForDeletion(
        _ groupID: UUID,
        in rootGroup: KPGroup,
        meta: KPMeta
    ) -> Bool {
        if groupID == rootGroup.id || groupID == visibleRootGroupID(in: rootGroup) {
            return true
        }

        guard let recycleBinID = meta.recycleBinUUID ?? rootGroup.recycleBinUUID else {
            return false
        }

        if groupID == recycleBinID {
            return true
        }

        guard let group = findGroup(withID: groupID, in: rootGroup) else {
            return false
        }

        return containsGroup(withID: recycleBinID, in: group)
    }

    private func visibleRootGroupID(in rootGroup: KPGroup) -> UUID {
        if rootGroup.entries.isEmpty, rootGroup.groups.count == 1 {
            return rootGroup.groups[0].id
        }
        return rootGroup.id
    }

    private func pathToGroup(withID targetGroupID: UUID, in group: KPGroup) -> [UUID]? {
        if group.id == targetGroupID {
            return [group.id]
        }

        for childGroup in group.groups {
            if let childPath = pathToGroup(withID: targetGroupID, in: childGroup) {
                return [group.id] + childPath
            }
        }

        return nil
    }

    private func findEntryLocation(
        entryID: UUID,
        in group: KPGroup
    ) -> (groupPath: [UUID], entryIndex: Int, entry: KPEntry)? {
        if let entryIndex = group.entries.firstIndex(where: { $0.id == entryID }) {
            return ([group.id], entryIndex, group.entries[entryIndex])
        }

        for childGroup in group.groups {
            if let childLocation = findEntryLocation(entryID: entryID, in: childGroup) {
                return ([group.id] + childLocation.groupPath, childLocation.entryIndex, childLocation.entry)
            }
        }

        return nil
    }

    private func findGroup(
        withID groupID: UUID,
        in group: KPGroup
    ) -> KPGroup? {
        if group.id == groupID {
            return group
        }

        for childGroup in group.groups {
            if let match = findGroup(withID: groupID, in: childGroup) {
                return match
            }
        }

        return nil
    }

    private func findGroupLocation(
        groupID: UUID,
        in group: KPGroup
    ) -> (parentPath: [UUID], groupIndex: Int, group: KPGroup)? {
        if let groupIndex = group.groups.firstIndex(where: { $0.id == groupID }) {
            return ([group.id], groupIndex, group.groups[groupIndex])
        }

        for childGroup in group.groups {
            if let childLocation = findGroupLocation(groupID: groupID, in: childGroup) {
                return ([group.id] + childLocation.parentPath, childLocation.groupIndex, childLocation.group)
            }
        }

        return nil
    }

    private func containsGroup(withID groupID: UUID, in group: KPGroup) -> Bool {
        group.id == groupID || group.groups.contains { containsGroup(withID: groupID, in: $0) }
    }

    private func deletedObjects(for group: KPGroup, deletionTime: Date) -> [KPDeletedObject] {
        var objects = [KPDeletedObject(uuid: group.id, deletionTime: deletionTime)]
        objects.append(contentsOf: group.entries.map { KPDeletedObject(uuid: $0.id, deletionTime: deletionTime) })
        for childGroup in group.groups {
            objects.append(contentsOf: deletedObjects(for: childGroup, deletionTime: deletionTime))
        }
        return objects
    }

    private func rebuildGroup(
        in currentGroup: KPGroup,
        targetPath: ArraySlice<UUID>,
        update: (KPGroup) throws -> KPGroup
    ) throws -> KPGroup {
        let targetGroupID = targetPath.last ?? currentGroup.id

        guard let currentGroupID = targetPath.first, currentGroupID == currentGroup.id else {
            throw DraftError.groupNotFound(targetGroupID)
        }

        guard targetPath.count > 1 else {
            return try update(currentGroup)
        }

        let childPath = targetPath.dropFirst()
        guard let childGroupID = childPath.first,
              let childGroup = currentGroup.groups.first(where: { $0.id == childGroupID }) else {
            throw DraftError.groupNotFound(targetGroupID)
        }

        let updatedChildGroup = try rebuildGroup(
            in: childGroup,
            targetPath: childPath,
            update: update
        )

        guard let updatedCurrentGroup = currentGroup.replacingChildGroup(updatedChildGroup) else {
            throw DraftError.groupNotFound(targetGroupID)
        }

        return updatedCurrentGroup
    }

    private func copyGroup(
        _ group: KPGroup,
        entries: [KPEntry]? = nil,
        groups: [KPGroup]? = nil,
        recycleBinUUIDOverride: RecycleBinUUIDOverride = .keep
    ) -> KPGroup {
        let recycleBinUUID: UUID?
        switch recycleBinUUIDOverride {
        case .keep:
            recycleBinUUID = group.recycleBinUUID
        case .value(let value):
            recycleBinUUID = value
        }

        return KPGroup(
            id: group.id,
            name: group.name,
            iconID: group.iconID,
            customIconUUID: group.customIconUUID,
            tags: group.tags,
            hasTagsElement: group.hasTagsElement,
            entries: entries ?? group.entries,
            groups: groups ?? group.groups,
            isExpanded: group.isExpanded,
            searchingEnabled: group.searchingEnabled,
            creationTime: group.creationTime,
            lastModificationTime: group.lastModificationTime,
            recycleBinUUID: recycleBinUUID,
            unknownXML: group.unknownXML
        )
    }
}

private extension KPGroup {
    func deepCopy() -> KPGroup {
        KPGroup(
            id: id,
            name: name,
            iconID: iconID,
            customIconUUID: customIconUUID,
            tags: tags,
            hasTagsElement: hasTagsElement,
            entries: entries,
            groups: groups.map { $0.deepCopy() },
            isExpanded: isExpanded,
            searchingEnabled: searchingEnabled,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            recycleBinUUID: recycleBinUUID,
            unknownXML: unknownXML
        )
    }
}
