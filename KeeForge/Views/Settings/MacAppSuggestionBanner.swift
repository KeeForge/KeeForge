import SwiftUI

/// Dismissible card shown on the database list when the iPhone and iPad app
/// is running on a Mac, pointing at the native Mac app.
struct MacAppSuggestionBanner: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("Using KeeForge on a Mac?")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("mac-app-suggestion.dismiss")
            }

            Text("Try our native macOS app for a better desktop experience.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Open Mac Version", action: onOpen)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mac-app-suggestion.open")
        }
        .tipBannerCard()
    }
}
