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
    @AppStorage("macWorkspace.sidebarWidth") private var macSidebarWidth = MacSidebarWidthSampler.idealWidth
    @State private var macSidebarWidthSampler = MacSidebarWidthSampler()
    @State private var macSplitWidth: Double?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        MacWorkspacePresentationHost(viewModel: viewModel, presentation: presentation) {
            splitView.navigationSplitViewStyle(.balanced)
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            MacWorkspaceSidebarColumn(viewModel: viewModel, presentation: presentation)
                .onGeometryChange(for: Double.self) { proxy in
                    Double(proxy.size.width)
                } action: { width in
                    // Deferred so the split view's width from the same layout
                    // pass is known, whichever geometry change fires first.
                    Task { @MainActor in
                        guard viewModel.state == .unlocked else { return }
                        if let preferred = macSidebarWidthSampler.preferredWidth(sidebarWidth: width, splitWidth: macSplitWidth) {
                            macSidebarWidth = preferred
                        }
                    }
                }
                // Outermost: wrapped by the geometry observer, the split view
                // ignores the column width (144 pt on macOS 27.0.1).
                .navigationSplitViewColumnWidth(
                    min: MacSidebarWidthSampler.minimumWidth,
                    ideal: macSidebarWidth,
                    max: MacSidebarWidthSampler.maximumWidth
                )
        } content: {
            MacWorkspaceEntriesColumn(viewModel: viewModel, presentation: presentation)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            MacWorkspaceDetailColumn(viewModel: viewModel, presentation: presentation)
        }
        .onGeometryChange(for: Double.self) { proxy in
            Double(proxy.size.width)
        } action: { width in
            macSplitWidth = width
        }
        .navigationTitle(viewModel.databaseDisplayName)
        .searchable(text: $viewModel.searchText, prompt: "Search entries")
        .searchFocused($isSearchFieldFocused)
        .onChange(of: viewModel.workspace.searchFocusRequestID) { _, _ in
            isSearchFieldFocused = true
        }
        .toolbar { macToolbar }
        .onAppear {
            // The tag check keeps a re-fired onAppear from silently clearing a
            // sidebar tag selection — selecting a group deselects the tag.
            if viewModel.workspace.selectedGroupID == nil, viewModel.workspace.selectedTag == nil {
                viewModel.workspace.selectedGroupID = viewModel.visibleRootGroupID
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
    }

}
#endif
