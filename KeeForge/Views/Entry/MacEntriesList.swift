#if os(macOS)
import SwiftUI

/// A macOS entry list backed by a native `List(selection:)` bound to
/// `DatabaseViewModel.selectedEntryID`, so arrow keys, type-select, and the
/// focus ring come from AppKit rather than being hand-rolled.
///
/// Search results and the tag browser use this instead of the shared
/// `EntryListView`, whose rows are buttons that swallow the click the list
/// needs to move its selection. The group column (`MacEntriesColumn`) shares
/// the row through `MacEntryRow` but keeps its own shell, because it raises
/// move and delete to the workspace — the sidebar and the menu-bar commands
/// share those hosts. Here the hosts are list-scoped, the way `EntryListView`
/// hosts them: outside the rows, so deleting the last entry cannot strand a
/// presentation.
struct MacEntriesList: View {
    @Bindable var viewModel: DatabaseViewModel
    let entries: [KPEntry]
    /// These lists draw entries from more than one group, so each row says
    /// where its entry lives — matching what `EntryListView` shows on iOS.
    var showsFolderPath: Bool = true
    /// Kept as the iOS lists' identifier so both platforms' UI tests match the
    /// same rows; the group column uses `entry.navlink`.
    var rowIdentifier: String = "search.entry.navlink"

    @FocusState private var isListFocused: Bool
    @State private var pendingDeletion: PendingDeletion?
    @State private var pendingMove: PendingMove?
    /// The prefilled New Entry form a Duplicate raised. Hosted here rather
    /// than raised to the workspace the way the group column does it, because
    /// these lists own their presentations.
    @State private var duplicateEditor: EntryEditViewModel?

    var body: some View {
        List(entries, selection: $viewModel.selectedEntryID) { entry in
            MacEntryRow(
                entry: entry,
                viewModel: viewModel,
                showsFolderPath: showsFolderPath,
                rowIdentifier: rowIdentifier,
                isListFocused: $isListFocused,
                onOpenEntry: openEntry,
                onRequestMove: { pendingMove = $0 },
                onRequestDuplicate: { duplicateEditor = $0 },
                onRequestDeletion: { pendingDeletion = $0 }
            )
        }
        .listStyle(.inset)
        .focused($isListFocused)
        .onKeyPress(.return) {
            guard let entryID = viewModel.selectedEntryID else { return .ignored }
            openEntry(entryID)
            return .handled
        }
        .alert(item: $pendingDeletion) { $0.confirmationAlert(viewModel: viewModel) }
        .sheet(item: $pendingMove) { pending in
            MoveToGroupPickerView(
                options: pending.destinationOptions(viewModel: viewModel)
            ) { destinationGroupID in
                pending.apply(destinationGroupID: destinationGroupID, viewModel: viewModel)
            }
        }
        .sheet(item: $duplicateEditor) { formViewModel in
            NavigationStack {
                EntryEditView(
                    formViewModel: formViewModel,
                    databaseViewModel: viewModel
                ) { _ in
                    duplicateEditor = nil
                }
            }
            .macSheetFrame()
        }
    }

    /// Routed through the view model's Edit Entry seam rather than a local
    /// sheet, so Return and double-click land on the one editor the workspace
    /// hosts — the same one ⌘E opens.
    private func openEntry(_ entryID: UUID) {
        viewModel.selectedEntryID = entryID
        viewModel.requestEntryEdit()
    }
}

/// One row of a macOS entry list. Shared by `MacEntriesList` and the group
/// column so a right-click offers the same actions wherever an entry is shown.
struct MacEntryRow: View {
    let entry: KPEntry
    @Bindable var viewModel: DatabaseViewModel
    var showsFolderPath: Bool = false
    var rowIdentifier: String = "entry.navlink"
    @FocusState.Binding var isListFocused: Bool
    let onOpenEntry: (UUID) -> Void
    let onRequestMove: (PendingMove) -> Void
    let onRequestDuplicate: (EntryEditViewModel) -> Void
    let onRequestDeletion: (PendingDeletion) -> Void

    var body: some View {
        EntryRow(
            entry: entry,
            username: viewModel.resolvingFieldReferences(entry.username),
            customIconData: viewModel.customIconData(for: entry),
            folderPath: showsFolderPath ? viewModel.folderPath(forEntryID: entry.id) : nil
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .macSelectableRowHover()
        // Any tap gesture on a row consumes the click the enclosing `List`
        // would have used to move its selection, so the single-click case has
        // to be handled here as well.
        //
        // The double-click must arrive as a *simultaneous* gesture attached
        // after the single tap, not as a second `onTapGesture(count: 2)`
        // before it. Two plain tap gestures compose exclusively: the
        // single-click handler cannot run until SwiftUI has ruled out a second
        // click, which parks selection — and with it the detail pane — behind
        // `NSEvent.doubleClickInterval` (0.5s by default). Measured on this
        // row's shape: 353ms exclusive, 3ms simultaneous.
        .onTapGesture {
            viewModel.selectedEntryID = entry.id
            isListFocused = true
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onOpenEntry(entry.id)
            }
        )
        .accessibilityIdentifier(rowIdentifier)
        .contextMenu {
            EntryRowCopyActions(entry: entry, viewModel: viewModel)

            EntryRowDuplicateAction(entryID: entry.id, viewModel: viewModel) { editor in
                onRequestDuplicate(editor)
            }

            if canMove {
                Button("Move to Group") {
                    onRequestMove(.entry(entry.id))
                }
                .accessibilityIdentifier("entry-row.move-context")
            }

            if viewModel.isReadOnly == false {
                Button(sendToRecycleBin ? "Delete" : "Delete Permanently", role: .destructive) {
                    onRequestDeletion(
                        .entry(
                            PendingEntryDeletion(
                                entryID: entry.id,
                                sendToRecycleBin: sendToRecycleBin
                            )
                        )
                    )
                }
                .accessibilityIdentifier(
                    sendToRecycleBin ? "entry-row.delete-context" : "entry-row.delete-permanent"
                )
            }
        }
    }

    private var sendToRecycleBin: Bool {
        viewModel.isEntryInRecycleBin(entryID: entry.id) == false
    }

    /// Same predicate as the iOS row's `canMoveEntry`: a recycled entry comes
    /// back through the restore flow, not through a move.
    private var canMove: Bool {
        viewModel.isReadOnly == false && sendToRecycleBin
    }
}
#endif
