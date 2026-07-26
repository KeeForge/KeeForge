import AuthenticationServices
import Foundation

/// WebDAV cloud provider. Stateless: the per-account `WebDAVCredential` is
/// fetched from `CloudTokenStore` on every call (off the main thread), so a
/// single shared instance safely serves all accounts.
///
/// `fileId` is the decoded, server-relative path (e.g. `/Vaults/personal.kdbx`);
/// the base URL lives with the credential. `rev` is the ETag verbatim.
final class WebDAVCloudProvider: CloudProvider, WebDAVConnecting, Sendable {
    static let shared = WebDAVCloudProvider()

    let id = CloudProviderKind.webDAV.rawValue
    let displayName = CloudProviderKind.webDAV.displayName
    let iconName = CloudProviderKind.webDAV.iconName

    private let client: WebDAVClient

    init(client: WebDAVClient = WebDAVClient(transport: WebDAVClient.liveTransport())) {
        self.client = client
    }

    // MARK: - Authentication

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        throw CloudProviderError.unknown(
            "WebDAV connections are added with a server address, username, and password. Use Add Database → WebDAV to reconnect."
        )
    }

    func isAuthenticated(accountId: String) -> Bool {
        credential(for: accountId) != nil
    }

    func signOut(accountId: String) {
        _ = CloudTokenStore.deleteToken(provider: id, accountId: accountId)
        CloudAccountStore.remove(provider: id, accountId: accountId)
    }

    /// Manual connect: normalize the URL, probe with credentials, persist the
    /// credential + account, and return the account.
    func connect(_ configuration: WebDAVConnectionConfiguration) async throws -> CloudAccount {
        let baseURL = try normalizedBaseURL(
            from: configuration.serverURL,
            allowsUnencryptedHTTP: configuration.allowsUnencryptedHTTP
        )
        let username = configuration.username

        let credential = WebDAVCredential(
            serverURL: baseURL.absoluteString,
            username: username,
            password: configuration.password
        )

        // Probe the collection root to validate credentials + WebDAV support.
        let response = try await client.probe(url: baseURL, credential: credential)
        if let error = WebDAVClient.mapHTTPStatus(response.statusCode, isPropfind: true, responseBody: response.data) {
            throw error
        }

        let accountId = WebDAVURL.accountId(normalizedBaseURL: baseURL, username: username)

        guard let payload = try? JSONEncoder().encode(credential),
              CloudTokenStore.setTokenData(payload, provider: id, accountId: accountId) else {
            throw CloudProviderError.unknown(String(localized: "Could not securely store the WebDAV credentials."))
        }

        let account = CloudAccount(
            id: accountId,
            displayName: WebDAVURL.displayName(normalizedBaseURL: baseURL, username: username),
            provider: id
        )
        CloudAccountStore.upsert(account)
        return account
    }

    // MARK: - Listing

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        let context = try resolveContext(accountId: accountId)
        let listURL = Self.url(forFolderPath: path, base: context.baseURL)

        let response = try await client.propfindList(url: listURL, credential: context.credential)
        if let error = WebDAVClient.mapHTTPStatus(response.statusCode, isPropfind: true, responseBody: response.data) {
            throw error
        }

        let resources = try WebDAVPropfindParser.parse(data: response.data, requestURL: listURL)
        let files = resources.compactMap { Self.makeCloudFile(from: $0, folderPath: path) }
        let filtered = Self.filter(files: files, query: query)
        return filtered.sorted(by: Self.sortCloudFiles)
    }

    // MARK: - Download

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        let context = try resolveContext(accountId: accountId)
        let fileURL = Self.url(forFileId: fileId, base: context.baseURL)

        let response = try await client.get(url: fileURL, credential: context.credential)
        if let error = WebDAVClient.mapHTTPStatus(response.statusCode, responseBody: response.data) {
            throw error
        }

        let directoryURL = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try response.data.write(to: localURL, options: .atomic)
        progress(1)

        // The GET's own ETag describes the bytes just written. Servers that
        // omit it on GET leave nothing to report, which is the same nil a
        // server without ETags produces everywhere else.
        guard let rev = Self.rev(from: response) else { return nil }
        return CloudFileMetadata(
            modifiedDate: Self.date(fromLastModified: response.lastModified) ?? .now,
            contentHash: nil,
            size: Int64(response.data.count),
            rev: rev
        )
    }

    // MARK: - Metadata

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let context = try resolveContext(accountId: accountId)
        let fileURL = Self.url(forFileId: fileId, base: context.baseURL)

        // Use the WebDAV-native metadata operation directly. A number of small
        // local HTTP WebDAV servers accept PROPFIND but leave HEAD requests
        // unanswered; on a first open that prevented KeeForge from ever
        // reaching the GET that creates the shared cached copy.
        let probe = try await client.probe(url: fileURL, credential: context.credential)
        if let error = WebDAVClient.mapHTTPStatus(probe.statusCode, isPropfind: true, responseBody: probe.data) {
            throw error
        }

        let resources = try WebDAVPropfindParser.parse(
            data: probe.data,
            requestURL: fileURL,
            includeSelf: true
        )
        guard let resource = resources.first else {
            throw CloudProviderError.fileNotFound
        }

        return CloudFileMetadata(
            modifiedDate: resource.lastModified ?? .now,
            contentHash: nil,
            size: resource.contentLength ?? 0,
            rev: Self.rev(eTag: resource.eTag, lastModified: nil)
        )
    }

    // MARK: - Upload

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        let context = try resolveContext(accountId: accountId)
        let fileURL = Self.url(forFileId: fileId, base: context.baseURL)

        // Only send If-Match for strong ETags. Weak (W/"…") and lastmod-derived
        // revs are unreliable conditionals, so we upload unconditionally.
        let ifMatch = Self.strongIfMatchValue(from: expectedRev)

        let response = try await client.put(
            url: fileURL,
            credential: context.credential,
            data: data,
            ifMatch: ifMatch
        )

        if response.statusCode == 412 {
            let freshRev = try? await freshRev(fileURL: fileURL, credential: context.credential)
            throw CloudProviderError.conflict(remoteRev: freshRev)
        }

        if let error = WebDAVClient.mapHTTPStatus(response.statusCode, responseBody: response.data) {
            throw error
        }

        progress(1)

        // A PUT response may omit the ETag; if so, do a follow-up HEAD for an
        // authoritative rev to avoid a spurious re-download on the next open.
        if let rev = Self.rev(from: response) {
            return CloudFileMetadata(
                modifiedDate: Self.date(fromLastModified: response.lastModified) ?? .now,
                contentHash: nil,
                size: Int64(data.count),
                rev: rev
            )
        }

        let head = try? await client.head(url: fileURL, credential: context.credential)
        return CloudFileMetadata(
            modifiedDate: Self.date(fromLastModified: head?.lastModified) ?? .now,
            contentHash: nil,
            size: Int64(data.count),
            rev: head.flatMap { Self.rev(from: $0) }
        )
    }

    // MARK: - Create

    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        let context = try resolveContext(accountId: accountId)
        let fileURL = Self.url(forFileId: path, base: context.baseURL)

        let response = try await client.put(
            url: fileURL,
            credential: context.credential,
            data: data,
            ifNoneMatch: "*"
        )

        if response.statusCode == 412 {
            throw CloudProviderError.conflict(remoteRev: nil)
        }

        if let error = WebDAVClient.mapHTTPStatus(response.statusCode, responseBody: response.data) {
            throw error
        }

        progress(1)

        let rev: String?
        let modifiedDate: Date
        if let putRev = Self.rev(from: response) {
            rev = putRev
            modifiedDate = Self.date(fromLastModified: response.lastModified) ?? .now
        } else {
            let head = try? await client.head(url: fileURL, credential: context.credential)
            rev = head.flatMap { Self.rev(from: $0) }
            modifiedDate = Self.date(fromLastModified: head?.lastModified) ?? .now
        }

        let normalizedPath = Self.serverRelativePath(from: path)
        let file = CloudFile(
            id: normalizedPath,
            name: WebDAVPropfindParser.lastComponent(of: normalizedPath),
            path: normalizedPath,
            isFolder: false,
            modifiedDate: modifiedDate,
            size: Int64(data.count)
        )
        let metadata = CloudFileMetadata(
            modifiedDate: modifiedDate,
            contentHash: nil,
            size: Int64(data.count),
            rev: rev
        )
        return CloudCreatedFile(file: file, metadata: metadata)
    }

    // MARK: - Context resolution

    private struct AccountContext {
        let baseURL: URL
        let credential: WebDAVCredential
    }

    private func resolveContext(accountId: String) throws -> AccountContext {
        guard let credential = credential(for: accountId) else {
            throw CloudProviderError.notAuthenticated
        }
        guard let baseURL = URL(string: credential.serverURL) else {
            throw CloudProviderError.invalidConfiguration
        }
        return AccountContext(baseURL: baseURL, credential: credential)
    }

    private func credential(for accountId: String) -> WebDAVCredential? {
        guard let data = CloudTokenStore.tokenData(provider: id, accountId: accountId) else {
            return nil
        }
        return try? JSONDecoder().decode(WebDAVCredential.self, from: data)
    }

    private func normalizedBaseURL(
        from raw: String,
        allowsUnencryptedHTTP: Bool
    ) throws -> URL {
        do {
            return try WebDAVURL.normalizedBaseURL(
                from: raw,
                allowsUnencryptedHTTP: allowsUnencryptedHTTP
            )
        } catch WebDAVURLError.insecureScheme {
            throw CloudProviderError.unknown(
                "WebDAV requires an https:// server address unless unencrypted HTTP is explicitly allowed."
            )
        } catch {
            throw CloudProviderError.unknown(String(localized: "The server address is not a valid URL."))
        }
    }

    private func freshRev(fileURL: URL, credential: WebDAVCredential) async throws -> String? {
        let head = try await client.head(url: fileURL, credential: credential)
        return Self.rev(from: head)
    }

    // MARK: - URL / fileId mapping

    /// Resolves a decoded, server-relative `fileId` against the account base URL.
    static func url(forFileId fileId: String, base: URL) -> URL {
        appending(serverRelativePath: fileId, to: base, isDirectory: false)
    }

    /// Resolves a (possibly nil) folder path against the base URL. `nil` / "/"
    /// returns the base URL itself.
    static func url(forFolderPath path: String?, base: URL) -> URL {
        let relative = serverRelativePath(from: path ?? "/")
        if relative == "/" {
            return base
        }
        return appending(serverRelativePath: relative, to: base, isDirectory: true)
    }

    private static func appending(serverRelativePath relative: String, to base: URL, isDirectory: Bool) -> URL {
        // Percent-encode each decoded path segment and append to the base path.
        let segments = relative
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment -> String in
                String(segment).addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed)
                    ?? String(segment)
            }

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        // The prefix must stay percent-encoded: `base.path` decodes, and mixing a
        // decoded base (e.g. mailbox.org's ".../Meine Dateien/") into the
        // `percentEncodedPath` setter is a fatalError, not a thrown error.
        var basePath = components.percentEncodedPath
        if !basePath.hasSuffix("/") {
            basePath += "/"
        }
        var encodedPath = basePath + segments.joined(separator: "/")
        if isDirectory, !encodedPath.hasSuffix("/") {
            encodedPath += "/"
        }
        components.percentEncodedPath = encodedPath
        return components.url ?? base
    }

    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    /// Normalizes a decoded path to a leading-slash, no-trailing-slash form.
    static func serverRelativePath(from path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
        var result = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    // MARK: - Rev / ETag semantics

    /// Computes a `rev` from a response: prefer strong `ETag`, fall back to
    /// `OC-ETag`, then `"lastmod:" + Last-Modified`, then nil.
    static func rev(from response: WebDAVClient.Response) -> String? {
        rev(eTag: response.eTag ?? response.ocETag, lastModified: response.lastModified)
    }

    static func rev(eTag: String?, lastModified: String?) -> String? {
        if let eTag, !eTag.isEmpty {
            return eTag
        }
        if let lastModified, !lastModified.isEmpty {
            return "lastmod:" + lastModified
        }
        return nil
    }

    /// Returns an `If-Match` value only for strong ETags. Weak (`W/"…"`),
    /// lastmod-derived, and empty revs return nil (upload unconditionally).
    static func strongIfMatchValue(from expectedRev: String?) -> String? {
        guard let rev = expectedRev, !rev.isEmpty else { return nil }
        if rev.hasPrefix("lastmod:") { return nil }
        if rev.hasPrefix("W/") || rev.hasPrefix("w/") { return nil }
        return rev
    }

    static func date(fromLastModified value: String?) -> Date? {
        WebDAVPropfindParser.parseRFC1123(value)
    }

    // MARK: - CloudFile mapping / filtering / sorting

    private static func makeCloudFile(from resource: WebDAVResource, folderPath: String?) -> CloudFile? {
        if !resource.isFolder {
            guard resource.name.lowercased().hasSuffix(".kdbx") else { return nil }
        }

        let fullPath = joinedPath(folder: folderPath, name: resource.name)
        return CloudFile(
            id: fullPath,
            name: resource.name,
            path: fullPath,
            isFolder: resource.isFolder,
            modifiedDate: resource.lastModified,
            size: resource.contentLength
        )
    }

    /// Builds the server-relative path of a child from its parent folder path.
    /// The parser strips the base prefix, so its `resource.path` is already
    /// relative to the listed folder; we re-anchor it to the folder path.
    private static func joinedPath(folder: String?, name: String) -> String {
        let base = serverRelativePath(from: folder ?? "/")
        if base == "/" {
            return "/" + name
        }
        return base + "/" + name
    }

    private static func filter(files: [CloudFile], query: String?) -> [CloudFile] {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return files
        }
        let lowered = query.lowercased()
        return files.filter { $0.name.lowercased().contains(lowered) }
    }

    private static func sortCloudFiles(_ lhs: CloudFile, _ rhs: CloudFile) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
