import CryptoKit
import SwiftUI

/// One row of the Verification Codes view: the entry's current code with its
/// countdown and a copy button.
///
/// The opening part and the copy button are sibling buttons rather than one
/// `NavigationLink` around everything, because a button nested in a link's
/// label does not get its own taps. The opening part keeps the entry rows'
/// `entry.navlink` identifier.
struct VerificationCodeRow: View {
    let title: String
    /// The entry's username and group, whichever of the two it has.
    let detail: String
    let onOpen: () -> Void
    @State private var totpVM: TOTPViewModel

    init(
        title: String,
        detail: String,
        config: TOTPConfig,
        sessionKey: SymmetricKey,
        onOpen: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.onOpen = onOpen
        self._totpVM = State(initialValue: TOTPViewModel(config: config, sessionKey: sessionKey))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(totpVM.groupedCode)
                            .font(.title.bold().monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .contentTransition(.numericText())
                            // Digit by digit; the grouped text would be read
                            // as two numbers.
                            .accessibilityLabel(Text(verbatim: totpVM.code.map(String.init).joined(separator: " ")))

                        if detail.isEmpty == false {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        CountdownRing(
                            progress: totpVM.progress,
                            seconds: totpVM.secondsRemaining,
                            showsSeconds: false
                        )
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)

                        Text(
                            Duration.seconds(totpVM.secondsRemaining)
                                .formatted(.units(allowed: [.seconds], width: .narrow))
                        )
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("entry.navlink")

            CopyButton(text: totpVM.code, accessibilityID: "verification-code-row.copy")
                .accessibilityLabel("Copy Verification Code")
        }
        .onAppear { totpVM.start() }
        .onDisappear { totpVM.stop() }
    }
}
