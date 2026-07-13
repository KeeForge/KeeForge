import Foundation

enum SecurityScopedBookmarkManager {
    // On macOS, sandboxed apps must create and resolve bookmarks with
    // `.withSecurityScope`; plain bookmarks resolve but grant no file access
    // after relaunch, which fails silently. iOS bookmarks carry security scope
    // implicitly and reject the macOS-only options.
    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    static func makeBookmarkData(for url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolveURL(from bookmarkData: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (url, isStale)
        }

        #if os(macOS)
        // Resolving a bookmark that was created WITHOUT `.withSecurityScope`
        // (e.g. older data) throws when `.withSecurityScope` is requested.
        // Fall back to a plain resolution so the URL is still usable where
        // sandbox access happens to be available; re-bookmarking on the next
        // save upgrades it to a security-scoped bookmark.
        isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (url, isStale)
        }
        #endif

        return nil
    }
}
