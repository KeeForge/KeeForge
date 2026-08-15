import Foundation

/// Resolves the file a database reference currently opens from — the shared
/// cached copy for cloud-backed references, the bookmark-resolved file for
/// local ones — and runs a synchronous read against it inside the security
/// scope. Callers are expected to run off the main thread.
enum DatabaseFileAccess {
    enum ResolutionFailure: Error, Equatable, Sendable {
        case cloudCacheMissing
        case localFileUnavailable
    }

    static func withReadableURL<T>(
        for reference: DatabaseReference,
        _ body: (URL) throws -> T
    ) throws -> T {
        if reference.isCloudBacked {
            guard let url = DatabaseListStore.cachedDatabaseURL(for: reference) else {
                throw ResolutionFailure.cloudCacheMissing
            }
            return try body(url)
        }

        guard case .available(let url) = DatabaseListStore.locateDatabaseFile(for: reference) else {
            throw ResolutionFailure.localFileUnavailable
        }

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }
}
