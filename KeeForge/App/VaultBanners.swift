import SwiftUI

struct UnsavedChangesBanner: View {
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        if PlatformDesign.followsIOSDesign {
            HStack(spacing: Theme.Spacing.iconText) {
                Circle()
                    .fill(Theme.warning)
                    .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    .accessibilityHidden(true)
                Text("Changes not saved")
                    .font(Theme.Font.subhead.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry Save") {
                    Task {
                        await viewModel.saveHandlingError()
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(viewModel.isSaving)
            }
            .vaultNoticeCard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("database.unsaved-indicator")
        } else {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.State.warning)
                    .frame(width: 8, height: 8)
                Text("Changes not saved")
                    .font(.caption.weight(.medium))

                Spacer(minLength: 12)

                Button("Retry Save") {
                    Task {
                        await viewModel.saveHandlingError()
                    }
                }
                .font(.caption.weight(.semibold))
                .disabled(viewModel.isSaving)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.State.warning.opacity(0.12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("database.unsaved-indicator")
        }
    }
}

extension View {
    /// A notice above the vault: the design's card on iPhone and iPad, the
    /// outlined card macOS has always drawn.
    func vaultNoticeCard() -> some View {
        modifier(VaultNoticeCard())
    }
}

private struct VaultNoticeCard: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if PlatformDesign.followsIOSDesign {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.side)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding(.horizontal, Theme.Spacing.side)
        } else {
            content
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
        }
    }
}

/// Stays up while an AutoFill save for this database is stuck behind a newer
/// cloud copy. A banner rather than an alert: the notice is due right at
/// unlock, while the compact unlock sheet is still dismissing, and a
/// presentation started then can be dropped.
///
/// `.contain` keeps the button's own identifier; a bare container identifier
/// would be copied onto it (see `tipBannerCard()`).
struct PendingUploadConflictBanner: View {
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A change saved through AutoFill couldn’t be uploaded because the cloud copy changed. Merge it into this database to upload it.")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Button("Merge Changes") {
                Task {
                    do {
                        try await viewModel.mergePendingUploads()
                    } catch {
                        viewModel.presentSaveError(error)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(PlatformDesign.followsIOSDesign ? .capsule : .automatic)
            .accessibilityIdentifier("pending-upload-banner.merge")
        }
        .vaultNoticeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-upload-banner")
    }
}

struct CloudReauthBanner: View {
    let providerName: String
    let isReconnectInFlight: Bool
    let onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reconnect \(providerName) to save changes.")
                .font(.subheadline.weight(.semibold))
            Button("Reconnect \(providerName)", action: onReconnect)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(PlatformDesign.followsIOSDesign ? .capsule : .automatic)
                .disabled(isReconnectInFlight)
                .accessibilityIdentifier("cloud-reauth-banner.reconnect")
        }
        .vaultNoticeCard()
        .accessibilityIdentifier("cloud-reauth-banner")
    }
}

