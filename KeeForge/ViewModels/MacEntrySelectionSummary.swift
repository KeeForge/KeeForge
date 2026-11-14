#if os(macOS)
import Foundation

/// What the Mac detail column shows while several entries are picked:
/// "3 Entries Selected", their names and shared group, and whether its Move to
/// Group… and Delete buttons apply.
struct MacEntrySelectionSummary: Equatable {
    static let iconLimit = 3

    let title: String
    let subtitle: String
    /// The first entries in display order, whose icons the summary fans out.
    let iconEntryIDs: [UUID]
    let canMove: Bool
    let canDelete: Bool

    @MainActor
    static func make(session: DatabaseViewModel) -> MacEntrySelectionSummary? {
        guard let picked = session.workspace.entrySelection, picked.isEmpty == false else { return nil }
        let entries = session.sortedEntries(picked.compactMap { session.entry(withID: $0) })
        guard entries.isEmpty == false else { return nil }
        let names = ListFormatter.localizedString(byJoining: entries.map {
            $0.title.isEmpty ? String(localized: "(untitled)") : $0.title
        })
        let paths = MacEntryListSnapshot.folderPaths(session: session, includingRoot: false)
        let groups = Set(entries.map { session.parentGroupID(forEntryID: $0.id) })
        let sharedPath = groups.count == 1 ? entries.first.flatMap { paths[$0.id] } : nil
        let isEditable = session.state == .unlocked && session.isReadOnly == false && session.isSaving == false
        let deletesPicks = if case .entries = session.deletableSelection { true } else { false }
        return MacEntrySelectionSummary(
            title: String(localized: "\(entries.count) Entries Selected"),
            subtitle: [names, sharedPath].compactMap(\.self).joined(separator: MacEntryListSnapshot.headerSeparator),
            iconEntryIDs: entries.prefix(iconLimit).map(\.id),
            canMove: isEditable,
            canDelete: isEditable && deletesPicks
        )
    }
}
#endif
