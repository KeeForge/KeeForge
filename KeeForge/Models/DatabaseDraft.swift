import CryptoKit
import Foundation

struct DatabaseDraft: Sendable {
    enum DraftError: Error, LocalizedError, Equatable {
        case groupNotFound(UUID)
        case entryNotFound(UUID)
        case duplicateGroupName(parentGroupID: UUID, name: String)
        case protectedGroup(UUID)

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
            totpConfig: try makeTOTPConfig(from: draft.totpConfig),
            otpURL: draft.totpConfig?.keeOTPSource?.fieldName == "otp"
                ? draft.totpConfig?.keeOTPSource?.rawQuery
                : nil,
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
        }
        return fields
    }

    private func preservedProtectedStringKeys(
        from entry: KPEntry,
        customFields: [String: String]
    ) -> Set<String> {
        let editableKeys = Set(customFields.keys).union(["Title", "UserName", "URL", "Notes"])
        return entry.protectedStringKeys.intersection(editableKeys)
    }

    private func trimmedHistory(
        appending snapshot: KPEntry,
        existing: [KPEntry],
        meta: KPMeta
    ) -> [KPEntry] {
        var history = ([snapshot] + existing).map { $0.cloneForHistory() }

        let maxItems = meta.resolvedHistoryMaxItems
        if maxItems >= 0, history.count > maxItems {
            history = Array(history.prefix(maxItems))
        }

        let maxSize = meta.resolvedHistoryMaxSize
        if maxSize >= 0 {
            var retained: [KPEntry] = []
            var sizeSoFar: Int64 = 0

            for historyEntry in history {
                let entrySize = estimatedHistorySize(for: historyEntry)
                if sizeSoFar + entrySize > maxSize {
                    break
                }
                retained.append(historyEntry)
                sizeSoFar += entrySize
            }

            history = retained
        }

        return history
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
            entries: entries ?? group.entries,
            groups: groups ?? group.groups,
            isExpanded: group.isExpanded,
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
            entries: entries,
            groups: groups.map { $0.deepCopy() },
            isExpanded: isExpanded,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            recycleBinUUID: recycleBinUUID,
            unknownXML: unknownXML
        )
    }
}
