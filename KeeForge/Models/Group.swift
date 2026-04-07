import Foundation

/// Represents a KeePass group (folder) containing entries and subgroups
final class KPGroup: Identifiable, @unchecked Sendable {
    var id: UUID
    var name: String
    var iconID: Int
    var entries: [KPEntry]
    var groups: [KPGroup]
    var isExpanded: Bool
    var creationTime: Date?
    var lastModificationTime: Date?
    /// UUID of the Recycle Bin group (only meaningful on the root group)
    var recycleBinUUID: UUID?
    var unknownXML: OpaqueXMLNodes

    init(
        id: UUID = UUID(),
        name: String,
        iconID: Int = 48,
        entries: [KPEntry] = [],
        groups: [KPGroup] = [],
        isExpanded: Bool = true,
        creationTime: Date? = nil,
        lastModificationTime: Date? = nil,
        recycleBinUUID: UUID? = nil,
        unknownXML: OpaqueXMLNodes = .empty
    ) {
        self.id = id
        self.name = name
        self.iconID = iconID
        self.entries = entries
        self.groups = groups
        self.isExpanded = isExpanded
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
            entries: entries,
            groups: updatedGroups,
            isExpanded: isExpanded,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            recycleBinUUID: recycleBinUUID,
            unknownXML: unknownXML
        )
    }

    /// System icon name based on KeePass icon ID
    var systemIconName: String {
        switch iconID {
        case 0: "key.fill"
        case 1: "globe"
        case 2: "exclamationmark.triangle"
        case 3: "server.rack"
        case 48: "folder.fill"
        case 49: "folder.fill"
        default: "folder.fill"
        }
    }
}
