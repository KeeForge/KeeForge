import SwiftUI

/// The "support the project" section, picked to match the build's channel.
///
/// An App Store build shows the StoreKit tip jar. A notarized direct-download
/// build has no receipt to purchase against, and shipping a StoreKit surface
/// there would fail rather than charge anyone, so it links to GitHub Sponsors
/// instead. Both call sites in `SettingsView` use this, so neither has to know
/// which channel it is in.
struct SupportKeeForgeSection: View {
    private static let sponsorsURL = URL(string: "https://github.com/sponsors/crazytan")

    var body: some View {
        if DistributionChannel.supportsStoreKit {
            TipJarView()
        } else if let url = Self.sponsorsURL {
            Section {
                Link(destination: url) {
                    Label("Sponsor KeeForge", systemImage: "heart")
                }
                .accessibilityIdentifier("support.sponsors")
            } footer: {
                Text("KeeForge is free and open source. Sponsorship covers the Apple Developer Program and the time that goes into it.")
            }
        }
    }
}
