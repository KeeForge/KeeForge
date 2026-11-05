#if os(iOS)
import SwiftUI

/// A database's storage glyph, white on a ground picked from its name the way
/// entry monograms are. The list's card and tiles and the opening screen share
/// it, so a database keeps one tile from the list into its opening.
struct DatabaseSourceTile: View {
    let name: String
    let provider: CloudProviderKind?
    let isCloudBacked: Bool
    let size: CGFloat
    var needsAttention = false

    var body: some View {
        let tint = Theme.monogramTint(for: name)
        glyph
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.tileGlyph)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [tint, tint.mix(with: .black, by: Theme.EntryIcon.monogramShade)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if needsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
        } else if isCloudBacked {
            CloudProviderIcon(provider: provider, fallbackSystemName: "cloud")
        } else {
            Image(systemName: "iphone")
        }
    }
}

/// The database the list puts first: its Quick Launch database, or the one
/// opened last. Tapping anywhere opens it, like a row.
struct DatabaseSpotlightCard: View {
    let reference: DatabaseReference
    let status: DatabaseRowStatus
    let lastOpenedDescription: String?
    var isSelected = false

    @Environment(\.isSidebarColumnContent) private var isInSidebar
    @ScaledMetric(relativeTo: .largeTitle) private var tileSize: CGFloat = 76

    var body: some View {
        let statusLine = DatabaseStatusLine(
            reference: reference,
            status: status,
            lastOpenedDescription: lastOpenedDescription
        )
        VStack(spacing: Theme.Spacing.textLine) {
            DatabaseSourceTile(
                name: reference.displayName,
                provider: reference.cloudProviderKind,
                isCloudBacked: reference.isCloudBacked,
                size: tileSize,
                needsAttention: status.hasAccessIssue || status.isDocumentsFileMissing
            )
            .padding(.bottom, Theme.Spacing.cardGap)

            Text(reference.displayName)
                .font(Theme.Font.entryTitle)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)

            Text(sourceLine)
                .font(Theme.Font.subhead)
                .foregroundStyle(Theme.labelSecondary)
                .multilineTextAlignment(.center)

            if let statusLine {
                DatabaseStatusLabel(line: statusLine)
                    .multilineTextAlignment(.center)
            }

            unlockCapsule
                .padding(.top, Theme.Spacing.cardGap)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.tile)
        .background(isInSidebar ? Theme.cardRaised : Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.tint, lineWidth: Theme.Size.focusRing)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// "Quick Launch · Dropbox", or the file for a database on this device.
    private var sourceLine: String {
        SettingsSummaryText.joined([
            reference.isQuickLaunch ? String(localized: "Quick Launch") : nil,
            reference.cloudProviderKind?.displayName ?? reference.filename,
        ])
    }

    /// Names Face ID or Touch ID only when opening will ask for it by itself.
    private var unlockCapsule: some View {
        let biometricOpens = status.hasStoredKey && SettingsService.autoUnlockWithFaceID && BiometricService.isAvailable
        return Label {
            Text(biometricOpens ? biometricTitle : String(localized: "Unlock Database"))
        } icon: {
            if biometricOpens {
                Image(systemName: BiometricService.availableType == .touchID ? "touchid" : "faceid")
            }
        }
        .font(Theme.Font.rowTitle)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.unlockField)
        .background(.tint, in: Capsule())
    }

    private var biometricTitle: String {
        BiometricService.availableType == .touchID
            ? String(localized: "Unlock with Touch ID")
            : String(localized: "Unlock with Face ID")
    }
}

/// A database other than the spotlight one, in the list's two-column grid.
struct DatabaseTile: View {
    let reference: DatabaseReference
    let status: DatabaseRowStatus
    let lastOpenedDescription: String?
    var isSelected = false

    @Environment(\.isSidebarColumnContent) private var isInSidebar
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = Theme.Size.tileCircle

    var body: some View {
        let statusLine = DatabaseStatusLine(
            reference: reference,
            status: status,
            lastOpenedDescription: lastOpenedDescription
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
            DatabaseSourceTile(
                name: reference.displayName,
                provider: reference.cloudProviderKind,
                isCloudBacked: reference.isCloudBacked,
                size: tileSize,
                needsAttention: status.hasAccessIssue || status.isDocumentsFileMissing
            )
            Spacer(minLength: Theme.Spacing.tileGap)
            Text(reference.displayName)
                .font(Theme.Font.rowTitle)
                .foregroundStyle(Color.primary)
                .lineLimit(2)
            if let statusLine {
                DatabaseStatusLabel(line: statusLine, showsIcon: false)
                    .lineLimit(2)
            } else {
                Text(reference.cloudProviderKind?.displayName ?? reference.filename)
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Size.tile, alignment: .leading)
        .padding(Theme.Spacing.tile)
        .background(isInSidebar ? Theme.cardRaised : Theme.card)
        .overlay(alignment: .bottom) {
            // A stripe along the bottom edge marks a tile that needs a look.
            if statusLine?.needsAttention == true {
                Theme.warning.frame(height: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.tint, lineWidth: Theme.Size.focusRing)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A `DatabaseStatusLine` in footnote type, orange when it needs attention.
struct DatabaseStatusLabel: View {
    let line: DatabaseStatusLine
    var showsIcon = true

    var body: some View {
        Group {
            if showsIcon {
                Label {
                    text
                } icon: {
                    Image(systemName: line.systemImage)
                }
            } else {
                text
            }
        }
        .font(Theme.Font.footnote)
        .foregroundStyle(line.needsAttention ? Theme.warning : Theme.labelSecondary)
    }

    /// The identifier sits on the text, where tests query it as static text.
    @ViewBuilder
    private var text: some View {
        if let identifier = line.accessibilityIdentifier {
            Text(line.text).accessibilityIdentifier(identifier)
        } else {
            Text(line.text)
        }
    }
}

extension EnvironmentValues {
    /// Set by the database list when it fills a split view's sidebar, whose
    /// dark ground matches the plain card colour.
    @Entry var isSidebarColumnContent = false
}
#endif
