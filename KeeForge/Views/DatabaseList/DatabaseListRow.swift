#if os(iOS)
import SwiftUI

/// A database in the iPhone and iPad list. The macOS sidebar keeps
/// `DatabaseRowView`.
struct DatabaseListRow: View {
    let reference: DatabaseReference
    let status: DatabaseRowStatus
    let lastOpenedDescription: String?

    @ScaledMetric(relativeTo: .body) private var iconSize = Theme.Size.entryIcon
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var summary: DatabaseRowStatusSummary {
        DatabaseRowStatusSummary(
            isReadOnly: reference.isReadOnly,
            isQuickLaunch: reference.isQuickLaunch,
            status: status
        )
    }

    var body: some View {
        let summary = summary
        HStack(spacing: Theme.Spacing.iconText) {
            sourceIcon

            VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                titleLine(summary.badges)

                Text(sourceLine)
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                metadataLine

                ForEach(summary.notices, id: \.text) { notice in
                    noticeText(notice)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    /// The name with its badges beside it; stacked at accessibility sizes.
    @ViewBuilder
    private func titleLine(_ badges: [DatabaseRowStatusSummary.Badge]) -> some View {
        let name = Text(reference.displayName)
            .font(Theme.Font.rowTitle)
            .foregroundStyle(Color.primary)
            .lineLimit(1)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.badgeGap) {
                name
                self.badges(badges)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.badgeGap) {
                name
                self.badges(badges)
            }
        }
    }

    /// The file and where it lives: "Work.kdbx · WebDAV".
    private var sourceLine: String {
        SettingsSummaryText.joined([reference.filename, reference.cloudProviderKind?.displayName])
    }

    /// When it was last opened or synced, and its key file.
    @ViewBuilder
    private var metadataLine: some View {
        let lastSyncedAt = reference.cloudSyncMetadata?.lastSyncedAt
        if lastOpenedDescription != nil || lastSyncedAt != nil || reference.keyFileFilename != nil {
            let line = Group {
                if let lastOpenedDescription {
                    Label(lastOpenedDescription, systemImage: "clock")
                        .accessibilityIdentifier("database-row.last-opened")
                }
                if let lastSyncedAt {
                    Label {
                        Text("Last synced \(lastSyncedAt, format: .relative(presentation: .named))")
                    } icon: {
                        Image(systemName: "icloud")
                    }
                }
                if let keyFileFilename = reference.keyFileFilename {
                    Label(keyFileFilename, systemImage: "key")
                }
            }
            .lineLimit(1)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.textLine) { line }
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
            } else {
                HStack(spacing: Theme.Spacing.badgeGap) { line }
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
            }
        }
    }

    @ViewBuilder
    private func badges(_ badges: [DatabaseRowStatusSummary.Badge]) -> some View {
        ForEach(badges, id: \.self) { badge in
            switch badge {
            case .readOnly:
                StatusBadge(text: String(localized: "READ ONLY"), tone: .accent)
                    .accessibilityIdentifier("database-row.read-only-badge")
            case .quickLaunch:
                StatusBadge(text: String(localized: "QUICK LAUNCH"), tone: .accent)
                    .accessibilityIdentifier("database-row.quick-launch-badge")
            case .uploadPending:
                StatusBadge(text: String(localized: "Upload Pending"), tone: .warning)
                    .accessibilityIdentifier("database-row.pending-uploads-badge")
            }
        }
    }

    @ViewBuilder
    private func noticeText(_ notice: DatabaseRowStatusSummary.Notice) -> some View {
        let text = Text(notice.text)
            .font(Theme.Font.footnote)
            .foregroundStyle(Theme.warning)
        if notice == .documentsFileMissing {
            text.accessibilityIdentifier("database-row.documents-file-missing")
        } else {
            text
        }
    }

    private var sourceIcon: some View {
        Group {
            if status.hasAccessIssue || status.isDocumentsFileMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else if reference.isCloudBacked {
                CloudProviderIcon(provider: reference.cloudProviderKind, fallbackSystemName: "icloud")
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "iphone")
                    .foregroundStyle(.tint)
            }
        }
        .font(.title3)
        .frame(width: iconSize, height: iconSize)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: Theme.Radius.entryIcon, style: .continuous))
        .accessibilityHidden(true)
    }
}
#endif
