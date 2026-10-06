import CryptoKit
import Foundation

struct DatabaseDraft: Sendable {
    enum DraftError: Error, LocalizedError, Equatable {
        case groupNotFound(UUID)
        case entryNotFound(UUID)
        case duplicateGroupName(parentGroupID: UUID, name: String)
        case emptyGroupName(UUID)
        case protectedGroup(UUID)
        case historyVersionNotFound(entryID: UUID, index: Int)
        case customIconNotStorable
        case moveDestinationInsideMovedGroup(groupID: UUID, destinationGroupID: UUID)
        case attachmentNotFound(name: String)
        case attachmentPoolUnavailable
        case attachmentWouldClaimMissingReference
        case attachmentsTooLarge

        var errorDescription: String? {
            switch self {
            case .groupNotFound(let groupID):
                String(localized: "Group not found: \(groupID.uuidString)")
            case .entryNotFound(let entryID):
                String(localized: "Entry not found: \(entryID.uuidString)")
            case .duplicateGroupName(_, let name):
                String(localized: "\"\(name)\" already exists in this group.")
            case .emptyGroupName:
                String(localized: "Group name cannot be empty.")
            case .protectedGroup:
                String(localized: "This group cannot be deleted.")
            case .historyVersionNotFound:
                String(localized: "That earlier version is no longer available.")
            case .customIconNotStorable:
                String(localized: "This database's icons are stored in a form KeeForge cannot add to without risking the ones already there.")
            case .moveDestinationInsideMovedGroup:
                String(localized: "A group cannot be moved into itself or one of its subgroups.")
            case .attachmentNotFound(let name):
                String(localized: "The attachment \"\(name)\" is no longer part of this entry.")
            case .attachmentPoolUnavailable:
                String(localized: "Attachments can't be added here.")
            case .attachmentWouldClaimMissingReference:
                String(localized: "This database has attachments whose data is missing. A new file would take their place, so it can't be added.")
            case .attachmentsTooLarge:
                String(localized: "This file would make the attachments too large for KeeForge to open the database again.")
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
    private let originalBinaryPoolFields: [Data]?
    private let currentBinaryPoolFields: [Data]?
    private let sessionKey: SymmetricKey

    let pendingEdits: [EntryEdit]

    /// `binaryPoolFields` is the inner-header binary pool `rootGroup`'s
    /// attachment refs point into, verbatim (`KDBXParser.Header.innerHeaderBinaryFields`).
    /// `nil` leaves the pool to the file being replaced, which is only correct
    /// while no edit adds an attachment, so such edits then throw
    /// `attachmentPoolUnavailable`.
    init(rootGroup: KPGroup, meta: KPMeta, sessionKey: SymmetricKey, binaryPoolFields: [Data]? = nil) {
        let originalRootGroupStorage = rootGroup.deepCopy()
        originalRootGroupStorage.recycleBinUUID = meta.recycleBinUUID

        self.originalRootGroupStorage = originalRootGroupStorage
        self.currentRootGroupStorage = originalRootGroupStorage
        self.originalMetaStorage = meta
        self.currentMetaStorage = meta
        self.originalBinaryPoolFields = binaryPoolFields
        self.currentBinaryPoolFields = binaryPoolFields
        self.sessionKey = sessionKey
        self.pendingEdits = []
    }

    private init(
        originalRootGroupStorage: KPGroup,
        currentRootGroupStorage: KPGroup,
        originalMetaStorage: KPMeta,
        currentMetaStorage: KPMeta,
        originalBinaryPoolFields: [Data]?,
        currentBinaryPoolFields: [Data]?,
        sessionKey: SymmetricKey,
        pendingEdits: [EntryEdit]
    ) {
        self.originalRootGroupStorage = originalRootGroupStorage
        self.currentRootGroupStorage = currentRootGroupStorage
        self.originalMetaStorage = originalMetaStorage
        self.currentMetaStorage = currentMetaStorage
        self.originalBinaryPoolFields = originalBinaryPoolFields
        self.currentBinaryPoolFields = currentBinaryPoolFields
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

    /// The binary pool the draft's attachment refs point into, or `nil` when
    /// the draft was built without one.
    var binaryPoolFields: [Data]? {
        currentBinaryPoolFields
    }

    var writerSessionKey: SymmetricKey {
        sessionKey
    }

    var isDirty: Bool {
        !pendingEdits.isEmpty
    }

    /// Encrypts the draft over `header`, writing the draft's binary pool in
    /// place of the one `header` was read with when the draft carries one.
    func write(
        compositeKey: SymmetricKey,
        header: KDBXParser.Header,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Data {
        var header = header
        if let currentBinaryPoolFields {
            header.innerHeaderBinaryFields = currentBinaryPoolFields
        }
        return try KDBXWriter.write(
            rootGroup: rootGroup,
            meta: meta,
            compositeKey: compositeKey,
            header: header,
            sessionKey: sessionKey,
            kdfPolicy: kdfPolicy
        )
    }

    func apply(_ edit: EntryEdit) throws -> DatabaseDraft {
        let updatedState: (rootGroup: KPGroup, meta: KPMeta)
        var binaryPoolFields = currentBinaryPoolFields

        switch edit {
        case .createEntry(let parentGroupID, let draft):
            updatedState = try applyCreate(
                parentGroupID: parentGroupID,
                draft: draft,
                binaryPoolFields: &binaryPoolFields
            )
        case .createGroup(let parentGroupID, let name):
            updatedState = try applyCreateGroup(parentGroupID: parentGroupID, name: name)
        case .updateEntry(let entryID, let draft):
            updatedState = try applyUpdate(entryID: entryID, draft: draft, binaryPoolFields: &binaryPoolFields)
        case .deleteEntry(let entryID, let sendToRecycleBin):
            updatedState = try applyDelete(entryID: entryID, sendToRecycleBin: sendToRecycleBin)
        case .deleteGroup(let groupID, let sendToRecycleBin):
            updatedState = try applyDeleteGroup(groupID: groupID, sendToRecycleBin: sendToRecycleBin)
        case .setGroupSearchingEnabled(let groupID, let value):
            updatedState = try applySetGroupSearchingEnabled(groupID: groupID, value: value.modelValue)
        case .setGroupIcon(let groupID, let iconID):
            updatedState = try applySetGroupIcon(groupID: groupID, iconID: iconID)
        case .setEntryIcon(let entryID, let icon):
            updatedState = try applySetEntryIcon(entryID: entryID, icon: icon)
        case .addEntryCustomIcon(let entryID, let iconUUID, let imageData):
            updatedState = try applyAddEntryCustomIcon(
                entryID: entryID,
                iconUUID: iconUUID,
                imageData: imageData
            )
        case .updateGroup(let groupID, let draft):
            updatedState = try applyUpdateGroup(groupID: groupID, draft: draft)
        case .restoreEntryVersion(let entryID, let historyIndex):
            updatedState = try applyRestoreEntryVersion(entryID: entryID, historyIndex: historyIndex)
        case .moveEntry(let entryID, let destinationGroupID):
            updatedState = try applyMoveEntry(entryID: entryID, destinationGroupID: destinationGroupID)
        case .moveGroup(let groupID, let destinationGroupID):
            updatedState = try applyMoveGroup(groupID: groupID, destinationGroupID: destinationGroupID)
        }

        updatedState.rootGroup.recycleBinUUID = updatedState.meta.recycleBinUUID

        return DatabaseDraft(
            originalRootGroupStorage: originalRootGroupStorage,
            currentRootGroupStorage: updatedState.rootGroup,
            originalMetaStorage: originalMetaStorage,
            currentMetaStorage: updatedState.meta,
            originalBinaryPoolFields: originalBinaryPoolFields,
            currentBinaryPoolFields: binaryPoolFields,
            sessionKey: sessionKey,
            pendingEdits: pendingEdits + [edit]
        )
    }

    /// Adds `drafts` to one group as if each were applied as `.createEntry`
    /// in order, pending edits included. The group's entry list and the edit
    /// log are copied once rather than once per entry, so a large import
    /// stays linear.
    func creatingEntries(_ drafts: [EntryDraftPayload], inGroup parentGroupID: UUID) throws -> DatabaseDraft {
        guard let parentGroupPath = pathToGroup(withID: parentGroupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(parentGroupID)
        }

        let timestamp = Date.now
        let newEntries = try drafts.map { try makeCreatedEntry(from: $0, timestamp: timestamp) }
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: parentGroupPath[...]) { group in
            copyGroup(group, entries: group.entries + newEntries)
        }
        updatedRootGroup.recycleBinUUID = currentMetaStorage.recycleBinUUID

        return DatabaseDraft(
            originalRootGroupStorage: originalRootGroupStorage,
            currentRootGroupStorage: updatedRootGroup,
            originalMetaStorage: originalMetaStorage,
            currentMetaStorage: currentMetaStorage,
            originalBinaryPoolFields: originalBinaryPoolFields,
            currentBinaryPoolFields: currentBinaryPoolFields,
            sessionKey: sessionKey,
            pendingEdits: pendingEdits + drafts.map { .createEntry(parentGroupID: parentGroupID, draft: $0) }
        )
    }

    func discardingEdits() -> DatabaseDraft {
        DatabaseDraft(
            originalRootGroupStorage: originalRootGroupStorage,
            currentRootGroupStorage: originalRootGroupStorage,
            originalMetaStorage: originalMetaStorage,
            currentMetaStorage: originalMetaStorage,
            originalBinaryPoolFields: originalBinaryPoolFields,
            currentBinaryPoolFields: originalBinaryPoolFields,
            sessionKey: sessionKey,
            pendingEdits: []
        )
    }

    private func applyCreate(
        parentGroupID: UUID,
        draft: EntryDraftPayload,
        binaryPoolFields: inout [Data]?
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let parentGroupPath = pathToGroup(withID: parentGroupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(parentGroupID)
        }

        let timestamp = Date.now
        var newEntry = try makeCreatedEntry(from: draft, timestamp: timestamp)
        if let attachments = draft.attachments {
            newEntry.attachments = try Self.resolvedAttachments(
                attachments,
                of: newEntry,
                keeping: [],
                referencedRefs: Self.attachmentRefs(in: currentRootGroupStorage),
                binaryPoolFields: &binaryPoolFields
            )
        }
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
        try KDBXXMLSerializer.validateText(trimmedName)
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: parentGroupPath[...]) { group in
            if group.groups.contains(where: { $0.name.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                throw DraftError.duplicateGroupName(parentGroupID: parentGroupID, name: trimmedName)
            }

            let timestamp = Date.now
            let newGroup = KPGroup(
                name: trimmedName,
                creationTime: timestamp,
                lastModificationTime: timestamp,
                locationChanged: timestamp
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
                notes: group.notes,
                hasNotesElement: group.hasNotesElement,
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
                locationChanged: group.locationChanged,
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
                notes: group.notes,
                hasNotesElement: group.hasNotesElement,
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
                locationChanged: group.locationChanged,
                recycleBinUUID: group.recycleBinUUID,
                unknownXML: unknownXML
            )
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    /// Where a `<CustomIconUUID>` fragment has to sit to be written directly
    /// after `<IconID>`, expressed in the opaque-XML position space.
    ///
    /// Two structured children precede it — `<UUID>` and `<IconID>` — but a
    /// parsable `<Binary>` advances that space too while *not* advancing the
    /// anchor `KPAttachment.insertionIndex` is expressed against, so an entry
    /// whose source interleaved attachments that early shifts everything after
    /// them. Counting those slots is what keeps this in step with
    /// `KDBXXMLSerializer.serializeEntry`; a fixed 2 writes the element ahead of
    /// `<IconID>` on exactly those entries.
    private static func customIconUUIDInsertionIndex(for entry: KPEntry) -> Int {
        let structuredChildrenBefore = 2
        let attachmentsBefore = entry.attachments.count { $0.insertionIndex < structuredChildrenBefore }
        return structuredChildrenBefore + attachmentsBefore
    }

    /// Changes which icon an entry displays.
    ///
    /// Both selections are expressed in the preserved XML, because that is the
    /// only place `<CustomIconUUID>` lives — the serializer never writes one
    /// structurally, so a display copy alone would be dropped on the next save.
    /// A standard icon therefore removes the element the way the group edit
    /// does, and a custom one replaces it.
    ///
    /// Pushes a history version like every other entry edit, so an icon change
    /// is undoable from the history viewer and matches what other clients record.
    private func applySetEntryIcon(
        entryID: UUID,
        icon: EntryIconSelection
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            throw DraftError.entryNotFound(entryID)
        }

        let updatedEntry = entryDisplaying(icon, entry: entryLocation.entry)
        let updatedRootGroup = try replacingEntry(at: entryLocation, with: updatedEntry)

        return (updatedRootGroup, currentMetaStorage)
    }

    /// The tree with the entry at `location` swapped for `updatedEntry`,
    /// everything around it structurally shared.
    private func replacingEntry(
        at location: (groupPath: [UUID], entryIndex: Int, entry: KPEntry),
        with updatedEntry: KPEntry
    ) throws -> KPGroup {
        try rebuildGroup(in: currentRootGroupStorage, targetPath: location.groupPath[...]) { group in
            var updatedEntries = group.entries
            updatedEntries[location.entryIndex] = updatedEntry
            return copyGroup(group, entries: updatedEntries)
        }
    }

    /// The entry as it looks displaying `icon`, history version pushed.
    ///
    /// Shared with `applyAddEntryCustomIcon`, which stores an image and points
    /// the entry at it in one edit: the pointing half must be the same operation
    /// either way, or the two paths would drift on where the element lands.
    private func entryDisplaying(_ icon: EntryIconSelection, entry: KPEntry) -> KPEntry {
        var updated = entry
        updated.history = trimmedHistory(
            appending: entry.cloneForHistory(),
            existing: entry.history,
            meta: currentMetaStorage
        )
        updated.lastModificationTime = Date.now
        updated.unknownXML.removeDirectChildren(named: "CustomIconUUID")

        switch icon {
        case .standard(let iconID):
            updated.iconID = iconID
            updated.customIconUUID = nil
        case .custom(let uuid):
            updated.customIconUUID = uuid
            updated.unknownXML.append(
                xml: "<CustomIconUUID>\(uuid.kdbxBase64String)</CustomIconUUID>",
                insertionIndex: Self.customIconUUIDInsertionIndex(for: entry)
            )
        }

        return updated
    }

    /// Stores an image in `Meta/CustomIcons` and points the entry at it.
    ///
    /// An image the database already holds is reused rather than stored twice:
    /// the same favicon downloaded onto three entries has to leave one icon in
    /// the file, not three, and KeePass's own icon dialog shows the set, so
    /// duplicates would be visible clutter as well as wasted bytes.
    ///
    /// The stored dictionary and the preserved XML are updated together. The
    /// dictionary is what the UI reads before the next save; the XML is what the
    /// writer emits, since `Meta/CustomIcons` is round-tripped verbatim and
    /// never rebuilt from the dictionary.
    private func applyAddEntryCustomIcon(
        entryID: UUID,
        iconUUID: UUID,
        imageData: Data
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            throw DraftError.entryNotFound(entryID)
        }

        var meta = currentMetaStorage
        let resolvedUUID: UUID
        // Lowest UUID among the matches, not the first the dictionary happens to
        // yield: a database can hold the same bytes under two UUIDs, and
        // `Dictionary` order varies per launch, which would make the same edit
        // on the same input produce different file bytes across runs.
        let duplicates = meta.customIcons.filter { $0.value == imageData }.keys
        if let existing = duplicates.min(by: { $0.uuidString < $1.uuidString }) {
            resolvedUUID = existing
        } else {
            guard let unknownXML = CustomIconXML.adding(
                uuid: iconUUID,
                imageData: imageData,
                to: meta.unknownXML
            ) else {
                throw DraftError.customIconNotStorable
            }
            resolvedUUID = iconUUID
            meta.customIcons[iconUUID] = imageData
            meta.unknownXML = unknownXML
        }

        let updatedEntry = entryDisplaying(.custom(uuid: resolvedUUID), entry: entryLocation.entry)
        let updatedRootGroup = try replacingEntry(at: entryLocation, with: updatedEntry)

        return (updatedRootGroup, meta)
    }

    private func applyUpdateGroup(
        groupID: UUID,
        draft: GroupDraftPayload
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let groupPath = pathToGroup(withID: groupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(groupID)
        }

        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            throw DraftError.emptyGroupName(groupID)
        }

        // Siblings only, and never the group itself: re-saving an unchanged
        // name must not read as a collision.
        if groupPath.count >= 2 {
            let parentGroupID = groupPath[groupPath.count - 2]
            let siblings = findGroup(withID: parentGroupID, in: currentRootGroupStorage)?.groups ?? []
            let collides = siblings.contains { sibling in
                sibling.id != groupID &&
                sibling.name.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            if collides {
                throw DraftError.duplicateGroupName(parentGroupID: parentGroupID, name: trimmedName)
            }
        }

        let tags = TagNormalizer.tags(from: draft.tags)
        try KDBXXMLSerializer.validateText(trimmedName)
        try KDBXXMLSerializer.validateText(draft.notes)
        for tag in tags {
            try KDBXXMLSerializer.validateText(tag)
        }
        let timestamp = Date.now
        let updatedRootGroup = try rebuildGroup(in: currentRootGroupStorage, targetPath: groupPath[...]) { group in
            var unknownXML = group.unknownXML
            // `<Notes>` is structured now, so any preserved copy would be
            // emitted next to it; same reason `setGroupSearchingEnabled` drops
            // its element, and only dropped there when a structured value
            // replaces it.
            unknownXML.removeDirectChildren(named: "Notes")
            if draft.searchingEnabled != nil {
                unknownXML.removeDirectChildren(named: "EnableSearching")
            }

            // A `<CustomIconUUID>` outranks `<IconID>`, so it only goes when
            // the user actually picked a different icon — renaming a group must
            // not swap the icon it displays.
            let iconChanged = draft.iconID != group.iconID
            if iconChanged {
                unknownXML.removeDirectChildren(named: "CustomIconUUID")
            }

            return KPGroup(
                id: group.id,
                name: trimmedName,
                notes: draft.notes,
                hasNotesElement: group.hasNotesElement || !draft.notes.isEmpty,
                iconID: draft.iconID,
                customIconUUID: iconChanged ? nil : group.customIconUUID,
                tags: tags,
                // Deliberately not raised for new tags: the serializer already
                // writes `<Tags>` for a non-empty list, and leaving the flag
                // alone is what keeps a group that never had the element from
                // gaining an empty one when the user clears its tags.
                hasTagsElement: group.hasTagsElement,
                entries: group.entries,
                groups: group.groups,
                isExpanded: group.isExpanded,
                searchingEnabled: draft.searchingEnabled?.modelValue,
                creationTime: group.creationTime,
                lastModificationTime: timestamp,
                locationChanged: group.locationChanged,
                recycleBinUUID: group.recycleBinUUID,
                unknownXML: unknownXML
            )
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func applyUpdate(
        entryID: UUID,
        draft: EntryDraftPayload,
        binaryPoolFields: inout [Data]?
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            throw DraftError.entryNotFound(entryID)
        }

        let timestamp = Date.now
        var updatedEntry = try makeUpdatedEntry(
            from: draft,
            originalEntry: entryLocation.entry,
            timestamp: timestamp
        )
        if let attachments = draft.attachments {
            updatedEntry.attachments = try Self.resolvedAttachments(
                attachments,
                of: updatedEntry,
                keeping: entryLocation.entry.attachments,
                referencedRefs: Self.attachmentRefs(in: currentRootGroupStorage),
                binaryPoolFields: &binaryPoolFields
            )
        }
        let updatedRootGroup = try replacingEntry(at: entryLocation, with: updatedEntry)

        return (updatedRootGroup, currentMetaStorage)
    }

    /// The attachments `payloads` describe, storing new files in the pool.
    ///
    /// Removing an attachment only drops the entry's reference: the version
    /// pushed onto the history still points at the bytes, as in KeePass, so
    /// the pool entry stays. A new file whose bytes the pool already holds
    /// reuses that entry, as KeePassXC does on save.
    ///
    /// Appending never takes an index some attachment already names: a
    /// dangling ref there, on any entry or history version, would silently
    /// start resolving to the new file's bytes.
    private static func resolvedAttachments(
        _ payloads: [EntryAttachmentPayload],
        of entry: KPEntry,
        keeping original: [KPAttachment],
        referencedRefs: Set<Int>,
        binaryPoolFields: inout [Data]?
    ) throws -> [KPAttachment] {
        var unclaimed = original
        var resolved: [KPAttachment] = []
        for payload in payloads {
            switch payload {
            case .existing(let name, let ref):
                guard let index = unclaimed.firstIndex(where: { $0.name == name && $0.ref == ref }) else {
                    throw DraftError.attachmentNotFound(name: name)
                }
                resolved.append(unclaimed.remove(at: index))
            case .new(let name, let data):
                guard var pool = binaryPoolFields else {
                    throw DraftError.attachmentPoolUnavailable
                }
                let ref: Int
                if let existing = pool.firstIndex(where: { $0.dropFirst() == data }) {
                    ref = existing
                } else {
                    guard referencedRefs.contains(pool.count) == false else {
                        throw DraftError.attachmentWouldClaimMissingReference
                    }
                    // The pool alone must fit what the reader inflates,
                    // whatever the file's compression is now; the writer
                    // makes the exact check once the XML is known.
                    let appendedByteCount = innerHeaderFieldFraming + 1 + data.count
                    guard innerHeaderByteCount(of: pool) + appendedByteCount <= KDBXCrypto.maxDecompressedSize else {
                        throw DraftError.attachmentsTooLarge
                    }
                    // KeePassXC flags every pool entry it writes as protected.
                    pool.append(Data([0x01]) + data)
                    ref = pool.count - 1
                }
                binaryPoolFields = pool
                resolved.append(KPAttachment(
                    name: name,
                    ref: ref,
                    insertionIndex: resolved.last?.insertionIndex ?? attachmentInsertionIndexAfterNotes(for: entry)
                ))
            }
        }
        return resolved
    }

    /// An inner-header field's one-byte type and four-byte length.
    private static let innerHeaderFieldFraming = 5

    /// The bytes `pool` occupies in the inner header.
    private static func innerHeaderByteCount(of pool: [Data]) -> Int {
        pool.reduce(0) { $0 + innerHeaderFieldFraming + $1.count }
    }

    /// Every pool ref an attachment in `group`'s subtree names, history
    /// versions included.
    private static func attachmentRefs(in group: KPGroup) -> Set<Int> {
        var refs = Set<Int>()
        for entry in group.allEntries {
            refs.formUnion(entry.attachments.map(\.ref))
            for version in entry.history {
                refs.formUnion(version.attachments.map(\.ref))
            }
        }
        return refs
    }

    /// The `KPAttachment.insertionIndex` that writes a `<Binary>` directly
    /// after `<Notes>`, and that the parser reports back for it.
    ///
    /// Every entry writes `<UUID>`, `<IconID>` and the five standard strings,
    /// `<Tags>` and `<Times>` only sometimes, all of them ahead of `<Notes>`.
    /// Whatever the serializer writes after `<Notes>` cannot move this slot:
    /// with nothing after it the attachment trails the entry, which the parser
    /// counts as the same position. An edited entry always carries
    /// `<LastModificationTime>`, so `<Times>` is always written here.
    private static func attachmentInsertionIndexAfterNotes(for entry: KPEntry) -> Int {
        let hasTags = entry.hasTagsElement || !entry.tags.isEmpty
        let hasTimes = entry.creationTime != nil || entry.lastModificationTime != nil || entry.locationChanged != nil
        return 2 + (hasTags ? 1 : 0) + (hasTimes ? 1 : 0) + 5
    }

    /// Whether a restore would keep the state it replaces, i.e. whether it can be undone.
    ///
    /// `HistoryMaxItems`/`HistoryMaxSize` can discard the pushed snapshot, so the
    /// confirmation must not promise an undo without asking first. This runs the real
    /// trim and checks that the snapshot itself survives — "anything survived" is not
    /// enough, because a stored version stamped ahead of the live entry (a device with
    /// a skewed clock can write one) outranks the snapshot in the recency order.
    func restoreKeepsReplacedState(entryID: UUID) -> Bool {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            return false
        }
        let current = entryLocation.entry
        let history = ([current] + current.history).map { $0.cloneForHistory() }
        return survivingHistoryIndices(of: history, meta: currentMetaStorage).contains(0)
    }

    /// Makes a stored history version current again.
    ///
    /// The state being replaced is pushed onto the history first, so a restore is
    /// itself reversible and never destroys the version the user was looking at.
    ///
    /// Identity and provenance stay with the live entry rather than coming from the
    /// snapshot: `id` (so references elsewhere keep resolving), `creationTime` (the
    /// entry was created once, restoring is not re-creating it), non-expiry `unknownXML`, and
    /// `customIconUUID`. The last two go together — the live entry's preserved XML
    /// describes the element layout the writer round-trips today, including where
    /// `<History>` sits and any `<CustomIconUUID>` (the serializer writes that element
    /// only from the preserved XML), so the display copy has to match those bytes or
    /// the shown icon would differ from every other client's after a save.
    /// Everything else the user can see or edit comes from the snapshot.
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
        var unknownXML = current.unknownXML
        // Expiry has a display copy, but the serializer writes its preserved XML.
        for elementName in ["ExpiryTime", "Expires"] {
            let matches: (OpaqueXMLNodes.Node) -> Bool = {
                $0.path == ["Times"] && $0.elementName == elementName
            }
            let insertionIndex = unknownXML.nodes.first(where: matches)?.insertionIndex
                ?? ((current.creationTime != nil ? 1 : 0) + 1)
            let nodeIndex = unknownXML.nodes.firstIndex(where: matches) ?? unknownXML.nodes.count
            unknownXML.nodes.removeAll(where: matches)
            unknownXML.nodes.insert(
                contentsOf: version.unknownXML.nodes.filter(matches).map {
                    OpaqueXMLNodes.Node(path: ["Times"], insertionIndex: insertionIndex, xml: $0.xml)
                },
                at: nodeIndex
            )
        }

        let restored = KPEntry(
            id: current.id,
            title: version.title,
            username: version.username,
            password: version.password,
            url: version.url,
            notes: version.notes,
            iconID: version.iconID,
            customIconUUID: current.customIconUUID,
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
            // Restoring a version does not move the entry, so where it lives
            // stays with the live entry, like `id` and `creationTime`.
            locationChanged: current.locationChanged,
            history: trimmedHistory(
                appending: current.cloneForHistory(),
                existing: current.history,
                meta: currentMetaStorage
            ),
            unknownXML: unknownXML,
            protectedStringKeys: version.protectedStringKeys,
            attachments: version.attachments
        )

        let updatedRootGroup = try replacingEntry(at: entryLocation, with: restored)

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

        // Recycling is a move, so the entry's `<LocationChanged>` advances while
        // its modification time stays put — that is how KeePass records it, and
        // what lets a merge tell a recycle apart from an edit.
        let timestamp = Date.now
        var recycledEntry = entryLocation.entry
        recycledEntry.locationChanged = timestamp

        switch recycleBinTarget(in: rootWithoutEntry, meta: currentMetaStorage) {
        case .existing(let recycleBinPath):
            let updatedRootGroup = try rebuildGroup(in: rootWithoutEntry, targetPath: recycleBinPath[...]) { group in
                var updatedEntries = group.entries
                updatedEntries.append(recycledEntry)
                return copyGroup(group, entries: updatedEntries)
            }
            return (updatedRootGroup, currentMetaStorage)

        case .create(let recycleBinID):
            let recycleBinGroup = makeRecycleBinGroup(
                id: recycleBinID,
                entry: recycledEntry,
                timestamp: timestamp
            )
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

        // Same as the entry path: the recycled group moved, so only its
        // `<LocationChanged>` advances. Its subtree did not move relative to it
        // and keeps its own timestamps.
        let timestamp = Date.now
        let recycledGroup = copyGroup(groupLocation.group, locationChanged: timestamp)

        switch recycleBinTarget(in: rootWithoutGroup, meta: currentMetaStorage) {
        case .existing(let recycleBinPath):
            let updatedRootGroup = try rebuildGroup(in: rootWithoutGroup, targetPath: recycleBinPath[...]) { group in
                var updatedGroups = group.groups
                updatedGroups.append(recycledGroup)
                return copyGroup(group, groups: updatedGroups)
            }
            return (updatedRootGroup, currentMetaStorage)

        case .create(let recycleBinID):
            let recycleBinGroup = makeRecycleBinGroup(
                id: recycleBinID,
                group: recycledGroup,
                timestamp: timestamp
            )
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

    private func applyMoveEntry(
        entryID: UUID,
        destinationGroupID: UUID
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard let entryLocation = findEntryLocation(entryID: entryID, in: currentRootGroupStorage) else {
            throw DraftError.entryNotFound(entryID)
        }

        guard let destinationPath = pathToGroup(withID: destinationGroupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(destinationGroupID)
        }

        let rootWithoutEntry = try rebuildGroup(in: currentRootGroupStorage, targetPath: entryLocation.groupPath[...]) { group in
            var updatedEntries = group.entries
            updatedEntries.remove(at: entryLocation.entryIndex)
            return copyGroup(group, entries: updatedEntries)
        }

        // A move only reparents: `<LocationChanged>` advances while the
        // modification time stays put, exactly as recycling records it.
        var movedEntry = entryLocation.entry
        movedEntry.locationChanged = Date.now

        let updatedRootGroup = try rebuildGroup(in: rootWithoutEntry, targetPath: destinationPath[...]) { group in
            var updatedEntries = group.entries
            updatedEntries.append(movedEntry)
            return copyGroup(group, entries: updatedEntries)
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func applyMoveGroup(
        groupID: UUID,
        destinationGroupID: UUID
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        guard isProtectedGroupForDeletion(groupID, in: currentRootGroupStorage, meta: currentMetaStorage) == false else {
            throw DraftError.protectedGroup(groupID)
        }

        guard let groupLocation = findGroupLocation(groupID: groupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(groupID)
        }

        guard containsGroup(withID: destinationGroupID, in: groupLocation.group) == false else {
            throw DraftError.moveDestinationInsideMovedGroup(groupID: groupID, destinationGroupID: destinationGroupID)
        }

        guard let destinationPath = pathToGroup(withID: destinationGroupID, in: currentRootGroupStorage) else {
            throw DraftError.groupNotFound(destinationGroupID)
        }

        let rootWithoutGroup = try rebuildGroup(
            in: currentRootGroupStorage,
            targetPath: groupLocation.parentPath[...]
        ) { parentGroup in
            var updatedGroups = parentGroup.groups
            updatedGroups.remove(at: groupLocation.groupIndex)
            return copyGroup(parentGroup, groups: updatedGroups)
        }

        // Only the moved group changed parent; its subtree did not move
        // relative to it and keeps its own timestamps.
        let movedGroup = copyGroup(groupLocation.group, locationChanged: Date.now)

        let updatedRootGroup = try rebuildGroup(in: rootWithoutGroup, targetPath: destinationPath[...]) { group in
            if group.groups.contains(where: { $0.name.compare(movedGroup.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                throw DraftError.duplicateGroupName(parentGroupID: destinationGroupID, name: movedGroup.name)
            }

            var updatedGroups = group.groups
            updatedGroups.append(movedGroup)
            return copyGroup(group, groups: updatedGroups)
        }

        return (updatedRootGroup, currentMetaStorage)
    }

    private func makeCreatedEntry(
        from draft: EntryDraftPayload,
        timestamp: Date
    ) throws -> KPEntry {
        let customFields = activeCustomFields(from: draft)
        let passkeyPrivateKey = try draftPasskeyPrivateKey(from: draft, fallback: nil)
        let entry = KPEntry(
            title: draft.title,
            username: draft.username,
            password: try EncryptedValue.encrypt(draft.password, using: sessionKey),
            url: draft.url,
            notes: draft.notes,
            tags: draft.tags,
            hasTagsElement: !draft.tags.isEmpty,
            customFields: customFields,
            passkeyPrivateKey: passkeyPrivateKey,
            totpConfig: try makeTOTPConfig(from: draft.totpConfig),
            otpURL: draft.totpConfig?.keeOTPSource == nil
                ? draft.totpConfig?.otpauthURI
                : (draft.totpConfig?.keeOTPSource?.fieldName == "otp"
                    ? draft.totpConfig?.keeOTPSource?.rawQuery
                    : nil),
            creationTime: timestamp,
            lastModificationTime: timestamp,
            locationChanged: timestamp,
            protectedStringKeys: draftProtectedStringKeys(
                from: draft,
                customFields: customFields,
                passkeyPrivateKey: passkeyPrivateKey
            )
        )
        try validateText(in: draft, protectedStringKeys: entry.protectedStringKeys)
        return draft.expiry.map { EntryExpiryXML.entry(entry, expiring: $0) } ?? entry
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

        let customFields = activeCustomFields(from: draft)
        let passkeyPrivateKey = try draftPasskeyPrivateKey(
            from: draft,
            fallback: originalEntry.passkeyPrivateKey
        )
        let entry = KPEntry(
            id: originalEntry.id,
            title: draft.title,
            username: draft.username,
            password: try EncryptedValue.encrypt(draft.password, using: sessionKey),
            url: draft.url,
            notes: draft.notes,
            iconID: originalEntry.iconID,
            tags: draft.tags,
            hasTagsElement: originalEntry.hasTagsElement || !draft.tags.isEmpty,
            customFields: customFields,
            passkeyPrivateKey: passkeyPrivateKey,
            totpConfig: try makeTOTPConfig(from: draft.totpConfig, originalEntry: originalEntry),
            otpURL: updatedOtpURL(draft: draft, originalEntry: originalEntry),
            creationTime: originalEntry.creationTime,
            lastModificationTime: timestamp,
            expires: originalEntry.expires,
            expiryTime: originalEntry.expiryTime,
            locationChanged: originalEntry.locationChanged,
            history: history,
            unknownXML: originalEntry.unknownXML,
            protectedStringKeys: preservedProtectedStringKeys(
                from: originalEntry,
                customFields: draft.customFields
            ).union(draftProtectedStringKeys(
                from: draft,
                customFields: customFields,
                passkeyPrivateKey: passkeyPrivateKey
            )),
            attachments: originalEntry.attachments
        )
        try validateText(in: draft, protectedStringKeys: entry.protectedStringKeys)
        return draft.expiry.map { EntryExpiryXML.entry(entry, expiring: $0) } ?? entry
    }

    private func validateText(in draft: EntryDraftPayload, protectedStringKeys: Set<String>) throws {
        var fields = [
            ("Title", draft.title), ("UserName", draft.username),
            ("URL", draft.url), ("Notes", draft.notes),
        ] + draft.customFields.map { ($0.key, $0.value) }
        if let source = draft.totpConfig?.keeOTPSource {
            fields.append((source.fieldName, source.rawQuery))
        } else if let uri = draft.totpConfig?.otpauthURI {
            fields.append(("otp", uri))
        }
        for (key, value) in fields {
            try KDBXXMLSerializer.validateText(key)
            if !protectedStringKeys.contains(key) {
                try KDBXXMLSerializer.validateText(value)
            }
        }
        for tag in draft.tags {
            try KDBXXMLSerializer.validateText(tag)
        }
        for attachment in draft.attachments ?? [] {
            switch attachment {
            case .existing(let name, _), .new(let name, _):
                try KDBXXMLSerializer.validateText(name)
            }
        }
    }

    private func updatedOtpURL(
        draft: EntryDraftPayload,
        originalEntry: KPEntry
    ) -> String? {
        guard let source = draft.totpConfig?.keeOTPSource else {
            // A fresh enrollment URI is a deliberate re-enrollment: it
            // replaces whatever the entry stored in the otp slot. A KeeOTP
            // source outranks it (matching the serializer's precedence), so
            // the URI is honored only when no legacy source owns the config.
            if let uri = draft.totpConfig?.otpauthURI {
                return uri
            }
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
        from draft: EntryDraftPayload.TOTPConfiguration?,
        originalEntry: KPEntry? = nil
    ) throws -> TOTPConfig? {
        guard let draft, !draft.secret.isEmpty else {
            return nil
        }

        return TOTPConfig(
            secret: try EncryptedValue.encrypt(draft.secret, using: sessionKey),
            decodedSecret: try draft.decodedSecret.map { try EncryptedValue.encrypt($0, using: sessionKey) },
            keeOTPSource: draft.keeOTPSource,
            keePassSecretField: preservedKeePassSecretField(draft: draft, originalEntry: originalEntry),
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm
        )
    }

    /// A draft does not say which KeePass field holds its secret. An
    /// unchanged secret stays in the field the entry keeps it in; a new or
    /// changed one is Base32.
    private func preservedKeePassSecretField(
        draft: EntryDraftPayload.TOTPConfiguration,
        originalEntry: KPEntry?
    ) -> KeePassTOTPSecretField {
        guard let originalConfig = originalEntry?.totpConfig,
              draft.keeOTPSource == nil,
              draft.decodedSecret != nil,
              let originalSecret = try? originalConfig.secret.decrypt(using: sessionKey),
              draft.secret == originalSecret
        else {
            return .base32
        }
        return originalConfig.keePassSecretField
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

    /// Protection requested by the draft, limited to keys the entry will
    /// actually serialize: its stored custom fields plus the diverted passkey
    /// PEM key, which the serializer re-emits keyed off `protectedStringKeys`.
    private func draftProtectedStringKeys(
        from draft: EntryDraftPayload,
        customFields: [String: String],
        passkeyPrivateKey: EncryptedValue?
    ) -> Set<String> {
        var serializableKeys = Set(customFields.keys)
        if passkeyPrivateKey != nil {
            serializableKeys.insert(PasskeyCredential.privateKeyPEMKey)
        }
        var keys = draft.protectedCustomFieldKeys.intersection(serializableKeys)
        if draft.totpConfig?.otpauthURI != nil, draft.totpConfig?.keeOTPSource == nil {
            // A freshly enrolled otpauth URI serializes into the otp slot and
            // must be protected, matching how KeePassXC stores it. A KeeOTP
            // source outranks the URI, so it gates here too.
            keys.insert("otp")
        }
        return keys
    }

    private func trimmedHistory(
        appending snapshot: KPEntry,
        existing: [KPEntry],
        meta: KPMeta
    ) -> [KPEntry] {
        EntryHistoryTrimmer.trimmed(
            appending: snapshot,
            existing: existing,
            meta: meta,
            sessionKey: sessionKey
        )
    }

    private func survivingHistoryIndices(of history: [KPEntry], meta: KPMeta) -> Set<Int> {
        EntryHistoryTrimmer.survivingIndices(of: history, meta: meta, sessionKey: sessionKey)
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

    private func makeRecycleBinGroup(id: UUID, entry: KPEntry, timestamp: Date) -> KPGroup {
        KPGroup(
            id: id,
            name: Self.localizedRecycleBinName,
            iconID: 43,
            entries: [entry],
            creationTime: timestamp,
            lastModificationTime: timestamp,
            locationChanged: timestamp
        )
    }

    private func makeRecycleBinGroup(id: UUID, group: KPGroup, timestamp: Date) -> KPGroup {
        KPGroup(
            id: id,
            name: Self.localizedRecycleBinName,
            iconID: 43,
            groups: [group],
            creationTime: timestamp,
            lastModificationTime: timestamp,
            locationChanged: timestamp
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

    /// Rebuilds a group with some children replaced. `locationChanged` is an
    /// override rather than a carried field: passing one marks a reparent,
    /// `nil` keeps whatever the group already had.
    private func copyGroup(
        _ group: KPGroup,
        entries: [KPEntry]? = nil,
        groups: [KPGroup]? = nil,
        recycleBinUUIDOverride: RecycleBinUUIDOverride = .keep,
        locationChanged: Date? = nil
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
            notes: group.notes,
            hasNotesElement: group.hasNotesElement,
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
            locationChanged: locationChanged ?? group.locationChanged,
            recycleBinUUID: recycleBinUUID,
            unknownXML: group.unknownXML
        )
    }
}
