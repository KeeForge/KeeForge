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
                        Label("Quick Launch", systemImage: "rocket.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
                }

                HStack(spacing: 10) {
                    if reference.keyFileFilename != nil {
                        Label(reference.keyFileFilename ?? "Key File", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let warningText = status.cloudState?.warningText {
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

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
                size: 24,
                fallbackSystemName: "icloud"
            )
            .frame(width: 28, height: 28)
        } else {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
        }
    }
}
