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
    let entry: KPEntry
    var customIconData: Data? = nil
    let title: String
    /// The entry's username and group, whichever of the two it has.
    let detail: String
    let onOpen: () -> Void
    @State private var totpVM: TOTPViewModel
    @ScaledMetric(relativeTo: .body) private var iconSize = Theme.Size.entryIcon
    @ScaledMetric(relativeTo: .subheadline) private var ringSize = Theme.Size.badge
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        entry: KPEntry,
        customIconData: Data? = nil,
        title: String,
        detail: String,
        config: TOTPConfig,
        sessionKey: SymmetricKey,
        onOpen: @escaping () -> Void
    ) {
        self.entry = entry
        self.customIconData = customIconData
        self.title = title
        self.detail = detail
        self.onOpen = onOpen
        self._totpVM = State(initialValue: TOTPViewModel(config: config, sessionKey: sessionKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tileGap) {
            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.iconText) {
                    FaviconEntryIconView(entry: entry, customIconData: customIconData, size: iconSize)

                    VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                        Text(title)
                            .font(Theme.Font.rowTitle)
                            .foregroundStyle(Color.primary)
                            .lineLimit(textLineLimit)

                        if detail.isEmpty == false {
                            Text(detail)
                                .font(Theme.Font.subhead)
                                .foregroundStyle(Theme.labelSecondary)
                                .lineLimit(textLineLimit)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                // Digit by digit; the grouped text would be read as two numbers.
                .accessibilityValue(Text(verbatim: totpVM.code.map(String.init).joined(separator: " ")))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("entry.navlink")

            HStack(spacing: Theme.Spacing.iconText) {
                Text(totpVM.groupedCode)
                    .font(Theme.Font.codeLarge)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                ZStack {
                    CountdownRing(
                        progress: totpVM.progress,
                        seconds: totpVM.secondsRemaining,
                        showsSeconds: false
                    )
                    Text(totpVM.secondsRemaining, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.labelSecondary)
                }
                .frame(width: ringSize, height: ringSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(totpVM.secondsRemaining) seconds remaining"))

                CopyButton(text: totpVM.code, accessibilityID: "verification-code-row.copy")
                    .accessibilityLabel("Copy Verification Code")
            }
            .padding(.leading, Theme.Spacing.iconText)
            .background(Theme.card2, in: RoundedRectangle(cornerRadius: Theme.Radius.entryIcon, style: .continuous))
        }
        .onAppear { totpVM.start() }
        .onDisappear { totpVM.stop() }
    }

    /// One line keeps the rows even; accessibility sizes leave too little width for that.
    private var textLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
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
