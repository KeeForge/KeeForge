import Foundation

enum CloudProviderRegistry {
    static var availableProviders: [CloudProviderKind] {
        [.dropbox]
    }

    static func provider(for id: String) -> CloudProvider? {
        guard let provider = CloudProviderKind(rawValue: id) else { return nil }

        switch provider {
        case .dropbox:
            return DropboxCloudProvider.shared
        }
    }

    @MainActor
    static func handleOpenURL(_ url: URL) -> Bool {
        DropboxCloudProvider.shared.handleRedirectURL(url)
    }
}
