import AuthenticationServices
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct DatabaseNavigationView: View {
    @Bindable var viewModel: DatabaseViewModel
    @State private var presentedSaveError: DatabaseSaveError?
    @State private var isCloudReconnectInFlight = false

    var body: some View {
        @Bindable var workspace = viewModel.workspace
        NavigationStack(path: $workspace.navigationPath) {
            Group {
                if let rootID = viewModel.visibleRootGroupID {
                    GroupListView(groupID: rootID, viewModel: viewModel)
                } else {
                    ContentUnavailableView(
                        "Vault Not Loaded",
                        systemImage: "lock.doc",
                        description: Text("Unlock a database to view groups and entries.")
                    )
                }
            }
            .navigationDestination(for: DatabaseRoute.self) { route in
                switch route {
                case .group(let groupID):
                    GroupListView(groupID: groupID, viewModel: viewModel)
                case .entry(let entryID):
                    EntryDetailView(entryID: entryID, viewModel: viewModel)
                case .tag(let tag):
                    TagEntriesView(tag: tag, viewModel: viewModel)
                case .collection(let collection):
                    if let rootID = viewModel.visibleRootGroupID {
                        GroupListView(groupID: rootID, collection: collection, viewModel: viewModel)
                    }
                case .editor:
                    if let editor = viewModel.workspace.openEditor {
                        compactEditor(editor)
                    }
                }
            }
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

                    if viewModel.hasPendingUploadConflict && viewModel.isSaving == false {
                        PendingUploadConflictBanner(viewModel: viewModel)
                    }
                }
                // The lists scroll under this inset, and the banners are only tinted.
                .background(Color(.systemBackground), ignoresSafeAreaEdges: [])
            }
        }
        // The workspace's editor is pushed over whatever screen opened it.
        .onChange(of: viewModel.workspace.openEditor != nil) { _, isOpen in
            if isOpen, viewModel.workspace.navigationPath.last != .editor {
                viewModel.workspace.navigationPath.append(.editor)
            }
        }
        // Back or a swipe popped it.
        .onChange(of: viewModel.workspace.navigationPath) { _, path in
            if viewModel.workspace.openEditor != nil, path.contains(.editor) == false {
                viewModel.workspace.closeEditor()
            }
        }
        .disabled(viewModel.isSaving)
        .overlay {
            if viewModel.isSaving {
                DatabaseSavingOverlay()
            }
        }
        .saveConflictAlert(viewModel: viewModel)
        .onChange(of: viewModel.saveError) { _, newValue in
            if let newValue {
                presentedSaveError = newValue
            }
        }
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
                get: { viewModel.pendingLockRequest?.reason == .draft },
                set: { _ in }
            )
        ) {
            if viewModel.isReadOnly == false {
                Button("Retry Save and Lock") {
                    Task { await viewModel.saveAndLockAfterLockRequest() }
                }
            }
            Button("Lock and Discard", role: .destructive) {
                let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
            }
            Button("Keep Editing", role: .cancel) {
                Task {
                    await viewModel.continueEditingAfterLockRequest()
                }
            }
        } message: {
            Text("Your unsaved entry changes will be lost.")
        }
    }

    @ViewBuilder
    private func compactEditor(_ editor: DatabaseWorkspaceState.OpenEditor) -> some View {
        switch editor {
        case .entry(let formViewModel):
            EntryEditView(
                formViewModel: formViewModel,
                databaseViewModel: viewModel,
                coordinator: viewModel.workspace.editorCoordinator(database: viewModel)
            ) { completion in
                viewModel.workspace.finishCompactEntryEditor(completion)
            }
        case .group(let formViewModel):
            GroupEditView(
                formViewModel: formViewModel,
                databaseViewModel: viewModel,
                coordinator: viewModel.workspace.editorCoordinator(database: viewModel)
            ) {
                viewModel.workspace.closeEditor()
            }
        }
    }

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

struct DatabaseSavingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text("Saving changes...")
                    .font(.headline)

                Text("KeeForge is writing the updated database securely.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 280)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving changes")
        .accessibilityIdentifier("database.saving-overlay")
    }
}

