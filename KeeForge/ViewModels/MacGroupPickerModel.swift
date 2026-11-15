#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class MacGroupPickerModel {
    enum Purpose { case move(PendingMove), autoFillDestination, importDestination }
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let depth: Int
        let iconID: Int
        let customIconData: Data?
        let isCurrent: Bool
        var isSelectable: Bool { !isCurrent }
    }
    let rows: [Row]
    let title: String
    let itemName: String
    let itemIconID: Int
    let itemCustomIconData: Data?
    let currentPath: String?
    var selection: UUID?
    var canConfirm: Bool { rows.contains { $0.id == selection && $0.isSelectable } }
    var confirmTitle: String

    init(purpose: Purpose, database: DatabaseViewModel, current: UUID? = nil) {
        let options: [DatabaseViewModel.MoveDestinationOption]
        var itemGroup: KPGroup?
        var itemEntry: KPEntry?
        switch purpose {
        case .move(let pending):
            options = pending.destinationOptions(viewModel: database)
            if case .restore = pending {
                title = String(localized: "Restore to Group")
                confirmTitle = String(localized: "Restore")
            } else {
                title = String(localized: "Move to Group")
                confirmTitle = String(localized: "Move")
            }
            switch pending {
            case .entry(let id), .restore(.entry(let id)): itemEntry = database.entry(withID: id)
            case .group(let id), .restore(.group(let id)): itemGroup = database.group(withID: id)
            case .entries: break
            }
            if case .entries(let ids) = pending {
                itemName = String(localized: "\(ids.count) Entries Selected")
            } else {
                itemName = itemGroup?.name ?? itemEntry?.title ?? ""
            }
        case .autoFillDestination, .importDestination:
            options = database.groupDestinationOptions(currentGroupID: current)
            title = String(localized: "Select Group")
            confirmTitle = String(localized: "Select")
            itemName = ""
        }
        itemIconID = itemGroup?.iconID ?? itemEntry?.iconID ?? 48
        itemCustomIconData = itemGroup.flatMap(database.customIconData(for:)) ?? itemEntry.flatMap(database.customIconData(for:))
        rows = options.map { option in
            let group = database.group(withID: option.id)
            return Row(id: option.id, name: option.name, depth: option.depth, iconID: group?.iconID ?? 48,
                       customIconData: group.flatMap(database.customIconData(for:)), isCurrent: current.map { $0 == option.id } ?? option.isCurrentParent)
        }
        var ancestors: [String] = []
        var path: String?
        for option in options {
            ancestors = Array(ancestors.prefix(option.depth))
            ancestors.append(option.name)
            if current.map({ $0 == option.id }) ?? option.isCurrentParent { path = (ancestors.count > 1 ? Array(ancestors.dropFirst()) : ancestors).joined(separator: " › ") }
        }
        currentPath = path
    }

    func confirmOnDoubleClick(_ id: UUID) -> UUID? {
        guard rows.contains(where: { $0.id == id && $0.isSelectable }) else { return nil }
        selection = id
        return id
    }
}
#endif
