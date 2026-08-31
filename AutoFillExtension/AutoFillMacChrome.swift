#if os(macOS)
import SwiftUI

// The macOS shell hosts the extension's SwiftUI views as a child
// `NSHostingController` inside the system credential-provider window, which
// carries no `NSToolbar`. SwiftUI routes `.toolbar` content and `.searchable`
// fields to the window toolbar on macOS, so both are silently dropped there —
// the picker renders as a bare list with no title, no search field, no
// database switcher, and no Cancel, leaving the request unanswerable and the
// calling app blocked. These bars draw the same affordances inside the hosted
// view; iOS keeps the toolbar.

/// Leading-aligned bar above the hosted content, standing in for the
/// navigation bar iOS gets from `.navigationTitle` / `.toolbar`.
struct AutoFillMacHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
        }
        .background(.bar)
    }
}

/// Trailing-aligned bar below the hosted content, holding the actions iOS
/// places in the toolbar. Every view the macOS shell hosts must offer a way
/// out here.
struct AutoFillMacFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Spacer()
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}
#endif
