#if os(macOS)
import SwiftUI

/// A failure the unlock form can fix, such as a wrong password, drawn under
/// the field it concerns. The form's Unlock is the retry; the rest is in its menu.
struct MacUnlockFailureCard: View {
    let card: MacDatabaseOpenPage.FailureCard
    let onCopyDetails: () -> Void
    let onSendFeedback: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                Text(card.summary)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unlock.error.label")
                Text(card.code)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Copy Error Details", action: onCopyDetails)
                    .accessibilityIdentifier("unlock.copy-error")
                Button("Send Feedback", action: onSendFeedback)
                    .accessibilityIdentifier("unlock.send-feedback")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More Actions for This Error"))
            .accessibilityIdentifier("unlock.error.more-actions")
            .macHelp(String(localized: "More Actions for This Error"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 11)
        .background(Color.red.opacity(0.1), in: shape)
        .overlay { shape.strokeBorder(Color.red.opacity(0.3), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unlock.error.card")
    }
}
#endif
