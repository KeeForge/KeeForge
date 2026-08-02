import Foundation
import Observation

/// Form state for the group editor, mirroring `EntryEditViewModel`: it owns the
/// user's in-flight edits and emits one `GroupDraftPayload`, while
/// `DatabaseViewModel` owns applying and saving it.
@MainActor @Observable
final class GroupEditViewModel {
    let id = UUID()
    let groupID: UUID

    struct Snapshot: Equatable, Sendable {
        var name: String
        var tags: [String]
        var notes: String
        var iconID: Int
        var isHiddenFromAutoFill: Bool
    }

    var name: String
    /// Tags the user has committed, rendered as removable pills — exact-string
    /// identity and arrival order, exactly like the entry editor's.
    private(set) var tags: [String]
    /// The tag being typed, not yet committed to a pill. It still counts toward
    /// the payload and toward suggestion exclusion.
    var pendingTagText: String = ""
    var notes: String
    var iconID: Int
    /// Whether search and AutoFill skip this group. Seeded from the *effective*
    /// exclusion, so a group hidden by an ancestor opens with the switch on.
    var isHiddenFromAutoFill: Bool

    /// True when the group carries no `<EnableSearching>` of its own and is
    /// hidden because an ancestor is. The form explains that rather than showing
    /// a switch that looks like it is already doing the work.
    let isExclusionInherited: Bool

    /// The group's stored `<EnableSearching>` state, including "no element at
    /// all" (`nil`). Replayed verbatim when the user leaves the switch alone —
    /// `GroupDraftPayload.searchingEnabled` is absolute, not a delta, so
    /// anything else would silently rewrite or clear the flag.
    private let originalSearchingEnabled: InheritableBoolPayload?
    private let originalSnapshot: Snapshot
    /// The database's distinct tags as of the moment the editor opened, in
    /// display order. A snapshot on purpose, like the entry editor's.
    private let knownTags: [String]

    init(
        groupID: UUID,
        name: String = "",
        tags: [String] = [],
        notes: String = "",
        iconID: Int = 48,
        searchingEnabled: InheritableBoolPayload? = nil,
        isHiddenFromAutoFill: Bool = false,
        isExclusionInherited: Bool = false,
        knownTags: [String] = []
    ) {
        self.groupID = groupID
        self.name = name
        self.tags = TagNormalizer.tags(from: tags)
        self.notes = notes
        self.iconID = iconID
        self.isHiddenFromAutoFill = isHiddenFromAutoFill
        self.isExclusionInherited = isExclusionInherited
        self.originalSearchingEnabled = searchingEnabled
        self.knownTags = knownTags
        originalSnapshot = Snapshot(
            name: name,
            tags: TagNormalizer.tags(from: tags),
            notes: notes,
            iconID: iconID,
            isHiddenFromAutoFill: isHiddenFromAutoFill
        )
    }

    convenience init(
        editing group: KPGroup,
        isHiddenFromAutoFill: Bool,
        isExclusionInherited: Bool = false,
        knownTags: [String] = []
    ) {
        self.init(
            groupID: group.id,
            name: group.name,
            tags: group.tags,
            notes: group.notes,
            iconID: group.iconID,
            searchingEnabled: Self.payload(for: group.searchingEnabled),
            isHiddenFromAutoFill: isHiddenFromAutoFill,
            isExclusionInherited: isExclusionInherited,
            knownTags: knownTags
        )
    }

    var isDirty: Bool {
        currentSnapshot != originalSnapshot
    }

    /// A group must keep a name — the draft layer rejects an empty one, so the
    /// form refuses to submit it rather than surfacing that as an error.
    var canSave: Bool {
        trimmedName.isEmpty == false && isDirty
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The known tags worth offering: `knownTags` minus the tags this group
    /// already carries, committed pills and the pending token alike. Re-read on
    /// every access so a chip leaves the strip the moment its tag lands and
    /// comes back when the pill is removed.
    ///
    /// Unlike the entry editor there is no inherited-tag exclusion: a group's
    /// own `<Tags>` are what it grants its descendants, and re-stating an
    /// ancestor's tag on a child group is a legitimate thing to author.
    var tagSuggestions: [String] {
        let appliedTags = Set(normalizedTags())
        return knownTags.filter { appliedTags.contains($0) == false }
    }

    func makeDraftPayload() -> GroupDraftPayload {
        GroupDraftPayload(
            name: trimmedName,
            tags: normalizedTags(),
            notes: notes,
            iconID: iconID,
            searchingEnabled: resolvedSearchingEnabled()
        )
    }

    /// Commits what is in the field, splitting it on every separator.
    ///
    /// Never triggered from the field's setter: rewriting a `TextField`'s bound
    /// text while the user is typing races the keystrokes still in flight and
    /// silently loses them. Return, or tapping a suggestion, is a pause in
    /// typing, so rewriting is safe there.
    func commitPendingTag() {
        appendTags(TagNormalizer.tags(fromText: pendingTagText))
        pendingTagText = ""
    }

    /// Adds `tag` as a committed pill, exactly as typing it and pressing Return
    /// would. A half-typed token is committed first, so pills end up in the
    /// order the user acted.
    func appendTagSuggestion(_ tag: String) {
        commitPendingTag()
        appendTags([tag])
    }

    /// Drops a committed pill. Unknown tags are ignored, so a stale render
    /// cannot remove something the user already removed.
    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    /// Dedupes against the committed pills only, never `normalizedTags()`:
    /// every caller is in the act of turning the pending token into a pill, and
    /// counting that token as already-applied would drop it on the floor.
    private func appendTags(_ newTags: [String]) {
        guard newTags.isEmpty == false else { return }

        var applied = Set(tags)
        for tag in newTags where applied.insert(tag).inserted {
            tags.append(tag)
        }
    }

    private var currentSnapshot: Snapshot {
        Snapshot(
            name: name,
            // The pending token counts: typing a tag and saving without
            // committing it must read as a change, and must save the tag.
            tags: normalizedTags(),
            notes: notes,
            iconID: iconID,
            isHiddenFromAutoFill: isHiddenFromAutoFill
        )
    }

    /// The committed pills plus whatever is still being typed, so an
    /// uncommitted token is never silently dropped by saving.
    private func normalizedTags() -> [String] {
        TagNormalizer.tags(from: tags + [pendingTagText])
    }

    /// An untouched switch replays the stored value — including "no element at
    /// all". A flipped one writes an explicit `True`/`False`, the same way
    /// `DatabaseViewModel.setGroupExcludedFromAutoFill` does, so a group inside
    /// a hidden parent can actually be shown again.
    private func resolvedSearchingEnabled() -> InheritableBoolPayload? {
        guard isHiddenFromAutoFill != originalSnapshot.isHiddenFromAutoFill else {
            return originalSearchingEnabled
        }
        return isHiddenFromAutoFill ? .disabled : .enabled
    }

    private static func payload(for value: KPInheritableBool?) -> InheritableBoolPayload? {
        switch value {
        case .none: return nil
        case .inherit: return .inherit
        case .enabled: return .enabled
        case .disabled: return .disabled
        }
    }
}

extension GroupEditViewModel: Hashable {
    nonisolated static func == (lhs: GroupEditViewModel, rhs: GroupEditViewModel) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// `id` is a stable `UUID`, so identity-based `Identifiable` is sound; used by
/// `sheet(item:)` and `navigationDestination(item:)`.
extension GroupEditViewModel: Identifiable {
}
