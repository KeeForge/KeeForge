#if os(macOS)
import SwiftUI

/// What a database window shows while its key is checked and the database
/// opens (UnlockVariants board, Opening): the steps, the status and Cancel.
struct MacDatabaseOpeningView: View {
    let summary: MacLockedDatabaseSummary
    let opening: MacDatabaseOpenPage.Opening
    let onCancel: () -> Void

    var body: some View {
        MacLockedPageLayout {
            VStack(spacing: 0) {
                MacLockedPageHeader(tile: .brand, title: String(localized: "Opening \(summary.name)"),
                                    subtitle: summary.fileAndStorage)
                VStack(spacing: 0) {
                    ForEach(Array(opening.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { Divider() }
                        MacOpeningStepRow(step: step)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(width: 300)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("unlock.opening.steps")
                .padding(.top, 24)

                Text(opening.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                if opening.canCancel {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("unlock.opening.cancel")
                        .padding(.top, 16)
                }
            }
        }
    }
}

private struct MacOpeningStepRow: View {
    let step: DatabaseOpeningSteps.Step

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 18, height: 18)
            Text(step.title)
                .font(.system(size: 13, weight: step.state == .current ? .semibold : .regular))
                .foregroundStyle(step.state == .current ? .primary : .secondary)
            Spacer(minLength: 0)
            if let detail = step.detail {
                Text(detail)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var indicator: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.green, in: Circle())
                .accessibilityLabel(Text("Done"))
        case .current:
            ProgressView()
                .controlSize(.small)
        case .upcoming:
            Circle()
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
        }
    }
}
#endif
