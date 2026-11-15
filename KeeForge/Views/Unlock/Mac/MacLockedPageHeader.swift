#if os(macOS)
import SwiftUI

/// The top of every page a locked database window shows: a tile, the title
/// and one line about the file. The unlock, opening and recovery pages share
/// its metrics, so a hand-over between them never moves the title.
struct MacLockedPageHeader: View {
    enum Tile {
        /// The app-icon key on its ink tile, the boards' one brand spot.
        case brand
        /// A recovery page's problem glyph on a plain tile.
        case symbol(String)
    }

    let tile: Tile
    let title: String
    let subtitle: String

    static let tileSize: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            tileView
                .padding(.bottom, 22)
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if subtitle.isEmpty == false {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 6)
                    .accessibilityIdentifier("unlock.subtitle")
            }
        }
    }

    @ViewBuilder
    private var tileView: some View {
        switch tile {
        case .brand:
            Image("LaunchGlyph")
                .resizable()
                .interpolation(.high)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color(red: 0.22, green: 0.27, blue: 0.47).opacity(0.22), radius: 9, y: 6)
                .accessibilityHidden(true)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        }
    }
}

/// The locked pages' column: centred, scrolled only when the window is too
/// short for it, with an optional footer kept at the bottom.
struct MacLockedPageLayout<Content: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    content
                    Spacer(minLength: 40)
                    footer
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension MacLockedPageLayout where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        footer = EmptyView()
    }
}
#endif
