#if os(macOS)
import SwiftUI

/// A failure another password cannot fix (UnlockVariants board, File
/// unavailable): what happened, the ways forward, and the error code.
struct MacDatabaseRecoveryView: View {
    let session: DatabaseViewModel
    @Bindable var form: MacUnlockFormModel
    let page: MacDatabaseOpenPage.RecoveryPage
    let onReconnect: () -> Void
    let onRemoveFromList: () -> Void

    @State private var feedbackContext: FeedbackComposerContext?

    static let columnWidth: CGFloat = 420

    var body: some View {
        MacLockedPageLayout {
            VStack(spacing: 0) {
                MacLockedPageHeader(tile: .symbol(Self.symbolName(page.symbol)), title: page.title,
                                    subtitle: page.subtitle)
                Text(page.summary)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .accessibilityIdentifier("unlock.error.label")

                actions
                    .padding(.top, 20)

                errorCodeRow
                    .padding(.top, 22)

                Text("Removing it from the list also removes its cached copy and saved biometric key. The file itself is not touched.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .frame(width: Self.columnWidth)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("unlock.recovery")
        }
        .sheet(item: $feedbackContext) { context in
            FeedbackComposerView(context: context)
                .macSheetFrame()
        }
        .alert(item: $form.selectionAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            ForEach(Array(page.actions.enumerated()), id: \.offset) { index, action in
                button(for: action, isPrimary: index == 0)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    private func button(for action: MacDatabaseOpenPage.RecoveryAction, isPrimary: Bool) -> some View {
        switch action {
        case .locateDatabaseFile:
            styled(Button {
                Task { await form.locateDatabaseFile() }
            } label: {
                Label("Locate Database File…", systemImage: "doc.text.magnifyingglass")
            }, isPrimary: isPrimary)
            .accessibilityIdentifier("unlock.relink")
        case .reconnect(let provider):
            styled(Button(String(localized: "Reconnect \(provider.displayName)"), action: onReconnect), isPrimary: isPrimary)
                .disabled(form.isReconnecting)
                .accessibilityIdentifier("unlock.reconnect")
        case .tryAgain:
            styled(Button("Try Again") { form.tryAgain() }, isPrimary: isPrimary)
                .accessibilityIdentifier("unlock.retry.button")
        case .removeFromList:
            Button(action: onRemoveFromList) {
                Text("Remove from List")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("unlock.remove-missing")
        }
    }

    @ViewBuilder
    private func styled(_ button: Button<some View>, isPrimary: Bool) -> some View {
        if isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// The code in full, with the links beside it or, for a long code, under it.
    private var errorCodeRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                errorCode
                Spacer(minLength: 8)
                errorLinks
            }
            VStack(alignment: .leading, spacing: 6) {
                errorCode
                errorLinks
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var errorCode: some View {
        HStack(spacing: 8) {
            Text("Error Code")
                .foregroundStyle(.secondary)
            Text(page.errorCode)
                .font(.system(size: 11).monospaced())
                .textSelection(.enabled)
        }
        .fixedSize()
    }

    private var errorLinks: some View {
        HStack(spacing: 14) {
            Button("Copy Error Details") {
                guard let failure = session.openFailure else { return }
                ClipboardService.copy(failure.copyableDetails)
            }
            .accessibilityIdentifier("unlock.copy-error")
            Button("Send Feedback") {
                guard let failure = session.openFailure else { return }
                feedbackContext = .databaseOpenFailure(failure)
            }
            .accessibilityIdentifier("unlock.send-feedback")
        }
        .buttonStyle(.plain)
        .fontWeight(.semibold)
        .foregroundStyle(.tint)
        .fixedSize()
    }

    static func symbolName(_ symbol: MacDatabaseOpenPage.RecoverySymbol) -> String {
        switch symbol {
        case .missingFile: "exclamationmark.triangle.fill"
        case .fileAccess: "lock.fill"
        case .server: "wifi.exclamationmark"
        case .account: "person.crop.circle.badge.exclamationmark"
        case .unsupportedFormat: "doc.badge.gearshape"
        case .unexpected: "exclamationmark.octagon.fill"
        }
    }
}

/// A database window whose reference has no file, bookmark or cached copy to open.
struct MacDatabaseUnavailableView: View {
    let summary: MacLockedDatabaseSummary

    var body: some View {
        MacLockedPageLayout {
            VStack(spacing: 0) {
                MacLockedPageHeader(tile: .brand, title: summary.name, subtitle: summary.fileAndStorage)
                Text("This database is unavailable. Return to the database list to remove it or refresh its bookmark.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
            }
            .frame(width: MacDatabaseRecoveryView.columnWidth)
        }
    }
}
#endif
