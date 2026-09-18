import AuthenticationServices
import Foundation

/// Plain-FTP provider. Stateless like `WebDAVCloudProvider`: the credential
/// is read from `CloudTokenStore` on every call and every call opens its own
/// session.
///
/// `fileId` is the decoded path relative to the account's base folder (e.g.
/// `/Vaults/personal.kdbx`). FTP has no ETag, so `rev` is derived from the
/// server's modification stamp and size; see `rev(for:)`.
final class FTPCloudProvider: CloudProvider, FTPConnecting, Sendable {
    static let shared = FTPCloudProvider()

    let id = CloudProviderKind.ftp.rawValue
    let displayName = CloudProviderKind.ftp.displayName
    let iconName = CloudProviderKind.ftp.iconName

    private let client: FTPClient
    private let makeTemporaryName: @Sendable (String) -> String

    init(
        client: FTPClient = FTPClient(),
        makeTemporaryName: @escaping @Sendable (String) -> String = FTPCloudProvider.temporaryName(for:)
    ) {
        self.client = client
        self.makeTemporaryName = makeTemporaryName
    }

    // MARK: - Authentication

    /// Reached from the Reconnect action after a rejected login; FTP has no
    /// hosted sign-in to present, so point the user back at the connect form.
    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        throw CloudProviderError.unknown(
            String(localized: "Reconnect by adding the FTP server again with its address, username, and password.")
        )
    }

    func isAuthenticated(accountId: String) -> Bool {
        credential(for: accountId) != nil
    }

    func signOut(accountId: String) {
        _ = CloudTokenStore.deleteToken(provider: id, accountId: accountId)
        CloudAccountStore.remove(provider: id, accountId: accountId)
    }

    /// Normalizes the address, logs in, and checks the base folder exists
    /// before anything is persisted.
    func connect(_ configuration: FTPConnectionConfiguration) async throws -> CloudAccount {
        let baseURL = try FTPURL.normalizedBaseURL(
            from: configuration.serverURL,
            allowsUnencryptedFTP: configuration.allowsUnencryptedFTP
        )
        guard let location = FTPURL.location(fromNormalizedBaseURL: baseURL) else {
            throw FTPURLError.malformed
        }

        let credential = FTPCredential(
            serverURL: baseURL.absoluteString,
            username: configuration.username,
            password: configuration.password
        )

        try await perform(context: .read, location: location, credential: credential) { session in
            try await session.changeDirectory(location.basePath)
        }

        let accountId = FTPURL.accountId(normalizedBaseURL: baseURL, username: configuration.username)
        guard let payload = try? JSONEncoder().encode(credential),
              CloudTokenStore.setTokenData(payload, provider: id, accountId: accountId) else {
            throw CloudProviderError.unknown(String(localized: "Could not securely store the FTP credentials."))
        }

        let account = CloudAccount(
            id: accountId,
            displayName: FTPURL.displayName(normalizedBaseURL: baseURL, username: configuration.username),
            provider: id
        )
        CloudAccountStore.upsert(account)
        return account
    }

    // MARK: - Listing

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        let (location, credential) = try resolveContext(accountId: accountId)
        let folderId = Self.serverRelativePath(from: path ?? "/")
        let folder = Self.remotePath(base: location.basePath, fileId: folderId)

        let entries = try await perform(context: .read, location: location, credential: credential) { session in
            try await session.changeDirectory(folder)
            return try await session.listCurrentDirectory()
        }

        let files = entries.compactMap { entry -> CloudFile? in
            guard entry.isFolder || entry.name.lowercased().hasSuffix(".kdbx") else { return nil }
            let fileId = folderId == "/" ? "/" + entry.name : folderId + "/" + entry.name
            return CloudFile(
                id: fileId,
                name: entry.name,
                path: fileId,
                isFolder: entry.isFolder,
                modifiedDate: entry.modifiedDate,
                size: entry.size
            )
        }

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return files
            .filter { trimmedQuery.isEmpty || $0.name.lowercased().contains(trimmedQuery) }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder {
                    return lhs.isFolder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Download

    /// Returns nil metadata: FTP cannot tie a modification stamp to the bytes
    /// of one transfer, and a stamp read afterwards may already describe a
    /// newer file than the one written here.
    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        let (location, credential) = try resolveContext(accountId: accountId)
        let path = Self.remotePath(base: location.basePath, fileId: fileId)

        let data = try await perform(context: .read, location: location, credential: credential) { session in
            try await session.retrieve(path)
        }

        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localURL, options: .atomic)
        progress(1)
        return nil
    }

    // MARK: - Metadata

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let (location, credential) = try resolveContext(accountId: accountId)
        let path = Self.remotePath(base: location.basePath, fileId: fileId)

        return try await perform(context: .read, location: location, credential: credential) { session in
            try await Self.metadata(of: path, in: session)
        }
    }

    // MARK: - Upload

    /// Uploads to a temporary name beside the target and renames it into
    /// place, so an interrupted transfer never leaves a truncated database.
    /// FTP has no conditional write; `expectedRev` is re-checked after the
    /// transfer, immediately before the rename, which is as close to the
    /// write as the protocol allows.
    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        let (location, credential) = try resolveContext(accountId: accountId)
        let path = Self.remotePath(base: location.basePath, fileId: fileId)
        let temporaryPath = Self.sibling(of: path, named: makeTemporaryName(FTPListingParser.lastComponent(of: path)))

        let metadata = try await perform(context: .write, location: location, credential: credential) { session in
            try await session.store(temporaryPath, data: data)

            if let expectedRev {
                let current = try await session.stat(path)
                let currentRev = current.flatMap(Self.rev(for:))
                guard currentRev == expectedRev else {
                    try? await session.delete(temporaryPath)
                    throw CloudProviderError.conflict(remoteRev: currentRev)
                }
            }

            try await Self.replace(path, with: temporaryPath, data: data, in: session)
            return try await Self.metadata(of: path, in: session)
        }
        progress(1)
        return metadata
    }

    // MARK: - Create

    /// Create-only: refuses a name that already exists, checked before the
    /// transfer and again before the rename. FTP offers no exclusive create,
    /// so a file appearing between that last check and the rename would be
    /// replaced on servers whose rename overwrites.
    func createFile(
        accountId: String,
        path fileId: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        let (location, credential) = try resolveContext(accountId: accountId)
        let normalizedId = Self.serverRelativePath(from: fileId)
        let path = Self.remotePath(base: location.basePath, fileId: normalizedId)
        let temporaryPath = Self.sibling(of: path, named: makeTemporaryName(FTPListingParser.lastComponent(of: path)))

        let metadata = try await perform(context: .write, location: location, credential: credential) { session in
            guard try await session.stat(path) == nil else {
                throw CloudProviderError.conflict(remoteRev: nil)
            }
            try await session.store(temporaryPath, data: data)
            guard try await session.stat(path) == nil else {
                try? await session.delete(temporaryPath)
                throw CloudProviderError.conflict(remoteRev: nil)
            }
            try await session.rename(temporaryPath, to: path)
            return try await Self.metadata(of: path, in: session)
        }
        progress(1)

        let file = CloudFile(
            id: normalizedId,
            name: FTPListingParser.lastComponent(of: normalizedId),
            path: normalizedId,
            isFolder: false,
            modifiedDate: metadata.modifiedDate,
            size: metadata.size
        )
        return CloudCreatedFile(file: file, metadata: metadata)
    }

    // MARK: - Session helpers

    /// Moves the uploaded temporary file over `path`. Servers that refuse to
    /// rename onto an existing file (IIS) get the bytes written in place
    /// instead: less atomic, but it never deletes the database first.
    private static func replace(
        _ path: String,
        with temporaryPath: String,
        data: Data,
        in session: FTPSession
    ) async throws {
        do {
            try await session.rename(temporaryPath, to: path)
        } catch FTPClientError.unexpectedReply(let reply) where reply.code == 550 || reply.code == 553 {
            try await session.store(path, data: data)
            try? await session.delete(temporaryPath)
        }
    }

    private static func metadata(of path: String, in session: FTPSession) async throws -> CloudFileMetadata {
        guard let entry = try await session.stat(path), !entry.isFolder else {
            throw CloudProviderError.fileNotFound
        }
        return CloudFileMetadata(
            modifiedDate: entry.modifiedDate ?? .now,
            contentHash: nil,
            size: entry.size ?? 0,
            rev: rev(for: entry)
        )
    }

    enum OperationContext {
        case read
        case write
    }

    private func perform<T: Sendable>(
        context: OperationContext,
        location: FTPServerLocation,
        credential: FTPCredential,
        _ body: (FTPSession) async throws -> T
    ) async throws -> T {
        do {
            return try await client.withSession(
                host: location.host,
                port: location.port,
                username: credential.username,
                password: credential.password,
                body
            )
        } catch {
            throw Self.mapError(error, context: context)
        }
    }

    private func resolveContext(accountId: String) throws -> (FTPServerLocation, FTPCredential) {
        guard let credential = credential(for: accountId) else {
            throw CloudProviderError.notAuthenticated
        }
        guard let url = URL(string: credential.serverURL),
              let location = FTPURL.location(fromNormalizedBaseURL: url) else {
            throw CloudProviderError.invalidConfiguration
        }
        return (location, credential)
    }

    private func credential(for accountId: String) -> FTPCredential? {
        guard let data = CloudTokenStore.tokenData(provider: id, accountId: accountId) else {
            return nil
        }
        return try? JSONDecoder().decode(FTPCredential.self, from: data)
    }

    // MARK: - Error mapping

    private static func mapError(_ error: Error, context: OperationContext) -> Error {
        switch error {
        case is CancellationError, is CloudProviderError, is FTPURLError:
            return error
        case FTPClientError.unexpectedReply(let reply):
            return mapReply(reply, context: context)
        case FTPClientError.illegalArgument:
            return CloudProviderError.invalidName
        case FTPClientError.malformedReply(let text):
            return CloudProviderError.unknown(text)
        default:
            // Connection refused, DNS, timeouts, and dropped connections.
            return CloudProviderError.networkUnavailable
        }
    }

    static func mapReply(_ reply: FTPReply, context: OperationContext) -> CloudProviderError {
        switch reply.code {
        case 530, 532:
            return .notAuthenticated
        case 421, 450, 451:
            return .serviceUnavailable
        case 425, 426:
            return .networkUnavailable
        case 452, 552:
            return .insufficientSpace
        case 553:
            return .invalidName
        case 550:
            return context == .write ? .permissionDenied : .fileNotFound
        default:
            return .unknown("\(reply.code) \(reply.message)")
        }
    }

    // MARK: - Rev

    /// `mtime:<stamp>;size:<bytes>`, or nil when the server reports no
    /// modification stamp. Stamps are usually whole seconds, so two writes of
    /// the same size inside one second are indistinguishable.
    static func rev(for entry: FTPListEntry) -> String? {
        guard let stamp = entry.modifiedStamp else { return nil }
        return "mtime:\(stamp);size:\(entry.size.map(String.init) ?? "?")"
    }

    // MARK: - Paths

    /// Joins the account's base folder and a `fileId` into the path sent to
    /// the server.
    static func remotePath(base: String, fileId: String) -> String {
        let relative = serverRelativePath(from: fileId)
        let suffix = relative == "/" ? "" : String(relative.dropFirst())
        if base.isEmpty { return suffix }
        if suffix.isEmpty { return base }
        return base.hasSuffix("/") ? base + suffix : base + "/" + suffix
    }

    /// Leading-slash, no-trailing-slash form of a decoded path.
    static func serverRelativePath(from path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
        var result = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func sibling(of path: String, named name: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return name }
        return String(path[...slash]) + name
    }

    /// A hidden name without the `.kdbx` extension, so an upload in flight
    /// never shows up in a database listing.
    static func temporaryName(for name: String) -> String {
        ".\(name).\(UUID().uuidString.prefix(8)).keeforge-upload"
    }
}
