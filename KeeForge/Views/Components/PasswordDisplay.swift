import SwiftUI

private enum PasswordVisualStyle {
    static let bulletCount = 12
    static let concealedText = String(repeating: "\u{2022}", count: bulletCount)
    static let segmentCount = 4
}

struct PasswordDisplayRow<Actions: View>: View {
    let revealedText: String?
    private let actions: Actions

    init(
        revealedText: String?,
        @ViewBuilder actions: () -> Actions
    ) {
        self.revealedText = revealedText
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                if let revealedText {
                    // Deliberately no `.textSelection(.enabled)` here: the system
                    // copy path would bypass ClipboardService (no expiry, no
                    // localOnly/ConcealedType, no clear-on-lock). The sanctioned
                    // CopyButton -> ClipboardService.copy is the only copy path.
                    PasswordDisplayText(revealedText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    PasswordConcealedText()
                }

                Spacer(minLength: 12)
                actions
            }

            if let revealedText {
                PasswordStrengthIndicator(password: revealedText)
                    .padding(.leading, 36)
            }
        }
    }
}

struct PasswordDisplayText: View {
    let password: String

    init(_ password: String) {
        self.password = password
    }

    var body: some View {
        Text(styledPassword)
            .font(.body.monospaced())
            .accessibilityLabel(Text(verbatim: password))
    }

    private var styledPassword: AttributedString {
        var result = AttributedString()

        for character in password {
            var segment = AttributedString(String(character))
            segment.foregroundColor = color(for: character)
            result.append(segment)
        }

        return result
    }

    private func color(for character: Character) -> Color {
        if character.isLetter {
            return .primary
        } else if character.isNumber {
            return .blue
        } else {
            return .orange
        }
    }
}

struct PasswordConcealedText: View {
    var accessibilityLabel: String = String(localized: "Hidden password")

    var body: some View {
        Text(PasswordVisualStyle.concealedText)
            .font(.body.monospaced())
            .foregroundStyle(.secondary)
            .accessibilityLabel(accessibilityLabel)
    }
}

struct PasswordStrengthIndicator: View {
    let password: String

    private var estimate: PasswordStrengthEstimate? {
        PasswordStrengthEstimator.estimate(password)
    }

    var body: some View {
        if let estimate {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(0..<PasswordVisualStyle.segmentCount, id: \.self) { index in
                        Capsule()
                            .fill(index < estimate.level.filledSegments ? color(for: estimate.level) : Color.secondary.opacity(0.2))
                            .frame(height: 4)
                    }
                }
                .accessibilityHidden(true)

                Text(estimate.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Password strength: \(estimate.summary)")
        }
    }

    private func color(for level: PasswordStrengthEstimate.Level) -> Color {
        switch level {
        case .veryWeak:
            .red
        case .weak:
            .orange
        case .good, .veryGood:
            .green
        }
    }
}
