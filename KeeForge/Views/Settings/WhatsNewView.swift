import SwiftUI

struct WhatsNewView: View {
    let release: WhatsNewRelease

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    header

                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(release.features) { feature in
                            featureRow(feature)
                        }
                    }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 36)
            }
            .navigationTitle("What's New")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("whats-new.done")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 76, height: 76)
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text("What's New in KeeForge")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("whats-new.title")

            HStack(spacing: 4) {
                Text("Version")
                Text(verbatim: release.version)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func featureRow(_ feature: WhatsNewFeature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(feature.title)
                    .font(.headline)

                Text(feature.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("whats-new.feature.\(feature.id)")
    }
}
