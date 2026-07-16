import Foundation

enum CloudProviderRegistry {
    /// Providers offered in the UI, filtered by the per-platform availability
    /// gate. `provider(for:)` below is intentionally NOT filtered so that
    /// already-connected databases keep resolving their provider and stay
    /// openable even when the provider is hidden from the add/import UI.
    static var availableProviders: [CloudProviderKind] {
        [.dropbox, .oneDrive, .webDAV].filter(\.isAvailableOnCurrentPlatform)
    }

    static func provider(for id: String) -> CloudProvider? {
        guard let provider = CloudProviderKind(rawValue: id) else { return nil }

        switch provider {
        case .dropbox:
            if UITestDropboxCloudProvider.isEnabled {
                return UITestDropboxCloudProvider.shared
            }
            return DropboxCloudProvider.shared
        case .oneDrive:
            return OneDriveCloudProvider.shared
        case .webDAV:
            if UITestWebDAVCloudProvider.isEnabled {
                return UITestWebDAVCloudProvider.shared
            }
            return WebDAVCloudProvider.shared
        }
    }

    @MainActor
    static func handleOpenURL(_ url: URL) -> Bool {
        if UITestDropboxCloudProvider.isEnabled {
            return false
        }
        return DropboxCloudProvider.shared.handleRedirectURL(url)
            || OneDriveCloudProvider.shared.handleRedirectURL(url)
    }
}
