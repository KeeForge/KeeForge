import Foundation

enum CloudProviderRegistry {
    static var availableProviders: [CloudProviderKind] {
        [.dropbox]
    }

    static func provider(for id: String) -> CloudProvider? {
        guard let provider = CloudProviderKind(rawValue: id) else { return nil }

        switch provider {
        case .dropbox:
            if UITestDropboxCloudProvider.isEnabled {
                return UITestDropboxCloudProvider.shared
            }
            return DropboxCloudProvider.shared
        }
    }

    @MainActor
    static func handleOpenURL(_ url: URL) -> Bool {
        if UITestDropboxCloudProvider.isEnabled {
            return false
        }
        return DropboxCloudProvider.shared.handleRedirectURL(url)
    }
}
