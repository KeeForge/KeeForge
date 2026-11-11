import SwiftUI

/// Dismissible card shown on the database list when KeeForge is not enabled
/// as the system AutoFill credential provider. Below the databases on iPhone
/// and iPad it is a single row.
struct AutoFillTipBanner: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    @Environment(\.isListedTip) private var isListedTip

    var body: some View {
        if isListedTip {
            listedRow
        } else {
            card
        }
    }

    private var listedRow: some View {
        HStack(spacing: Theme.Spacing.iconText) {
            Image(systemName: "key.viewfinder")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                Text("Turn On AutoFill")
                    .font(Theme.Font.rowTitle)
                Text("Fill passwords in Safari and other apps.")
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Turn On…", action: onEnable)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("autofill-tip.enable")

            // Borderless, or the row would take both buttons' taps as one.
            dismissButton
                .buttonStyle(.borderless)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("Turn On AutoFill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                dismissButton
            }

            #if os(macOS)
            Text("To fill passwords from KeeForge in Safari and other apps, enable KeeForge in System Settings under General > AutoFill & Passwords.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // macOS has no in-app enable prompt, so the button opens the
            // system pane instead (`AutoFillStatusService`).
            Button("Open AutoFill Settings…", action: onEnable)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("autofill-tip.enable")
            #else
            Text("To fill passwords from KeeForge in Safari and other apps, enable KeeForge in iOS AutoFill settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Turn On…", action: onEnable)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("autofill-tip.enable")
            #endif
        }
        .tipBannerCard()
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("autofill-tip.dismiss")
        .macHelp(String(localized: "Dismiss"))
    }
}
