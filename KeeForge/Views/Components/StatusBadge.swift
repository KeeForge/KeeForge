import SwiftUI

/// The uppercase pill beside a name: a database's state, an expired entry.
struct StatusBadge: View {
    enum Tone {
        case accent
        case warning
        case danger
    }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(Theme.Font.badge)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(Theme.Spacing.badge)
            .background(background, in: Capsule())
    }

    private var foreground: AnyShapeStyle {
        switch tone {
        case .accent: AnyShapeStyle(.tint)
        case .warning: AnyShapeStyle(Theme.warning)
        case .danger: AnyShapeStyle(Theme.danger)
        }
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .accent: AnyShapeStyle(Theme.accentSoft)
        case .warning: AnyShapeStyle(Theme.fill)
        case .danger: AnyShapeStyle(Theme.dangerSoft)
        }
    }
}
