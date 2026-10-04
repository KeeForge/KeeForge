import SwiftUI

struct FaviconView: View {
    let url: String?
    let iconID: Int
    let size: CGFloat
    /// Image data of the entry's custom icon from `Meta/CustomIcons`. Takes
    /// precedence over favicons and the standard-icon fallback.
    var customIconData: Data? = nil

    @State private var loader = FaviconLoadModel()

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

    private var requestedDomain: String? {
        customIconData == nil && showFavicons ? domain : nil
    }

    var body: some View {
        Group {
            if let customIcon {
                Image(platformImage: customIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if showFavicons, loader.domain == requestedDomain, let image = loader.image {
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
        .task(id: requestedDomain) {
            await loader.load(domain: requestedDomain)
        }
    }

    private var fallbackIcon: some View {
        StandardIconView(iconID: iconID)
            .font(.system(size: size * 0.6))
    }
}

@MainActor @Observable
final class FaviconLoadModel {
    private(set) var image: PlatformImage?
    private(set) var domain: String?
    private var loadID = UUID()
    private let loadImage: @MainActor (String) async -> PlatformImage?

    init(loadImage: @escaping @MainActor (String) async -> PlatformImage? = {
        await FaviconService.favicon(for: $0)
    }) {
        self.loadImage = loadImage
    }

    func load(domain: String?) async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        loadID = requestID
        self.domain = domain
        image = nil
        guard let domain else { return }
        let fetched = await loadImage(domain)
        guard loadID == requestID, !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: 0.2)) {
            image = fetched
        }
    }
}
