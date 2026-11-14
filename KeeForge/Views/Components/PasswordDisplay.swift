import SwiftUI

enum PasswordVisualStyle {
    static let bulletCount = 12
    static let concealedText = String(repeating: "\u{2022}", count: bulletCount)
    static let segmentCount = 4
}

struct PasswordDisplayRow<Actions: View>: View {
    let revealedText: String?
    private let passwordAccessibilityIdentifier: String?
    private let maximumEntropyBits: Double
    /// The generator's suggestion: the design's larger password style on iOS.
    private let isProminent: Bool
    private let actions: Actions

    init(
        revealedText: String?,
        passwordAccessibilityIdentifier: String? = nil,
        maximumEntropyBits: Double = .infinity,
        isProminent: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.revealedText = revealedText
        self.passwordAccessibilityIdentifier = passwordAccessibilityIdentifier
        self.maximumEntropyBits = maximumEntropyBits
        self.isProminent = isProminent
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
                    Group {
                        if let passwordAccessibilityIdentifier {
                            PasswordDisplayText(revealedText, isProminent: isProminent)
                                .accessibilityIdentifier(passwordAccessibilityIdentifier)
                        } else {
                            PasswordDisplayText(revealedText, isProminent: isProminent)
                        }
                    }
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    PasswordConcealedText()
                }

                Spacer(minLength: 12)
                actions
            }

            if let revealedText {
                PasswordStrengthIndicator(password: revealedText, maximumEntropyBits: maximumEntropyBits)
                    .padding(.leading, 36)
            }
        }
    }
}

struct PasswordDisplayText: View {
    let password: String
    var isProminent = false
    /// Replaces the default monospaced body font (the Mac generator's large suggestion).
    var font: Font?

    init(_ password: String, isProminent: Bool = false, font: Font? = nil) {
        self.password = password
        self.isProminent = isProminent
        self.font = font
    }

    var body: some View {
        Text(styledPassword)
            .font(font ?? (isProminent && PlatformDesign.followsIOSDesign ? Theme.Font.password : .body.monospaced()))
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
            return PlatformDesign.followsIOSDesign ? Theme.digit : .blue
        } else {
            return PlatformDesign.followsIOSDesign ? Theme.symbol : .orange
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
    /// How the iOS row reads: "Strength ▬▬▬▬ Very good (~120 bits)", the meter
    /// then just the rating, or the meter then "Password strength: Very good".
    enum Caption {
        case strength
        case rating
        case passwordStrength
    }

    let password: String
    var maximumEntropyBits: Double = .infinity
    var caption: Caption = .strength

    private var estimate: PasswordStrengthEstimate? {
        PasswordStrengthEstimator.estimate(password, maximumEntropyBits: maximumEntropyBits)
    }

    var body: some View {
        if let estimate {
            if PlatformDesign.followsIOSDesign {
                StrengthRow(estimate: estimate, color: color(for: estimate.level), caption: caption)
            } else {
                legacyIndicator(estimate)
            }
        }
    }

    private func legacyIndicator(_ estimate: PasswordStrengthEstimate) -> some View {
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

    private func color(for level: PasswordStrengthEstimate.Level) -> Color {
        switch level {
        case .veryWeak:
            Theme.State.danger
        case .weak:
            Theme.State.warning
        case .good, .veryGood:
            Theme.State.success
        }
    }
}

/// Password strength as one row: "Strength", a four-segment meter, and the
/// rating in its color, so the color never stands alone.
private struct StrengthRow: View {
    let estimate: PasswordStrengthEstimate
    let color: Color
    let caption: PasswordStrengthIndicator.Caption

    @ScaledMetric(relativeTo: .subheadline) private var segmentWidth = Theme.Size.meterSegment.width
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if caption != .strength {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.tileGap) {
                        meter
                        trailingCaption
                            .lineLimit(1)
                            .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                        meter
                        trailingCaption
                    }
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                    label
                    HStack(spacing: Theme.Spacing.tileGap) {
                        meter
                        rating
                    }
                }
            } else {
                HStack(spacing: Theme.Spacing.tileGap) {
                    label
                    Spacer(minLength: 0)
                    meter
                    rating
                }
            }
        }
        .font(Theme.Font.subhead)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(estimate.summary)")
    }

    @ViewBuilder
    private var trailingCaption: some View {
        let rating = Text(estimate.level.title).fontWeight(.semibold).foregroundColor(color)
        if caption == .passwordStrength {
            Text("Password strength: \(rating)")
                .foregroundStyle(Theme.labelSecondary)
        } else {
            rating
        }
    }

    private var label: some View {
        Text("Strength")
            .foregroundStyle(Theme.labelSecondary)
    }

    private var meter: some View {
        HStack(spacing: Theme.Spacing.meterSegment) {
            ForEach(0..<PasswordVisualStyle.segmentCount, id: \.self) { index in
                Capsule()
                    .fill(index < estimate.level.filledSegments ? color : Theme.fill)
                    .frame(width: segmentWidth, height: Theme.Size.meterSegment.height)
            }
        }
    }

    private var rating: some View {
        Text(estimate.summary)
            .fontWeight(.semibold)
            .foregroundStyle(color)
    }
}
