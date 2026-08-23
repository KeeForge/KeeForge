import SwiftUI

struct FaviconView: View {
    let url: String?
    let iconID: Int
    let size: CGFloat
    /// Image data of the entry's custom icon from `Meta/CustomIcons`. Takes
    /// precedence over favicons and the standard-icon fallback.
    var customIconData: Data? = nil

    @State private var image: PlatformImage?
    @State private var didAttemptFetch = false
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var customIcon: PlatformImage? {
        customIconData.flatMap { PlatformImage(data: $0) }
    }

    private var domain: String? {
        guard let url else { return nil }
        return FaviconService.extractDomain(from: url)
    }

    private var showFavicons: Bool {
        SettingsService.showWebsiteIcons
    }

    var body: some View {
        Group {
            if let customIcon {
                Image(platformImage: customIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if showFavicons, let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .transition(.opacity)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .task(id: domain) {
            guard customIconData == nil, showFavicons, let domain, !didAttemptFetch else { return }
            // Check cache first (synchronous)
            if let cached = FaviconService.cachedImage(for: domain) {
                image = cached
                didAttemptFetch = true
                return
            }
            // Fetch in background
            didAttemptFetch = true
            if let fetched = await FaviconService.fetchFavicon(for: domain) {
                withAnimation(.easeIn(duration: 0.2)) {
                    image = fetched
                }
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: KPEntry.systemIconName(for: iconID))
            .foregroundStyle(fallbackIconStyle)
            .font(.system(size: size * 0.6))
    }

    /// A selected list row raises `backgroundProminence`, and only then is the
    /// row's fill the accent color — which `.tint` would render the glyph in
    /// too, leaving it accent-on-accent at 1.34:1. An unselected row, or a
    /// selected one in an unfocused list, keeps the accent glyph.
    private var fallbackIconStyle: AnyShapeStyle {
        backgroundProminence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.tint)
    }
}
