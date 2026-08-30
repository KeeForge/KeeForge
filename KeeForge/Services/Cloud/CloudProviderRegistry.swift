import Foundation

enum CloudProviderRegistry {
    /// Providers offered in the UI, filtered by the per-platform availability
    /// gate. On iOS `provider(for:)` below is intentionally NOT filtered, so
    /// already-connected databases keep resolving their provider and stay
    /// openable even when the provider is hidden from the add/import UI.
    ///
    /// macOS is the exception: the Mac app does not compile the Dropbox or
    /// OneDrive providers at all (WebDAV-only release — see the KeeForgeMac
    /// source excludes in project.yml), so `provider(for:)` returns nil for
    /// them there. Nothing can have connected one, because neither has ever
    /// been reachable from the Mac UI.
    static var availableProviders: [CloudProviderKind] {
        [.dropbox, .oneDrive, .webDAV].filter(\.isAvailableOnCurrentPlatform)
    }

    static func provider(for id: String) -> CloudProvider? {
        guard let provider = CloudProviderKind(rawValue: id) else { return nil }

        switch provider {
        case .dropbox:
            #if DEBUG
            if UITestDropboxCloudProvider.isEnabled {
                return UITestDropboxCloudProvider.shared
            }
            #endif
            #if os(macOS)
            return nil
            #else
            return DropboxCloudProvider.shared
            #endif
        case .oneDrive:
            #if os(macOS)
            return nil
            #else
            return OneDriveCloudProvider.shared
            #endif
        case .webDAV:
            #if DEBUG
            if UITestWebDAVCloudProvider.isEnabled {
                return UITestWebDAVCloudProvider.shared
            }
            #endif
            return WebDAVCloudProvider.shared
        }
    }

    @MainActor
    static func handleOpenURL(_ url: URL) -> Bool {
        #if DEBUG
        if UITestDropboxCloudProvider.isEnabled {
            return false
        }
        #endif
        #if os(macOS)
        // WebDAV is the only macOS provider and it has no OAuth redirect.
        return false
        #else
        return DropboxCloudProvider.shared.handleRedirectURL(url)
            || OneDriveCloudProvider.shared.handleRedirectURL(url)
        #endif
    }
}
