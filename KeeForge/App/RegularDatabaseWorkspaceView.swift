import AuthenticationServices
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct RegularDatabaseWorkspaceView: View {
    @Bindable var viewModel: DatabaseViewModel
    @State private var navigationPath: [UUID] = []
    @State private var presentedSaveError: DatabaseSaveError?
    @State private var isCloudReconnectInFlight = false
    #if os(macOS)
    /// Editor presented by the menu-bar New Entry command (⌘N).
    @State private var commandEditor: EntryEditViewModel?
    #endif

    var body: some View {
        decoratedSplitView
            .onChange(of: viewModel.saveError) { _, newValue in
                if let newValue {
                    presentedSaveError = newValue
                }
            }
            .onChange(of: viewModel.visibleRootGroupID) { _, _ in
                navigationPath = []
                viewModel.selectEntry(nil)
            }
            .onChange(of: navigationPath) { _, _ in
                viewModel.selectEntry(nil)
            }
            .onChange(of: viewModel.searchText) { oldValue, newValue in
                guard oldValue != newValue else { return }
                viewModel.selectEntry(nil)
            }
            .modifier(NewEntryCommandHandling(view: self))
            .alert(item: $presentedSaveError) { error in
                Alert(
                    title: Text("Couldn't Save Database"),
                    message: Text(error.localizedDescription),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(
                "Lock and discard unsaved changes?",
                isPresented: Binding(
                    get: { viewModel.pendingLockRequest != nil },
                    set: { isPresented in
                        if isPresented == false {
                            viewModel.cancelLockRequest()
                        }
                    }
                )
            ) {
                Button("Lock and Discard", role: .destructive) {
                    let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                    viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
                }
                Button("Keep Editing", role: .cancel) {
                    viewModel.cancelLockRequest()
                }
            } message: {
                Text("Your unsaved entry changes will be lost.")
            }
    }

    private var decoratedSplitView: some View {
        splitView
            .navigationSplitViewStyle(.balanced)
            .background(Color(.systemBackground))
            .accessibilityIdentifier("regular-workspace.root")
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    if viewModel.saveError?.isWriteScopeRequired == true {
                        CloudReauthBanner(
                            providerName: viewModel.databaseReference.cloudProviderKind?.displayName ?? "cloud",
                            isReconnectInFlight: isCloudReconnectInFlight,
                            onReconnect: beginCloudReconnect
                        )
                    }

                    if viewModel.isDirty && viewModel.isSaving == false {
                        UnsavedChangesBanner(viewModel: viewModel)
                    }
                }
            }
            .disabled(viewModel.isSaving)
            .overlay {
                if viewModel.isSaving {
                    DatabaseSavingOverlay()
                }
            }
            .saveConflictAlert(viewModel: viewModel)
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            NavigationStack {
                if let selectedEntryID = viewModel.selectedEntryID {
                    EntryDetailView(
                        entryID: selectedEntryID,
                        viewModel: viewModel,
                        onClose: {
                            viewModel.selectEntry(nil)
                        }
                    )
                } else if viewModel.searchText.isEmpty {
                    ContentUnavailableView(
                        "Select an Entry",
                        systemImage: "key.horizontal",
                        description: Text("Choose an entry to view or edit its details.")
                    )
                    .accessibilityIdentifier("regular-workspace.select-entry-placeholder")
                } else {
                    ContentUnavailableView(
                        "Search Results",
                        systemImage: "magnifyingglass",
                        description: Text("Select a matching entry to view its details.")
                    )
                    .accessibilityIdentifier("regular-workspace.search-results-placeholder")
                }
            }
        }
    }

    /// macOS: reacts to the menu-bar New Entry command and hosts the editor
    /// sheet it presents; no-op modifier on iOS.
    private struct NewEntryCommandHandling: ViewModifier {
        let view: RegularDatabaseWorkspaceView

        func body(content: Content) -> some View {
            #if os(macOS)
            content
                .onChange(of: view.viewModel.newEntryRequestID) { oldValue, newValue in
                    guard newValue != oldValue else { return }
                    view.beginNewEntryFromCommand()
                }
                .sheet(item: view.$commandEditor) { formViewModel in
                    NavigationStack {
                        EntryEditView(
                            formViewModel: formViewModel,
                            databaseViewModel: view.viewModel
                        ) { _ in
                            view.commandEditor = nil
                        }
                    }
                    .frame(minWidth: 540, minHeight: 560)
                }
            #else
            content
            #endif
        }
    }

    /// Sidebar group navigation.
    ///
    /// iOS/iPadOS: a `NavigationStack` pushing `GroupListView` levels
    /// (unchanged legacy behavior).
    ///
    /// macOS: flat drill-down — pushed navigation stacks inside a
    /// `NavigationSplitView` sidebar column render zero-height on macOS
    /// (observed on macOS 26), so the sidebar re-renders `GroupListView` for
    /// the current level of `navigationPath` and offers a Back toolbar button
    /// instead of pushing.
    @ViewBuilder
    private var sidebarColumn: some View {
        #if os(macOS)
        if let rootID = viewModel.visibleRootGroupID {
            let currentGroupID = navigationPath.last ?? rootID
            GroupListView(
                groupID: currentGroupID,
                viewModel: viewModel,
                onSelectEntry: selectEntry,
                onSelectGroup: { groupID in
                    navigationPath.append(groupID)
                },
                onNavigateBack: navigationPath.isEmpty ? nil : {
                    navigationPath.removeLast()
                }
            )
            .id(currentGroupID)
        } else {
            ContentUnavailableView(
                "Vault Not Loaded",
                systemImage: "lock.doc",
                description: Text("Unlock a database to browse groups and entries.")
            )
        }
        #else
        NavigationStack(path: $navigationPath) {
            if let rootID = viewModel.visibleRootGroupID {
                GroupListView(
                    groupID: rootID,
                    viewModel: viewModel,
                    onSelectEntry: selectEntry
                )
                .navigationDestination(for: UUID.self) { groupID in
                    GroupListView(
                        groupID: groupID,
                        viewModel: viewModel,
                        onSelectEntry: selectEntry
                    )
                }
            } else {
                ContentUnavailableView(
                    "Vault Not Loaded",
                    systemImage: "lock.doc",
                    description: Text("Unlock a database to browse groups and entries.")
                )
            }
        }
        #endif
    }

    private func selectEntry(_ entry: KPEntry) {
        viewModel.selectEntry(entry.id)
    }

    #if os(macOS)
    @MainActor
    private func beginNewEntryFromCommand() {
        guard commandEditor == nil else { return }
        guard let targetGroupID = navigationPath.last ?? viewModel.visibleRootGroupID else { return }

        Task { @MainActor in
            let result = await viewModel.acknowledgeEditingIfNeeded()
            guard result == .acknowledged else { return }
            commandEditor = EntryEditViewModel(createIn: targetGroupID)
        }
    }
    #endif

    @MainActor
    private func beginCloudReconnect() {
        guard isCloudReconnectInFlight == false else { return }
        guard let providerID = viewModel.databaseReference.cloudSyncMetadata?.provider,
              let provider = CloudProviderRegistry.provider(for: providerID) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        isCloudReconnectInFlight = true
        Task { @MainActor in
            defer { isCloudReconnectInFlight = false }

            do {
                _ = try await provider.authenticate(from: presentationAnchor())
                viewModel.clearSaveError()
            } catch let error as CloudProviderError where error == .authenticationCancelled {
                return
            } catch {
                viewModel.presentSaveError(error)
            }
        }
    }

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
        #else
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
        #endif
    }
}
