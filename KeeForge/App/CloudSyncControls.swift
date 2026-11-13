import SwiftUI

struct CloudSyncControls: View {
    @Bindable var viewModel: DatabaseViewModel
    @State private var isShowingDetails = false

    static func isVisible(for viewModel: DatabaseViewModel) -> Bool {
        viewModel.databaseReference.isCloudBacked
    }

    /// Also carries the open's cached-copy notice, so screens with these
    /// controls need no separate `CloudSyncWarningButton`.
    static func showsWarning(for viewModel: DatabaseViewModel) -> Bool {
        if case .failed = viewModel.cloudSyncOutcome { return true }
        return viewModel.cloudSyncBannerText != nil
            || viewModel.isCloudRefreshPending
            || showsPendingUploadNote(for: viewModel)
    }

    /// A conflicted AutoFill upload is not waiting: `PendingUploadConflictBanner`
    /// right below says it failed and offers Merge Changes, so this line would
    /// contradict it.
    static func showsPendingUploadNote(for viewModel: DatabaseViewModel) -> Bool {
        viewModel.hasPendingCloudUploads && viewModel.hasPendingUploadConflict == false
    }

    static func title(for viewModel: DatabaseViewModel) -> String {
        let providerName = viewModel.databaseReference.cloudProviderKind?.displayName ?? String(localized: "cloud")
        if viewModel.isSyncingCloud {
            return String(localized: "Checking \(providerName) for changes…")
        }
        if let outcome = viewModel.cloudSyncOutcome {
            return outcome.message
        }
        if let bannerText = viewModel.cloudSyncBannerText {
            return bannerText
        }
        if viewModel.isCloudRefreshPending {
            return String(localized: "Opened without checking \(providerName) for changes.")
        }
        return String(localized: "Cloud Sync")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isShowingDetails.toggle()
            } label: {
                if viewModel.isSyncingCloud {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: Self.showsWarning(for: viewModel) ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(Self.showsWarning(for: viewModel) ? Theme.State.cloudWarning : Color.secondary)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .buttonStyle(.plain)
            .accessibilityLabel("Cloud Sync")
            .accessibilityValue(Self.title(for: viewModel))
            .macHelp(String(localized: "Cloud Sync"))
            .accessibilityIdentifier("database.cloud-sync-status.details")
            .popover(isPresented: $isShowingDetails) {
                CloudSyncDetails(viewModel: viewModel) { isShowingDetails = false }
            }

            Button {
                Task {
                    await viewModel.syncCloudNow()
                }
            } label: {
                #if os(iOS)
                // A long translation gives way to an icon where the bar
                // beside it is narrow, as in a compact iPad toolbar.
                ViewThatFits(in: .horizontal) {
                    Text("Sync Now")
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityLabel("Sync Now")
                }
                #else
                Text("Sync Now")
                #endif
            }
            .font(.callout.weight(.semibold))
            .disabled(viewModel.canSyncCloudNow == false)
            .accessibilityIdentifier("database.cloud-sync-now")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("database.cloud-sync-status")
    }

}

/// The vault root's sync status, in words: nothing while the database is in
/// sync, a spinner while it syncs, and a warning that opens the details with
/// Sync Now. Pull to refresh syncs at any time.
struct CloudSyncStatusRow: View {
    @Bindable var viewModel: DatabaseViewModel
    @State private var isShowingDetails = false

    static func isVisible(for viewModel: DatabaseViewModel) -> Bool {
        viewModel.isSyncingCloud || CloudSyncControls.showsWarning(for: viewModel)
    }

    var body: some View {
        if viewModel.isSyncingCloud {
            Label {
                Text(CloudSyncControls.title(for: viewModel))
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
            .font(Theme.Font.subhead)
            .foregroundStyle(Theme.labelSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("database.cloud-sync-status.progress")
        } else if CloudSyncControls.showsWarning(for: viewModel) {
            HStack(spacing: Theme.Spacing.iconText) {
                Button {
                    isShowingDetails.toggle()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                            Text(CloudSyncControls.title(for: viewModel))
                                .foregroundStyle(Color.primary)
                            if let detail {
                                Text(detail)
                                    .font(Theme.Font.footnote)
                                    .foregroundStyle(Theme.labelSecondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                    .font(Theme.Font.subhead)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cloud Sync")
                .accessibilityValue(CloudSyncControls.title(for: viewModel))
                .accessibilityIdentifier("database.cloud-sync-status.details")
                .popover(isPresented: $isShowingDetails) {
                    CloudSyncDetails(viewModel: viewModel, showsSyncNow: true) { isShowingDetails = false }
                }

                Button("Sync Now") {
                    Task { await viewModel.syncCloudNow() }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(viewModel.canSyncCloudNow == false)
                .accessibilityIdentifier("database.cloud-sync-status.sync-now")
            }
        }
    }

    /// The second line: changes still waiting, else when it last synced.
    private var detail: String? {
        if CloudSyncControls.showsPendingUploadNote(for: viewModel) {
            return String(localized: "Changes saved through AutoFill are still waiting to upload.")
        }
        guard let lastSyncedAt = viewModel.databaseReference.cloudSyncMetadata?.lastSyncedAt else { return nil }
        return String(localized: "Last synced \(lastSyncedAt, format: .relative(presentation: .named))")
    }
}

private struct CloudSyncDetails: View {
    @Bindable var viewModel: DatabaseViewModel
    var showsSyncNow = false
    let close: () -> Void

    private var lastSyncedAt: Date? {
        viewModel.databaseReference.cloudSyncMetadata?.lastSyncedAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CloudSyncControls.title(for: viewModel))
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("database.cloud-sync-status.title")

            if let lastSyncedAt {
                Text("Last synced \(lastSyncedAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if CloudSyncControls.showsPendingUploadNote(for: viewModel) {
                Text("Changes saved through AutoFill are still waiting to upload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if showsSyncNow {
                    Button("Sync Now") {
                        close()
                        Task { await viewModel.syncCloudNow() }
                    }
                    .fontWeight(.semibold)
                    .disabled(viewModel.canSyncCloudNow == false)
                    .accessibilityIdentifier("database.cloud-sync-now")
                }
                Button("Dismiss") {
                    viewModel.dismissCloudSyncOutcome()
                    close()
                }
                .accessibilityIdentifier("database.cloud-sync-status.dismiss")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .leading)
        .padding(16)
        .font(.body)
        .lineLimit(nil)
        .presentationCompactAdaptation(.popover)
    }
}

struct CloudSyncWarningButton: View {
    let message: String
    @State private var isShowingDetails = false

    private var explanation: String {
        String(localized: "\(message)\n\nKeeForge opened the cached copy for now. Cloud sync needs attention before this database can be refreshed from its provider.")
    }

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Theme.State.cloudWarning)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cloud sync warning")
        .accessibilityValue(message)
        .accessibilityHint("Shows why this database needs attention")
        .accessibilityIdentifier("database.cloud-sync-warning")
        .alert("Cloud Sync Needs Attention", isPresented: $isShowingDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(explanation)
        }
    }
}
