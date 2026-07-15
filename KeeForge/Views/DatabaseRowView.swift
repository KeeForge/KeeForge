import SwiftUI

struct DatabaseRowView: View {
    let reference: DatabaseReference
    let status: DatabaseRowStatus
    let lastOpenedDescription: String?
    let filenameSubtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            sourceIcon

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reference.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if reference.isReadOnly {
                        Text("READ ONLY")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .accessibilityIdentifier("database-row.read-only-badge")
                    }

                    if reference.isQuickLaunch {
                        Text("QUICK LAUNCH")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .accessibilityIdentifier("database-row.quick-launch-badge")
                    }

                    if status.pendingUploadCount > 0 {
                        Text("Pending \(status.pendingUploadCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(status.pendingUploadConflictCount > 0 ? .orange : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (status.pendingUploadConflictCount > 0 ? Color.orange : Color.secondary)
                                    .opacity(0.12),
                                in: Capsule()
                            )
                            .accessibilityIdentifier("database-row.pending-uploads-badge")
                    }
                }

                if let filenameSubtitle {
                    Text(filenameSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let lastOpenedDescription {
                    Text(lastOpenedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("database-row.last-opened")
                }

                HStack(spacing: 10) {
                    if reference.keyFileFilename != nil {
                        Label(reference.keyFileFilename ?? "Key File", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if status.pendingUploadConflictCount > 0 {
                        Text(conflictText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if let warningText = status.cloudState?.warningText {
                        Text(warningText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }

                    if status.hasAccessIssue, status.cloudState == nil {
                        Text("File unavailable")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if status.hasAccessIssue, status.cloudState != nil {
                        Text("Cache unavailable")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 12)

            // macOS uses standard sidebar selection (no disclosure chevron);
            // iOS keeps the drill-in affordance.
            #if os(iOS)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            #endif
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Local (non-cloud) database glyph. The iPhone symbol reads wrong on a
    /// Mac, so use a drive symbol there; iOS keeps the familiar device glyph.
    private var localDatabaseSymbolName: String {
        #if os(macOS)
        "externaldrive.fill"
        #else
        "iphone"
        #endif
    }

    private var conflictText: String {
        if status.pendingUploadConflictCount == 1 {
            return "1 pending upload conflict"
        }
        return "\(status.pendingUploadConflictCount) pending upload conflicts"
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if status.hasAccessIssue {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
        } else if reference.isCloudBacked {
            CloudProviderIcon(
                provider: reference.cloudProviderKind,
                fallbackSystemName: "icloud"
            )
            .font(.title3)
            .foregroundStyle(Color.accentColor)
            .frame(width: 28, height: 28)
        } else {
            Image(systemName: localDatabaseSymbolName)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
        }
    }
}
