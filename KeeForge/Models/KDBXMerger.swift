import CryptoKit
import Foundation

/// Record-level reconciliation of two parses of the same database, in the style
/// of KeePass 2.x Synchronize / KeePassXC merge.
///
/// Both sides must be parsed with the *same* session key, so protected values
/// graft across without a decrypt/reseal cycle and can be compared in plaintext
/// (`EncryptedValue` ciphertext is nonce-randomized, so equal secrets have
/// unequal sealed bytes).
///
/// The engine is pure: it never mutates either input and the tree it returns
/// aliases neither of them. It has no actor isolation — parsing and comparing
/// secrets belongs off the main actor, so callers run it on a detached task.
///
/// Safety property: when the result cannot be proven lossless the engine
/// declines rather than guessing. Losing sides of entry conflicts land in entry
/// history, so a merge never drops a version the file already held.
enum KDBXMerger {
    /// One parsed side of the merge.
    struct Side: Sendable {
        var rootGroup: KPGroup
        var meta: KPMeta
        /// The side's KDBX4 inner-header binary pool, verbatim
        /// (`KDBXParser.Header.innerHeaderBinaryFields`). Used only for the
        /// divergence check: the writer re-emits the pool of the file being
        /// replaced and cannot renumber refs.
        var binaryPoolFields: [Data]

        init(rootGroup: KPGroup, meta: KPMeta, binaryPoolFields: [Data] = []) {
            self.rootGroup = rootGroup
            self.meta = meta
            self.binaryPoolFields = binaryPoolFields
        }
    }

    /// What the merge changed, relative to the local side.
    ///
    /// Every counter is a delta against local, not a count of work done: a
    /// second merge of the same remote must report all zeros (see `hasChanges`),
    /// which is what makes idempotence observable.
    struct Summary: Sendable, Hashable {
        var entriesAdded = 0
        var entriesUpdated = 0
        var entriesMoved = 0
        var groupsAdded = 0
        var groupsUpdated = 0
        var groupsMoved = 0
        var historyItemsAdded = 0
        var deletionsApplied = 0
        /// Tombstones local held that the merge dropped because the object was
        /// edited after its deletion time (edit-after-delete resurrection).
        var tombstonesDropped = 0
        /// Tombstones adopted from remote, so the deletion propagates onward.
        var tombstonesAdded = 0
        var customIconsSpliced = 0
        /// Icon references the merge could not satisfy. Cosmetic only — KeePass
        /// and KeePassXC fall back to the default icon — so not a blocker, and
        /// deliberately not a change.
        var danglingIconReferences = 0

        var hasChanges: Bool {
            entriesAdded > 0 || entriesUpdated > 0 || entriesMoved > 0
                || groupsAdded > 0 || groupsUpdated > 0 || groupsMoved > 0
                || historyItemsAdded > 0 || deletionsApplied > 0
                || tombstonesDropped > 0 || tombstonesAdded > 0
                || customIconsSpliced > 0
        }
    }

    /// A freshly built tree and meta that alias neither input.
    struct Merged: Sendable {
        let rootGroup: KPGroup
        let meta: KPMeta
        let summary: Summary
    }

    /// Why a merge could not be proven safe. Remote parse failure and KDBX 3.1
    /// are detected before the engine runs and are not modelled here.
    enum Blocker: Sendable, Hashable {
        /// The two inner-header binary pools differ and something references an
        /// attachment. KeeForge re-emits the pool of the file it replaces and
        /// cannot renumber refs, so a grafted ref could point at other data.
        case attachmentPoolDivergence
    }

    enum Outcome: Sendable {
        case merged(Merged)
        case declined([Blocker])
    }

    enum MergeError: Error, Equatable {
        /// A protected value would not decrypt under the session key, so the
        /// two sides cannot be compared. Both sides must be parsed with the
        /// same key.
        case protectedValueUnreadable
    }

    /// Merges `remote` into `local`.
    ///
    /// - Returns: `.merged` with a tree/meta pair built for a pristine draft
    ///   save, or `.declined` listing what stopped it.
    /// - Throws: `MergeError` when the two sides cannot be compared.
    static func merge(local: Side, remote: Side, sessionKey: SymmetricKey) throws -> Outcome {
        let declined = blockers(local: local, remote: remote)
        guard declined.isEmpty else { return .declined(declined) }

        let engine = Engine(local: local, remote: remote, sessionKey: sessionKey)
        return .merged(try engine.run())
    }

    // MARK: - Blockers

    private static func blockers(local: Side, remote: Side) -> [Blocker] {
        guard local.binaryPoolFields != remote.binaryPoolFields else { return [] }
        guard referencesAttachments(local.rootGroup) || referencesAttachments(remote.rootGroup) else {
            // Divergent pools nothing points into cannot dangle.
            return []
        }
        return [.attachmentPoolDivergence]
    }

    private static func referencesAttachments(_ group: KPGroup) -> Bool {
        for entry in group.entries {
            if !entry.attachments.isEmpty { return true }
            if entry.history.contains(where: { !$0.attachments.isEmpty }) { return true }
        }
        return group.groups.contains(where: referencesAttachments)
    }

    // MARK: - Timestamps

    /// KDBX stores whole seconds; anything finer is an artefact of how a value
    /// reached memory and must not decide a conflict.
    static func truncatedToSeconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    /// Strictly newer at second granularity. A missing timestamp means "never
    /// happened" and loses to any present one; two missing ones are equal.
    static func isNewer(_ candidate: Date?, than baseline: Date?) -> Bool {
        guard let candidate else { return false }
        guard let baseline else { return true }
        return truncatedToSeconds(candidate) > truncatedToSeconds(baseline)
    }
}

// MARK: - Engine

extension KDBXMerger {
    /// The mutable state of one merge run.
    ///
    /// `KPGroup` is a reference type, so the run works on a deep copy of the
    /// local tree and grafts deep copies of remote subtrees: nothing it touches
    /// is shared with either input.
    private final class Engine {
        let local: Side
        let remote: Side
        let sessionKey: SymmetricKey

        private let root: KPGroup
        private var meta: KPMeta
        private var summary = Summary()

        /// Live index of the merged tree. Rebuilt nowhere: every structural
        /// change updates it, so lookups stay O(1) as the tree changes shape.
        private var groupsByID: [UUID: KPGroup] = [:]
        private var parentByGroupID: [UUID: KPGroup] = [:]
        private var entryOwnerByID: [UUID: KPGroup] = [:]

        /// Custom-icon references that arrived with remote content in this run.
        private var remoteIconReferences: Set<UUID> = []

        init(local: Side, remote: Side, sessionKey: SymmetricKey) {
            self.local = local
            self.remote = remote
            self.sessionKey = sessionKey
            self.root = local.rootGroup.deepCopy()
            self.meta = local.meta
        }

        func run() throws -> Merged {
            indexTree()
            mergeGroups()
            try mergeEntries()
            applyDeletions()
            mergeMeta()

            root.recycleBinUUID = meta.recycleBinUUID
            return Merged(rootGroup: root, meta: meta, summary: summary)
        }

        // MARK: Index

        private func indexTree() {
            func visit(_ group: KPGroup, parent: KPGroup?) {
                groupsByID[group.id] = group
                if let parent { parentByGroupID[group.id] = parent }
                for entry in group.entries where entryOwnerByID[entry.id] == nil {
                    entryOwnerByID[entry.id] = group
                }
                for child in group.groups { visit(child, parent: group) }
            }
            visit(root, parent: nil)
        }

        /// The merged-tree group that stands in for a remote parent. Remote's
        /// root maps to local's root even when the two roots carry different
        /// UUIDs.
        private func mergedParent(forRemoteParentID id: UUID) -> KPGroup {
            id == remote.rootGroup.id ? root : (groupsByID[id] ?? root)
        }

        private func isDescendant(_ candidate: KPGroup, of ancestor: KPGroup) -> Bool {
            var cursor: KPGroup? = candidate
            while let group = cursor {
                if group === ancestor { return true }
                cursor = parentByGroupID[group.id]
            }
            return false
        }

        // MARK: Groups

        /// Pre-order over the remote tree, so a group's parent is in place
        /// before the group itself is matched or grafted.
        ///
        /// The remote root's own scalars are deliberately left alone: v1 keeps
        /// local Meta, and the root group is database-level furniture rather
        /// than a record.
        private func mergeGroups() {
            func visit(_ remoteGroup: KPGroup, remoteParent: KPGroup?) {
                if let remoteParent {
                    apply(remoteGroup: remoteGroup, remoteParentID: remoteParent.id)
                }
                for child in remoteGroup.groups { visit(child, remoteParent: remoteGroup) }
            }
            visit(remote.rootGroup, remoteParent: nil)
        }

        private func apply(remoteGroup: KPGroup, remoteParentID: UUID) {
            let targetParent = mergedParent(forRemoteParentID: remoteParentID)

            guard let existing = groupsByID[remoteGroup.id] else {
                // Shallow graft: children arrive through the walk, so an entry
                // or group that also exists elsewhere locally is matched and
                // moved rather than duplicated under a new UUID twin.
                let copy = remoteGroup.deepCopy()
                copy.entries = []
                copy.groups = []
                targetParent.groups.append(copy)
                groupsByID[copy.id] = copy
                parentByGroupID[copy.id] = targetParent
                noteRemoteIconReference(copy.customIconUUID)
                summary.groupsAdded += 1
                return
            }

            if KDBXMerger.isNewer(remoteGroup.lastModificationTime, than: existing.lastModificationTime) {
                adoptScalars(from: remoteGroup, into: existing)
                summary.groupsUpdated += 1
            }

            guard KDBXMerger.isNewer(remoteGroup.locationChanged, than: existing.locationChanged) else { return }
            existing.locationChanged = remoteGroup.locationChanged

            guard let currentParent = parentByGroupID[existing.id],
                  currentParent !== targetParent,
                  !isDescendant(targetParent, of: existing)
            else { return }

            currentParent.groups.removeAll { $0 === existing }
            targetParent.groups.append(existing)
            parentByGroupID[existing.id] = targetParent
            summary.groupsMoved += 1
        }

        /// The newer side wins the whole group: name, notes, icon, times, and
        /// its preserved XML, which is where `<CustomIconUUID>` and every other
        /// unmodelled group scalar lives. Children and `locationChanged` are
        /// not scalars — they are decided by the walk and the move rule.
        private func adoptScalars(from source: KPGroup, into target: KPGroup) {
            target.name = source.name
            target.notes = source.notes
            target.hasNotesElement = source.hasNotesElement
            target.iconID = source.iconID
            target.customIconUUID = source.customIconUUID
            target.tags = source.tags
            target.hasTagsElement = source.hasTagsElement
            target.isExpanded = source.isExpanded
            target.searchingEnabled = source.searchingEnabled
            target.creationTime = source.creationTime
            target.lastModificationTime = source.lastModificationTime
            target.unknownXML = source.unknownXML
            noteRemoteIconReference(source.customIconUUID)
        }

        // MARK: Entries

        private func mergeEntries() throws {
            func visit(_ remoteGroup: KPGroup) throws {
                for remoteEntry in remoteGroup.entries {
                    try apply(remoteEntry: remoteEntry, remoteParentID: remoteGroup.id)
                }
                for child in remoteGroup.groups { try visit(child) }
            }
            try visit(remote.rootGroup)
        }

        private func apply(remoteEntry: KPEntry, remoteParentID: UUID) throws {
            let targetParent = mergedParent(forRemoteParentID: remoteParentID)

            guard let owner = entryOwnerByID[remoteEntry.id],
                  let index = owner.entries.firstIndex(where: { $0.id == remoteEntry.id })
            else {
                targetParent.entries.append(remoteEntry)
                entryOwnerByID[remoteEntry.id] = targetParent
                noteRemoteIconReference(remoteEntry.customIconUUID)
                summary.entriesAdded += 1
                return
            }

            let localEntry = owner.entries[index]
            let remoteWins = KDBXMerger.isNewer(remoteEntry.lastModificationTime, than: localEntry.lastModificationTime)
            let localWins = KDBXMerger.isNewer(localEntry.lastModificationTime, than: remoteEntry.lastModificationTime)
            let sameContent = try hasEqualContent(localEntry, remoteEntry)

            // Entry granularity is deliberate: KeePass rejects field-level
            // merge, so the newer side wins every field at once and the loser's
            // current state is preserved as a history version instead.
            var merged = remoteWins ? remoteEntry : localEntry
            merged.id = localEntry.id
            merged.history = try mergedHistory(
                local: localEntry,
                remote: remoteEntry,
                remoteWins: remoteWins,
                localWins: localWins,
                sameContent: sameContent
            )

            if remoteWins {
                noteRemoteIconReference(merged.customIconUUID)
                if !sameContent { summary.entriesUpdated += 1 }
            }
            summary.historyItemsAdded += addedHistoryCount(
                from: localEntry.history,
                to: merged.history
            )

            let adoptsRemoteLocation = KDBXMerger.isNewer(remoteEntry.locationChanged, than: localEntry.locationChanged)
            merged.locationChanged = adoptsRemoteLocation ? remoteEntry.locationChanged : localEntry.locationChanged

            if adoptsRemoteLocation, targetParent !== owner {
                owner.entries.remove(at: index)
                targetParent.entries.append(merged)
                entryOwnerByID[merged.id] = targetParent
                summary.entriesMoved += 1
            } else {
                owner.entries[index] = merged
            }
        }

        /// Both sides' versions, one per `LastModificationTime`, oldest first,
        /// plus the losing current state — then the database's history limits.
        ///
        /// Local's array order is kept verbatim when the union adds nothing, so
        /// a merge that touches no history does not rewrite a foreign file's
        /// `<History>` bytes.
        private func mergedHistory(
            local localEntry: KPEntry,
            remote remoteEntry: KPEntry,
            remoteWins: Bool,
            localWins: Bool,
            sameContent: Bool
        ) throws -> [KPEntry] {
            var keys = Set(localEntry.history.map(historyKey))
            var additions: [KPEntry] = []

            for version in remoteEntry.history where !keys.contains(historyKey(of: version)) {
                keys.insert(historyKey(of: version))
                additions.append(version.cloneForHistory())
            }

            if !sameContent, remoteWins || localWins {
                let loser = (remoteWins ? localEntry : remoteEntry).cloneForHistory()
                var alreadyStored = keys.contains(historyKey(of: loser))
                if !alreadyStored {
                    // Re-merging the same remote must not stack a second copy
                    // of a version the history already holds under another
                    // timestamp.
                    for stored in localEntry.history + additions {
                        guard try hasEqualContent(stored, loser) else { continue }
                        alreadyStored = true
                        break
                    }
                }
                if !alreadyStored { additions.append(loser) }
            }

            guard !additions.isEmpty else { return localEntry.history }

            // KeePassXC keys its union by timestamp and emits it ascending; the
            // oracle tests compare history order, so match it once history
            // actually merges.
            let union = (localEntry.history.map { $0.cloneForHistory() } + additions)
                .enumerated()
                .sorted { lhs, rhs in
                    switch (lhs.element.lastModificationTime, rhs.element.lastModificationTime) {
                    case let (left?, right?):
                        let leftKey = KDBXMerger.truncatedToSeconds(left)
                        let rightKey = KDBXMerger.truncatedToSeconds(right)
                        return leftKey == rightKey ? lhs.offset < rhs.offset : leftKey < rightKey
                    case (nil, _?): return true
                    case (_?, nil): return false
                    case (nil, nil): return lhs.offset < rhs.offset
                    }
                }
                .map(\.element)

            return EntryHistoryTrimmer.trimmed(union, meta: meta, sessionKey: sessionKey)
        }

        /// Counted after trimming: a version the limits discard again on every
        /// merge is not a change.
        private func addedHistoryCount(from existing: [KPEntry], to merged: [KPEntry]) -> Int {
            let existingKeys = Set(existing.map(historyKey))
            return merged.filter { !existingKeys.contains(historyKey(of: $0)) }.count
        }

        private func historyKey(of entry: KPEntry) -> Date? {
            entry.lastModificationTime.map(KDBXMerger.truncatedToSeconds)
        }

        // MARK: Deletions

        /// Union of both sides' tombstones, deduped by UUID keeping the
        /// earliest deletion time (KeePassXC's rule, and our test oracle),
        /// applied post-order so a group is only judged once its children are.
        private func applyDeletions() {
            var deletionTimes: [UUID: Date] = [:]
            var order: [UUID] = []
            for tombstone in local.meta.deletedObjects + remote.meta.deletedObjects {
                if let existing = deletionTimes[tombstone.uuid] {
                    deletionTimes[tombstone.uuid] = min(existing, tombstone.deletionTime)
                } else {
                    deletionTimes[tombstone.uuid] = tombstone.deletionTime
                    order.append(tombstone.uuid)
                }
            }

            /// An object edited strictly after its deletion time comes back and
            /// takes its tombstone with it; otherwise it dies and the tombstone
            /// stays, so the deletion reaches a third replica.
            func survivesDeletion(id: UUID, lastModificationTime: Date?) -> Bool {
                guard let deletionTime = deletionTimes[id] else { return true }
                guard KDBXMerger.isNewer(lastModificationTime, than: deletionTime) else { return false }
                deletionTimes[id] = nil
                return true
            }

            func visit(_ group: KPGroup) {
                for child in group.groups { visit(child) }

                group.entries.removeAll { entry in
                    guard deletionTimes[entry.id] != nil else { return false }
                    guard !survivesDeletion(id: entry.id, lastModificationTime: entry.lastModificationTime) else {
                        return false
                    }
                    entryOwnerByID[entry.id] = nil
                    summary.deletionsApplied += 1
                    return true
                }

                group.groups.removeAll { child in
                    guard deletionTimes[child.id] != nil else { return false }
                    guard !survivesDeletion(id: child.id, lastModificationTime: child.lastModificationTime) else {
                        return false
                    }
                    // A group dies only once it is empty; a surviving child
                    // keeps its parent alive, tombstone and all.
                    guard child.entries.isEmpty, child.groups.isEmpty else { return false }
                    groupsByID[child.id] = nil
                    parentByGroupID[child.id] = nil
                    summary.deletionsApplied += 1
                    return true
                }
            }
            visit(root)

            meta.deletedObjects = order.compactMap { uuid in
                deletionTimes[uuid].map { KPDeletedObject(uuid: uuid, deletionTime: $0) }
            }

            let localIDs = Set(local.meta.deletedObjects.map(\.uuid))
            let mergedIDs = Set(meta.deletedObjects.map(\.uuid))
            summary.tombstonesDropped = localIDs.subtracting(mergedIDs).count
            summary.tombstonesAdded = mergedIDs.subtracting(localIDs).count
        }

        // MARK: Meta

        private func noteRemoteIconReference(_ uuid: UUID?) {
            guard let uuid else { return }
            remoteIconReferences.insert(uuid)
        }

        /// Local Meta survives the merge except for the two things that would
        /// otherwise leave merged content stranded: a recycle-bin UUID when
        /// local has none (the bin group itself arrives through the tree walk,
        /// and without the UUID nothing would recognize it as a bin), and the
        /// custom icons that merged content points at, copied in through the
        /// same splice the icon editor uses.
        private func mergeMeta() {
            if meta.recycleBinUUID == nil, let remoteBin = remote.meta.recycleBinUUID {
                meta.recycleBinUUID = remoteBin
                meta.hasRecycleBinUUIDElement = true
            }

            var live: Set<UUID> = []
            func visit(_ group: KPGroup) {
                if let uuid = group.customIconUUID { live.insert(uuid) }
                for entry in group.entries {
                    if let uuid = entry.customIconUUID { live.insert(uuid) }
                }
                for child in group.groups { visit(child) }
            }
            visit(root)

            for uuid in remoteIconReferences.intersection(live).sorted(by: { $0.uuidString < $1.uuidString })
            where meta.customIcons[uuid] == nil {
                guard let imageData = remote.meta.customIcons[uuid],
                      let spliced = CustomIconXML.adding(uuid: uuid, imageData: imageData, to: meta.unknownXML)
                else {
                    // A reference with no icon behind it renders as the default
                    // icon in every client — cosmetic, so it must not cost the
                    // user the merge.
                    summary.danglingIconReferences += 1
                    continue
                }
                meta.unknownXML = spliced
                meta.customIcons[uuid] = imageData
                summary.customIconsSpliced += 1
            }
        }

        // MARK: Content equality

        /// Whether two versions of an entry hold the same content.
        ///
        /// Identity, times and history are excluded: they say *which* version
        /// this is, not what it holds. Protected values are compared in
        /// plaintext — sealed bytes carry a fresh nonce each time, so equal
        /// secrets never have equal ciphertext.
        private func hasEqualContent(_ lhs: KPEntry, _ rhs: KPEntry) throws -> Bool {
            guard lhs.title == rhs.title,
                  lhs.username == rhs.username,
                  lhs.url == rhs.url,
                  lhs.notes == rhs.notes,
                  lhs.iconID == rhs.iconID,
                  lhs.customIconUUID == rhs.customIconUUID,
                  lhs.tags == rhs.tags,
                  lhs.hasTagsElement == rhs.hasTagsElement,
                  lhs.customFields == rhs.customFields,
                  lhs.otpURL == rhs.otpURL,
                  lhs.expires == rhs.expires,
                  sameInstant(lhs.expiryTime, rhs.expiryTime),
                  lhs.protectedStringKeys == rhs.protectedStringKeys,
                  lhs.attachments == rhs.attachments,
                  lhs.unknownXML == rhs.unknownXML
            else { return false }

            guard try plaintext(lhs.password) == plaintext(rhs.password),
                  try plaintext(lhs.passkeyPrivateKey) == plaintext(rhs.passkeyPrivateKey)
            else { return false }

            return try hasEqualTOTP(lhs.totpConfig, rhs.totpConfig)
        }

        private func hasEqualTOTP(_ lhs: TOTPConfig?, _ rhs: TOTPConfig?) throws -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (nil, _), (_, nil): return false
            case let (left?, right?):
                guard left.period == right.period,
                      left.digits == right.digits,
                      left.algorithm == right.algorithm,
                      left.keeOTPSource == right.keeOTPSource
                else { return false }
                return try plaintext(left.secret) == plaintext(right.secret)
                    && plaintext(left.decodedSecret) == plaintext(right.decodedSecret)
            }
        }

        private func sameInstant(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case let (left?, right?):
                return KDBXMerger.truncatedToSeconds(left) == KDBXMerger.truncatedToSeconds(right)
            default: return false
            }
        }

        private func plaintext(_ value: EncryptedValue?) throws -> Data? {
            guard let value else { return nil }
            do {
                return try value.decryptData(using: sessionKey)
            } catch {
                throw MergeError.protectedValueUnreadable
            }
        }
    }
}
