#if os(iOS)
import SwiftUI

/// A database in the iPhone and iPad list.
struct DatabaseListRow: View {
    let reference: DatabaseReference
    let status: DatabaseRowStatus
    let lastOpenedDescription: String?
    /// Off hides when the database was last synced, as it hides when it was
    /// last opened; sync warnings still show.
    var showsUsageStats = true

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
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.middle)

                statusLine(cloudWarning: cloudWarning(in: summary.notices))

                ForEach(summary.notices.filter { cloudWarning(in: [$0]) == nil }, id: \.text) { notice in
                    noticeText(notice)
                }
            }
            // Otherwise the list guesses from the status line and starts the divider past its icon.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    /// The name with its badges beside it when everything fits, else the
    /// badges on a line of their own, else one per line. Badges never truncate.
    @ViewBuilder
    private func titleLine(_ badges: [DatabaseRowStatusSummary.Badge]) -> some View {
        let name = Text(reference.displayName)
            .font(Theme.Font.rowTitle)
            .foregroundStyle(Color.primary)
        if badges.isEmpty {
            name.lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.badgeGap) {
                    name.lineLimit(1).fixedSize()
                    self.badges(badges)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.badgeGap) {
                    name.lineLimit(2)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Spacing.badgeGap) {
                            self.badges(badges)
                        }
                        VStack(alignment: .leading, spacing: Theme.Spacing.badgeGap) {
                            self.badges(badges)
                        }
                    }
                }
            }
        }
    }

    /// The file and where it lives: "Work.kdbx · WebDAV".
    private var sourceLine: String {
        SettingsSummaryText.joined([reference.filename, reference.cloudProviderKind?.displayName])
    }

    /// One line on the database's state: a cloud warning takes the place of
    /// its last sync, and a local file says when it was last opened.
    @ViewBuilder
    private func statusLine(cloudWarning: String?) -> some View {
        Group {
            if let cloudWarning {
                Label(cloudWarning, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(Theme.warning)
            } else if showsUsageStats, let lastSyncedAt = reference.cloudSyncMetadata?.lastSyncedAt {
                Label {
                    Text("Last synced \(lastSyncedAt, format: .relative(presentation: .named))")
                } icon: {
                    Image(systemName: "icloud")
                }
                .foregroundStyle(Theme.labelSecondary)
            } else if let lastOpenedDescription {
                Label(lastOpenedDescription, systemImage: "clock")
                    .foregroundStyle(Theme.labelSecondary)
                    .accessibilityIdentifier("database-row.last-opened")
            }
        }
        .font(Theme.Font.footnote)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
    }

    private func cloudWarning(in notices: [DatabaseRowStatusSummary.Notice]) -> String? {
        for case .cloudWarning(let text) in notices {
            return text
        }
        return nil
    }

    @ViewBuilder
    private func badges(_ badges: [DatabaseRowStatusSummary.Badge]) -> some View {
        ForEach(badges, id: \.self) { badge in
            switch badge {
            case .readOnly:
                StatusBadge(text: String(localized: "READ ONLY"), tone: .accent)
                    .fixedSize()
                    .accessibilityIdentifier("database-row.read-only-badge")
            case .quickLaunch:
                StatusBadge(text: String(localized: "QUICK LAUNCH"), tone: .accent)
                    .fixedSize()
                    .accessibilityIdentifier("database-row.quick-launch-badge")
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
