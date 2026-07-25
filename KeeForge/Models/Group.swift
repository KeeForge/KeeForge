import Foundation

/// A KDBX tri-state group flag, as used by `<EnableSearching>` and
/// `<EnableAutoType>`: an explicit yes/no, or `inherit` (serialized as `null`)
/// meaning "take the parent's answer".
enum KPInheritableBool: Sendable, Hashable {
    case inherit
    case enabled
    case disabled

    /// `nil` for `inherit`, so callers can fall back to the parent value with
    /// a single `??`.
    var boolValue: Bool? {
        switch self {
        case .inherit: return nil
        case .enabled: return true
        case .disabled: return false
        }
    }

    /// Parses a KDBX element body. Returns `nil` for anything unrecognized so
    /// the caller can leave the source element in `unknownXML` untouched
    /// instead of rewriting it into something the original app didn't write.
    static func parse(_ rawValue: String) -> KPInheritableBool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "null": return .inherit
        case "true": return .enabled
        case "false": return .disabled
        default: return nil
        }
    }

    /// KeePass casing: `True`/`False` for the booleans, lowercase `null` for inherit.
    var xmlValue: String {
        switch self {
        case .inherit: return "null"
        case .enabled: return "True"
        case .disabled: return "False"
        }
    }
}

/// Represents a KeePass group (folder) containing entries and subgroups
final class KPGroup: Identifiable, @unchecked Sendable {
    var id: UUID
    var name: String
    var iconID: Int
    /// UUID referencing `Meta/CustomIcons`, when the group uses a custom icon.
    /// Read-only display copy: the source `<CustomIconUUID>` element stays in
    /// `unknownXML` so the writer round-trips it verbatim.
    var customIconUUID: UUID?
    var entries: [KPEntry]
    var groups: [KPGroup]
    var isExpanded: Bool
    /// KDBX `<EnableSearching>`. `nil` means the source group had no such
    /// element at all, which behaves like `.inherit` but is kept distinct so
    /// the writer doesn't add an element the original app never wrote.
    var searchingEnabled: KPInheritableBool?
    var creationTime: Date?
    var lastModificationTime: Date?
    /// UUID of the Recycle Bin group (only meaningful on the root group)
    var recycleBinUUID: UUID?
    var unknownXML: OpaqueXMLNodes

    init(
        id: UUID = UUID(),
        name: String,
        iconID: Int = 48,
        customIconUUID: UUID? = nil,
        entries: [KPEntry] = [],
        groups: [KPGroup] = [],
        isExpanded: Bool = true,
        searchingEnabled: KPInheritableBool? = nil,
        creationTime: Date? = nil,
        lastModificationTime: Date? = nil,
        recycleBinUUID: UUID? = nil,
        unknownXML: OpaqueXMLNodes = .empty
    ) {
        self.id = id
        self.name = name
        self.iconID = iconID
        self.customIconUUID = customIconUUID
        self.entries = entries
        self.groups = groups
        self.isExpanded = isExpanded
        self.searchingEnabled = searchingEnabled
        self.creationTime = creationTime
        self.lastModificationTime = lastModificationTime
        self.recycleBinUUID = recycleBinUUID
        self.unknownXML = unknownXML
    }

    /// Recursively find all entries in this group and subgroups
    var allEntries: [KPEntry] {
        entries + groups.flatMap(\.allEntries)
    }

    /// Recursively find all entries, excluding a specific group and its subgroups
    func allEntries(excludingGroupID groupID: UUID) -> [KPEntry] {
        guard id != groupID else { return [] }
        return entries + groups.flatMap { $0.allEntries(excludingGroupID: groupID) }
    }

    /// Recursively collects the entries AutoFill is allowed to offer, honouring
    /// `<EnableSearching>` down the tree.
    ///
    /// A group with `.disabled` contributes nothing, and its subgroups inherit
    /// that unless they override it with an explicit `.enabled` — matching how
    /// KeePass resolves the flag. Groups without the element (or with
    /// `.inherit`) take the parent's answer; the root defaults to enabled.
    ///
    /// In-app browsing and the in-app search deliberately keep using
    /// `allEntries`: hiding a group from AutoFill is not meant to hide it from
    /// the person who owns the database.
    func autoFillEntries(
        excludingGroupID excludedGroupID: UUID? = nil,
        inheritedSearchingEnabled: Bool = true
    ) -> [KPEntry] {
        guard id != excludedGroupID else { return [] }

        let isSearchable = searchingEnabled?.boolValue ?? inheritedSearchingEnabled
        let ownEntries = isSearchable ? entries : []

        return ownEntries + groups.flatMap {
            $0.autoFillEntries(
                excludingGroupID: excludedGroupID,
                inheritedSearchingEnabled: isSearchable
            )
        }
    }

    /// Returns a new version of this group with one direct child group replaced.
    func replacingChildGroup(_ updatedGroup: KPGroup) -> KPGroup? {
        guard let index = groups.firstIndex(where: { $0.id == updatedGroup.id }) else {
            return nil
        }

        var updatedGroups = groups
        updatedGroups[index] = updatedGroup

        return KPGroup(
            id: id,
            name: name,
            iconID: iconID,
            customIconUUID: customIconUUID,
            entries: entries,
            groups: updatedGroups,
            isExpanded: isExpanded,
            searchingEnabled: searchingEnabled,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            recycleBinUUID: recycleBinUUID,
            unknownXML: unknownXML
        )
    }

    /// System icon name based on KeePass icon ID
    var systemIconName: String {
        KPEntry.systemIconName(for: iconID, fallback: "folder.fill")
    }
}
