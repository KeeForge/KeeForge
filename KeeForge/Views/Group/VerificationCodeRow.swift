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

                        VerificationCodeText(totpVM: totpVM, font: .title.bold())

                        if detail.isEmpty == false {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 8)

                    VerificationCodeCountdown(totpVM: totpVM, ringSize: 22)
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

/// An entry row in Groups, All Entries, search, and tags with the entry's live
/// code, shown when the Display setting is on. Same parts and timer lifecycle
/// as `VerificationCodeRow`, laid out as the ordinary entry row.
///
/// The copy button sits beside the row's own content for the same reason as
/// there. `onOpen` nil leaves the content plain, for the Mac lists, whose rows
/// handle taps themselves.
struct LiveCodeEntryRow: View {
    let entry: KPEntry
    let username: String
    var customIconData: Data?
    var folderPath: String?
    var openIdentifier = "entry.navlink"
    var onOpen: (() -> Void)?
    @State private var totpVM: TOTPViewModel

    init(
        entry: KPEntry,
        username: String,
        customIconData: Data?,
        folderPath: String?,
        config: TOTPConfig,
        sessionKey: SymmetricKey,
        openIdentifier: String = "entry.navlink",
        onOpen: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.username = username
        self.customIconData = customIconData
        self.folderPath = folderPath
        self.openIdentifier = openIdentifier
        self.onOpen = onOpen
        self._totpVM = State(initialValue: TOTPViewModel(config: config, sessionKey: sessionKey))
    }

    var body: some View {
        HStack(spacing: 4) {
            if let onOpen {
                Button(action: onOpen) { row }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(openIdentifier)
            } else {
                row
            }

            CopyButton(text: totpVM.code, accessibilityID: "entry-row.copy-code")
                .accessibilityLabel("Copy Verification Code")
        }
        .onAppear { totpVM.start() }
        .onDisappear { totpVM.stop() }
    }

    private var row: some View {
        EntryRow(
            entry: entry,
            username: username,
            customIconData: customIconData,
            folderPath: folderPath,
            verificationCode: totpVM
        )
    }
}

/// The live code, grouped for reading.
struct VerificationCodeText: View {
    let totpVM: TOTPViewModel
    let font: Font

    var body: some View {
        Text(totpVM.groupedCode)
            .font(font.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            // Digit by digit; the grouped text would be read as two numbers.
            .accessibilityLabel(Text(verbatim: totpVM.code.map(String.init).joined(separator: " ")))
    }
}

/// The ring and the seconds left beside it.
struct VerificationCodeCountdown: View {
    let totpVM: TOTPViewModel
    let ringSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            CountdownRing(
                progress: totpVM.progress,
                seconds: totpVM.secondsRemaining,
                showsSeconds: false
            )
            .frame(width: ringSize, height: ringSize)
            .accessibilityHidden(true)

            Text(
                Duration.seconds(totpVM.secondsRemaining)
                    .formatted(.units(allowed: [.seconds], width: .narrow))
            )
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
        }
    }
}
