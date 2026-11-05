import SwiftUI

extension EnvironmentValues {
    /// The tip sits in a list row, whose own card it uses.
    @Entry var isListedTip = false
}

extension View {
    /// The card a dismissible tip on the database list sits in.
    ///
    /// No container-level accessibilityIdentifier: SwiftUI propagates it to
    /// every child element, clobbering the buttons' own ids.
    func tipBannerCard() -> some View {
        modifier(TipBannerCard())
    }
}

private struct TipBannerCard: ViewModifier {
    @Environment(\.isListedTip) private var isListedTip

    @ViewBuilder
    func body(content: Content) -> some View {
        if isListedTip {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.textLine)
        } else if PlatformDesign.followsIOSDesign {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.side)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding(.horizontal, Theme.Spacing.side)
                .padding(.top, Theme.Spacing.cardGap)
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
                .padding(.top, 8)
        }
    }
}
