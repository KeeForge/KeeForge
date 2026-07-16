import SwiftUI

struct FaviconView: View {
    let url: String?
    let iconID: Int
    let size: CGFloat

    @State private var image: PlatformImage?
    @State private var didAttemptFetch = false

    private var domain: String? {
        guard let url else { return nil }
        return FaviconService.extractDomain(from: url)
    }

    private var showFavicons: Bool {
        SettingsService.showWebsiteIcons
    }

    var body: some View {
        Group {
            if showFavicons, let image {
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
            guard showFavicons, let domain, !didAttemptFetch else { return }
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
            .foregroundStyle(.tint)
            .font(.system(size: size * 0.6))
    }
}

// MARK: - Static icon name helper

extension KPEntry {
    static func systemIconName(for iconID: Int) -> String {
        switch iconID {
        case 0: "key.fill"
        case 1: "globe"
        case 62: "creditcard.fill"
        case 68: "at"
        default: "key.fill"
        }
    }
}
