import Foundation

enum CloudProviderRegistry {
    static var availableProviders: [CloudProviderKind] {
        [.dropbox, .oneDrive, .webDAV]
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
            // Slice 1: real provider only. The UI-test mock hook lands in a
            // later slice; when it does, branch here on the -ui-testing flag as
            // the Dropbox case does above.
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
