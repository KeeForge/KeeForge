import SwiftUI

struct DatabaseRowView: View {
    let reference: DatabaseReference
    let status: DatabaseRowStatus
    let biometricSymbolName: String
    let lastOpenedDescription: String?
    let filenameSubtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.hasAccessIssue ? "exclamationmark.triangle.fill" : "lock.fill")
                .font(.title3)
                .foregroundStyle(status.hasAccessIssue ? Color.orange : Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reference.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

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

                    if status.hasStoredKey {
                        Image(systemName: biometricSymbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if status.hasAccessIssue {
                        Text("File unavailable")
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
}
