#if os(macOS)
import AppKit
import AuthenticationServices
import SwiftUI

struct MacWorkspaceDetailColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation

    var body: some View {
        NavigationStack {
            selectionDetail
        }
        // The placeholders size to their content; filling keeps the banners at the column's top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            MacWorkspaceBanners(viewModel: viewModel, presentation: presentation)
        }
    }

    @ViewBuilder
    private var selectionDetail: some View {
        Group {
            if let summary = MacEntrySelectionSummary.make(session: viewModel) {
                MacEntrySelectionSummaryView(summary: summary, viewModel: viewModel, presentation: presentation)
            } else if let selectedEntryID = viewModel.workspace.selectedEntryID {
                EntryDetailView(
                    entryID: selectedEntryID,
                    viewModel: viewModel,
                    onClose: {
                        viewModel.workspace.selectedEntryID = nil
                    },
                    onSelectTag: { viewModel.workspace.selectedTag = $0 },
                    popsOnClose: false
                )
                .id(selectedEntryID)
            } else {
                ContentUnavailableView(
                    "Select an Entry",
                    systemImage: "key.horizontal",
                    description: Text("Choose an entry to view or edit its details.")
                )
                .accessibilityIdentifier("regular-workspace.select-entry-placeholder")
            }
        }
    }
}

/// Several picked entries: their icons fanned out, how many, their names, and
/// Move to Group… and Delete, which act on all of them.
private struct MacEntrySelectionSummaryView: View {
    let summary: MacEntrySelectionSummary
    let viewModel: DatabaseViewModel
    let presentation: MacWorkspacePresentation

    var body: some View {
        VStack(spacing: 8) {
            icons
            Text(summary.title)
                .font(.title2.bold())
                .padding(.top, 14)
                .accessibilityIdentifier("entry-selection.count")
            Text(summary.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                Button("Move to Group…") {
                    MacWorkspaceCommands(session: viewModel, presentation: presentation).moveToGroup()
                }
                .disabled(summary.canMove == false)
                .accessibilityIdentifier("entry-selection.move")
                // ⌘⌫ is the menu bar's Delete, which acts on the same selection.
                Button {
                    presentation.beginSelectionDeletion(in: viewModel)
                } label: {
                    HStack(spacing: 4) {
                        Text("Delete")
                            .foregroundStyle(.red)
                        Text(verbatim: "⌘⌫")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(summary.canDelete == false)
                .accessibilityIdentifier("entry-selection.delete")
            }
            .controlSize(.large)
            .padding(.top, 18)
            Text("Deleted entries are moved to the recycle bin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 48)
        .padding(.top, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var icons: some View {
        let entries = summary.iconEntryIDs.compactMap { viewModel.entry(withID: $0) }
        let customIcons = viewModel.currentMeta?.customIcons ?? [:]
        let fan: [(offset: CGFloat, angle: Double, size: CGFloat)] = [(-36, -8, 60), (0, 0, 68), (36, 8, 60)]
        return ZStack {
            // The second icon is drawn last, in front of the other two.
            ForEach([0, 2, 1].filter { $0 < entries.count }, id: \.self) { index in
                let entry = entries[index]
                EntryIconView(entry: entry, customIconData: entry.customIconUUID.flatMap { customIcons[$0] },
                              size: fan[index].size)
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                    .rotationEffect(.degrees(fan[index].angle))
                    .offset(x: fan[index].offset)
            }
        }
        .frame(width: 132, height: 80)
        .accessibilityHidden(true)
    }
}

/// The save, upload-conflict and cloud reconnect banners, at the top of the detail column.
private struct MacWorkspaceBanners: View {
    let viewModel: DatabaseViewModel
    let presentation: MacWorkspacePresentation

    var body: some View {
        VStack(spacing: 8) {
            if viewModel.saveError?.isWriteScopeRequired == true {
                CloudReauthBanner(
                    providerName: viewModel.databaseReference.cloudProviderKind?.displayName ?? "cloud",
                    isReconnectInFlight: presentation.isCloudReconnectInFlight,
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
        // The detail scrolls under this inset, and the banners are only tinted.
        .background(Color(.systemBackground), ignoresSafeAreaEdges: [])
    }

    private func beginCloudReconnect() {
        guard presentation.isCloudReconnectInFlight == false else { return }
        guard let providerID = viewModel.databaseReference.cloudSyncMetadata?.provider,
              let provider = CloudProviderRegistry.provider(for: providerID) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        presentation.reconnectCloud(in: viewModel) {
            _ = try await provider.authenticate(from: presentationAnchor())
        }
    }

    private func presentationAnchor() -> ASPresentationAnchor {
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}
#endif
