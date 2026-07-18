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
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    @State private var pendingEntryDeletion: PendingEntryDeletion?

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView.search
        } else {
            List(entries) { entry in
                entryRow(for: entry)
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

    @ViewBuilder
    private func entryRow(for entry: KPEntry) -> some View {
        Group {
            if let onSelectEntry {
                Button {
                    onSelectEntry(entry)
                } label: {
                    EntryRow(entry: entry, customIconData: viewModel.customIconData(for: entry))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.entry.navlink")
            } else {
                NavigationLink(value: entry) {
                    EntryRow(entry: entry, customIconData: viewModel.customIconData(for: entry))
                }
                .accessibilityIdentifier("search.entry.navlink")
            }
        }
        .macHoverHighlight()
        .contextMenu {
            if viewModel.isReadOnly == false {
                Button(deletionTitle(for: entry), role: .destructive) {
                    pendingEntryDeletion = PendingEntryDeletion(
                        entryID: entry.id,
                        sendToRecycleBin: sendDeletionToRecycleBin(for: entry)
                    )
                }
                .accessibilityIdentifier(
                    sendDeletionToRecycleBin(for: entry)
                        ? "entry-row.delete-context"
                        : "entry-row.delete-permanent"
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if viewModel.isReadOnly == false {
                Button(deletionTitle(for: entry), role: .destructive) {
                    pendingEntryDeletion = PendingEntryDeletion(
                        entryID: entry.id,
                        sendToRecycleBin: sendDeletionToRecycleBin(for: entry)
                    )
                }
                .accessibilityIdentifier("entry-row.delete-swipe")
            }
        }
    }

    private func deletionTitle(for entry: KPEntry) -> String {
        sendDeletionToRecycleBin(for: entry) ? "Delete" : "Delete Permanently"
    }

    private func sendDeletionToRecycleBin(for entry: KPEntry) -> Bool {
        viewModel.isEntryInRecycleBin(entryID: entry.id) == false
    }
}
