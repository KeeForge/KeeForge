import SwiftUI

/// Identifies the entry whose icon picker is showing, so `sheet(item:)` has an
/// `Identifiable` to key on.
struct PendingEntryIconChange: Identifiable {
    let entryID: UUID

    var id: UUID { entryID }
}

/// The Change Icon item of an entry row's context menu. Hands the pending
/// change back rather than presenting, because the sheet's host differs per
/// list.
struct EntryRowChangeIconAction: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel
    let onChangeIcon: (PendingEntryIconChange) -> Void

    var body: some View {
        if EntryRowMoveAction.isAvailable(entryID: entryID, viewModel: viewModel) {
            Button("Change Icon", systemImage: "photo") {
                onChangeIcon(PendingEntryIconChange(entryID: entryID))
            }
            .accessibilityIdentifier("entry-row.change-icon-context")
        }
    }
}

/// The entry icon picker, applying and saving the pick. Shared by entry detail
/// and the row menus so both write the icon the same way.
struct EntryIconChangeSheet: View {
    let entryID: UUID
    let viewModel: DatabaseViewModel

    var body: some View {
        // Resolved here, not when the menu was tapped, so the picker opens on
        // the icon the entry has now.
        if let entry = viewModel.entry(withID: entryID) {
            EntryIconPickerView(
                entryTitle: entry.title,
                selection: Self.iconSelection(of: entry),
                customIcons: viewModel.customIcons,
                databaseViewModel: viewModel,
                canDownloadFavicon: viewModel.canDownloadFavicon(forEntryID: entryID),
                onSelect: changeIcon,
                onDownloadFavicon: {
                    try await viewModel.downloadFavicon(forEntryID: entryID)
                    // Outside the picker's cancellable task on purpose: the
                    // icon is in the draft by now, and closing the sheet
                    // mid-save would leave it unwritten.
                    await Task { await viewModel.saveHandlingError() }.value
                }
            )
        }
    }

    /// A `<CustomIconUUID>` outranks `<IconID>` in KeePass, so the custom icon
    /// is the one the picker opens on, as it is the one shown.
    private static func iconSelection(of entry: KPEntry) -> EntryIconSelection {
        if let uuid = entry.customIconUUID {
            return .custom(uuid: uuid)
        }
        return .standard(iconID: entry.iconID)
    }

    private func changeIcon(_ icon: EntryIconSelection) {
        do {
            try viewModel.setEntryIcon(icon, entryID: entryID)
            Task {
                await viewModel.saveHandlingError()
            }
        } catch {
            viewModel.presentSaveError(error)
        }
    }
}
