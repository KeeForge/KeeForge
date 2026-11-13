#if os(macOS)
import AppKit
import SwiftUI

struct RegularDatabaseWorkspaceView: View {
    let viewModel: DatabaseViewModel
    @Environment(MacWorkspacePresentation.self) private var presentation

    var body: some View {
        MacDatabaseWorkspaceView(viewModel: viewModel, presentation: presentation)
    }
}

struct MacDatabaseWorkspaceView: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation
    @Environment(MacWindowWorkspace.self) private var workspace
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        MacWorkspacePresentationHost(viewModel: viewModel, presentation: presentation) {
            NavigationStack {
                Group {
                    if let controller = workspace.splitViewController, controller.session === viewModel {
                        MacWorkspaceSplitView(controller: controller)
                            .id(ObjectIdentifier(controller))
                    }
                }
                .searchable(text: $viewModel.searchText, prompt: "Search entries")
                .searchFocused($isSearchFieldFocused)
                .onChange(of: viewModel.workspace.searchFocusRequestID) { _, _ in
                    isSearchFieldFocused = true
                }
                .toolbar { macToolbar }
            }
        }
    }

    /// Database-scoped actions sit in the `.navigation` region, beside the lock
    /// button and over the group/entry columns. `.primaryAction` would park
    /// them at the trailing edge, above the entry detail — next to the detail's
    /// own Edit button, where they read as actions on the selected entry.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                NSApp.sendAction(#selector(MainWindowController.toggleSidebar(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show Sidebar")
            .accessibilityLabel("Show Sidebar")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                viewModel.lockRequest(manuallyTriggered: true)
            } label: {
                Image(systemName: "lock.fill")
            }
            .help("Lock Database")
            .accessibilityLabel("Lock Database")
            .accessibilityIdentifier("lock.button")
        }

        ToolbarItemGroup(placement: .navigation) {
            if CloudSyncControls.isVisible(for: viewModel) {
                CloudSyncControls(viewModel: viewModel)
            }

            if viewModel.isReadOnly {
                ReadOnlyIndicator(explanation: viewModel.readOnlyExplanation)
            } else {
                Menu {
                    Button("New Entry", systemImage: "doc.badge.plus") {
                        viewModel.requestNewEntry()
                    }
                    Button("New Group", systemImage: "folder.badge.plus") {
                        presentation.beginNewGroup()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .help("Add Entry or Group")
                .accessibilityLabel("Add Entry or Group")
                .accessibilityIdentifier("entry-list.add-entry")
            }

            Menu {
                Picker("Sort By", selection: $viewModel.sortOrder) {
                    ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                Picker("Sort Direction", selection: $viewModel.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .help("Sort")
            .accessibilityLabel("Sort")
            .accessibilityIdentifier("sort.menu")

            Button {
                presentation.isShowingDatabaseDetails = true
            } label: {
                Image(systemName: "info.circle")
            }
            .help("Database Details")
            .accessibilityLabel("Database Details")
            .accessibilityIdentifier("database-details.button")

            Button {
                NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings.button")
        }

        ToolbarItem(placement: .primaryAction) {
            if let entryID = viewModel.workspace.selectedEntryID,
               viewModel.entry(withID: entryID) != nil,
               viewModel.isReadOnly == false {
                Button("Edit") {
                    presentation.beginEntryEdit(entryID: entryID, in: viewModel)
                }
                .disabled(viewModel.canEditSelectedEntry == false)
                .accessibilityIdentifier("entry-detail.edit")
            }
        }
    }

}
#endif
