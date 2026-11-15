#if os(iOS)
import SwiftUI

/// Dismissible card shown on the database list when KeeForge is not enabled
/// as the system AutoFill credential provider.
struct AutoFillTipBanner: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("Turn On AutoFill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("autofill-tip.dismiss")
                .macHelp(String(localized: "Dismiss"))
            }

            Text("To fill passwords from KeeForge in Safari and other apps, enable KeeForge in iOS AutoFill settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Turn On…", action: onEnable)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("autofill-tip.enable")
        }
        .tipBannerCard()
    }
}
#endif
