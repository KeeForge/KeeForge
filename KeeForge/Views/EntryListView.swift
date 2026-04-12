import SwiftUI

struct EntryListView: View {
    struct PendingEntryDeletion: Identifiable {
        let entryID: UUID
        let sendToRecycleBin: Bool

        var id: String {
            "\(entryID.uuidString)-\(sendToRecycleBin)"
        }
    }

    let entries: [KPEntry]
    @Bindable var viewModel: DatabaseViewModel
    @State private var pendingEntryDeletion: PendingEntryDeletion?

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView.search
        } else {
            List(entries) { entry in
                NavigationLink(value: entry) {
                    EntryRow(entry: entry)
                }
                .accessibilityIdentifier("search.entry.navlink")
                .contextMenu {
                    if viewModel.isReadOnly == false {
                        Button("Delete Permanently", role: .destructive) {
                            pendingEntryDeletion = PendingEntryDeletion(
                                entryID: entry.id,
                                sendToRecycleBin: false
                            )
                        }
                        .accessibilityIdentifier("entry-row.delete-permanent")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if viewModel.isReadOnly == false {
                        Button("Delete", role: .destructive) {
                            pendingEntryDeletion = PendingEntryDeletion(
                                entryID: entry.id,
                                sendToRecycleBin: true
                            )
                        }
                        .accessibilityIdentifier("entry-row.delete-swipe")
                    }
                }
            }
            .alert(item: $pendingEntryDeletion) { action in
                Alert(
                    title: Text(action.sendToRecycleBin ? "Delete Entry?" : "Delete Permanently?"),
                    message: Text(action.sendToRecycleBin
                        ? "The entry will be moved to the recycle bin."
                        : "This entry will be removed immediately and cannot be restored from KeeForge."),
                    primaryButton: .destructive(Text(action.sendToRecycleBin ? "Delete" : "Delete Permanently")) {
                        do {
                            try viewModel.deleteEntry(action.entryID, sendToRecycleBin: action.sendToRecycleBin)
                            Task {
                                await viewModel.saveHandlingError()
                            }
                        } catch {
                            viewModel.presentSaveError(error)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}
