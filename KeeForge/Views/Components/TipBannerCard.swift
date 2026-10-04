import SwiftUI

extension View {
    /// The card a dismissible tip on the database list sits in.
    ///
    /// No container-level accessibilityIdentifier: SwiftUI propagates it to
    /// every child element, clobbering the buttons' own ids.
    func tipBannerCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
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
