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
            }

            Text("To fill passwords from KeeForge in Safari and other apps, enable KeeForge in iOS AutoFill settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Turn On…", action: onEnable)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("autofill-tip.enable")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // No container-level accessibilityIdentifier: SwiftUI propagates it to
        // every child element, clobbering the enable/dismiss button ids.
    }
}
