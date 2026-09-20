import AuthenticationServices
import Foundation

/// Plain-FTP provider. Stateless like `WebDAVCloudProvider`: the credential
/// is read from `CloudTokenStore` on every call and every call opens its own
/// session.
///
/// `fileId` is the decoded path relative to the account's base folder (e.g.
/// `/Vaults/personal.kdbx`). FTP has no ETag, so `rev` is a SHA-256 of the
/// bytes the server returns; see `rev(of:)`.
final class FTPCloudProvider: CloudProvider, FTPConnecting, Sendable {
    static let shared = FTPCloudProvider()

    let id = CloudProviderKind.ftp.rawValue
    let displayName = CloudProviderKind.ftp.displayName
    let iconName = CloudProviderKind.ftp.iconName

    private let client: FTPClient
    private let now: @Sendable () -> Date
    private let makeScratchToken: @Sendable () -> String

    init(
        client: FTPClient = FTPClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeScratchToken: @escaping @Sendable () -> String = { String(UUID().uuidString.prefix(8)) }
    ) {
        self.client = client
        self.now = now
        self.makeScratchToken = makeScratchToken
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

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        let (location, credential) = try resolveContext(accountId: accountId)
        let path = Self.remotePath(base: location.basePath, fileId: fileId)

        let (data, metadata) = try await perform(context: .read, location: location, credential: credential) { session in
            let data = try await session.retrieve(path)
            return (data, await Self.metadata(of: data, at: path, in: session))
        }

        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localURL, options: .atomic)
        progress(1)
        return metadata
    }

    // MARK: - Metadata

    /// The rev is a hash of the bytes, so the probe is a full transfer.
    let metadataProbeTransfersContent = true

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let (location, credential) = try resolveContext(accountId: accountId)
        let path = Self.remotePath(base: location.basePath, fileId: fileId)

        return try await perform(context: .read, location: location, credential: credential) { session in
            guard let entry = try await session.stat(path), !entry.isFolder else {
                throw CloudProviderError.fileNotFound
            }
            let data = try await Self.retrieveExisting(path, in: session)
            return CloudFileMetadata(
                modifiedDate: entry.modifiedDate ?? .now,
                contentHash: nil,
                size: Int64(data.count),
                rev: Self.rev(of: data)
            )
        }
    }

    // MARK: - Upload

    /// Uploads to a temporary name beside the target and moves it into place
    /// (see `install`), so the database is never written in place. FTP has no
    /// conditional write: `expectedRev` is checked against a fresh download
    /// after the transfer, immediately before the move, which is as close to
    /// the write as the protocol allows.
    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        let (location, credential) = try resolveContext(accountId: accountId)
        let path = Self.remotePath(base: location.basePath, fileId: fileId)
        let temporaryPath = scratchPath(beside: path, kind: .upload)
        let backupPath = scratchPath(beside: path, kind: .backup)

        let metadata = try await perform(context: .write, location: location, credential: credential) { session in
            do {
                // Inside the cleanup: an interrupted transfer can leave a
                // partial file behind.
                try await session.store(temporaryPath, data: data)
                if let expectedRev {
                    guard let current = try await session.stat(path), !current.isFolder else {
                        throw CloudProviderError.conflict(remoteRev: nil)
                    }
                    let currentRev = Self.rev(of: try await Self.retrieveExisting(path, in: session))
                    guard currentRev == expectedRev else {
                        throw CloudProviderError.conflict(remoteRev: currentRev)
                    }
                }
                try await install(
                    temporaryPath,
                    at: path,
                    backupPath: backupPath,
                    expectedRev: expectedRev,
                    in: session,
                    location: location,
                    credential: credential
                )
            } catch {
                try? await session.delete(temporaryPath)
                throw error
            }
            await sweepStaleUploads(beside: path, in: session)
            return await Self.metadata(of: data, at: path, in: session)
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
        let temporaryPath = scratchPath(beside: path, kind: .upload)

        let metadata = try await perform(context: .write, location: location, credential: credential) { session in
            guard try await session.stat(path) == nil else {
                throw CloudProviderError.conflict(remoteRev: nil)
            }
            do {
                try await session.store(temporaryPath, data: data)
                guard try await session.stat(path) == nil else {
                    throw CloudProviderError.conflict(remoteRev: nil)
                }
                try await session.rename(temporaryPath, to: path)
            } catch {
                try? await session.delete(temporaryPath)
                throw error
            }
            await sweepStaleUploads(beside: path, in: session)
            return await Self.metadata(of: data, at: path, in: session)
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

    /// Moves the completed upload over `path`. Where the server will not
    /// rename onto an existing file (IIS), the database is first renamed to a
    /// backup beside it and renamed back if the upload cannot take its place.
    /// It is never written in place or deleted; the backup goes only once the
    /// upload is installed.
    private func install(
        _ temporaryPath: String,
        at path: String,
        backupPath: String,
        expectedRev: String?,
        in session: FTPSession,
        location: FTPServerLocation,
        credential: FTPCredential
    ) async throws {
        do {
            try await session.rename(temporaryPath, to: path)
            return
        } catch FTPClientError.renameRefused {}

        do {
            // Inside the restore: `RNTO` can be carried out and still lose its
            // reply, which would leave the database stranded under the backup
            // name with nothing at `path`.
            try await session.rename(path, to: backupPath)

            // Setting the file aside took it from every other client, so a
            // write since the caller's check shows up here, not as a lost
            // update.
            if let expectedRev {
                let setAsideRev = Self.rev(of: try await Self.retrieveExisting(backupPath, in: session))
                guard setAsideRev == expectedRev else {
                    throw CloudProviderError.conflict(remoteRev: setAsideRev)
                }
            }
            try await session.rename(temporaryPath, to: path)
        } catch {
            await restore(
                backupPath,
                to: path,
                discarding: temporaryPath,
                in: session,
                location: location,
                credential: credential
            )
            throw error
        }
        await discardBackup(backupPath, in: session, location: location, credential: credential)
    }

    /// Removes the backup now that the upload is installed, retrying over a
    /// fresh session because the install may have been the last thing this
    /// connection carried.
    ///
    /// This is the only point at which the backup is known to be redundant.
    /// Nothing later can establish that: a backup left behind is
    /// indistinguishable from the one an unrestorable install left as the
    /// database's only copy, and the name it belongs to may by then hold a
    /// different database entirely.
    private func discardBackup(
        _ backupPath: String,
        in session: FTPSession,
        location: FTPServerLocation,
        credential: FTPCredential
    ) async {
        if (try? await session.delete(backupPath)) != nil {
            return
        }
        let client = client
        await Task.detached {
            _ = try? await client.withSession(
                host: location.host,
                port: location.port,
                username: credential.username,
                password: credential.password
            ) { fresh in
                try await fresh.delete(backupPath)
            }
        }.value
    }

    /// Puts the backup back, on a fresh session if this one is gone: a
    /// timeout or cancellation closes the control connection. The fresh
    /// session runs detached so the caller's cancellation cannot stop it, and
    /// also removes the upload, which the dead session no longer can.
    private func restore(
        _ backupPath: String,
        to path: String,
        discarding temporaryPath: String,
        in session: FTPSession,
        location: FTPServerLocation,
        credential: FTPCredential
    ) async {
        if (try? await Self.moveBack(backupPath, to: path, in: session)) != nil {
            return
        }
        let client = client
        await Task.detached {
            _ = try? await client.withSession(
                host: location.host,
                port: location.port,
                username: credential.username,
                password: credential.password
            ) { fresh in
                try await Self.moveBack(backupPath, to: path, in: fresh)
                try? await fresh.delete(temporaryPath)
            }
        }.value
    }

    /// Leaves the backup where it is if anything already stands at `path`:
    /// that may be the upload, installed by a rename whose reply was lost.
    private static func moveBack(_ backupPath: String, to path: String, in session: FTPSession) async throws {
        guard try await session.stat(path) == nil else { return }
        try await session.rename(backupPath, to: path)
    }

    /// Deletes this app's upload leftovers in `path`'s folder that are old
    /// enough not to belong to a transfer still running. Best effort: a
    /// failure here never fails the save that just succeeded.
    ///
    /// Only uploads. An upload holds bytes the client still has, but a
    /// backup holds the only remaining copy of a database whose install
    /// could not be undone, and by then nothing on the server distinguishes
    /// that from a backup whose deletion merely failed — least of all the
    /// name being occupied again, which any later database takes.
    private func sweepStaleUploads(beside path: String, in session: FTPSession) async {
        guard let entries = try? await session.listDirectory(FTPListingParser.parentPath(of: path)) else {
            return
        }
        let cutoff = now().addingTimeInterval(-Self.staleUploadAge)
        for entry in entries where !entry.isFolder {
            guard let created = Self.creationDate(ofUploadScratchNamed: entry.name), created < cutoff else {
                continue
            }
            try? await session.delete(Self.sibling(of: path, named: entry.name))
        }
    }

    /// A 550 on RETR of a path known to exist is a refusal, not absence.
    private static func retrieveExisting(_ path: String, in session: FTPSession) async throws -> Data {
        do {
            return try await session.retrieve(path)
        } catch FTPClientError.unexpectedReply(let reply) where reply.code == 550 {
            throw FTPClientError.accessDenied(reply)
        }
    }

    /// The rev is the hash of the bytes this session transferred, not a
    /// re-read: a re-read could record another client's write as this one's.
    /// The stamp is only for display, so failing to read it never fails the
    /// transfer.
    private static func metadata(of data: Data, at path: String, in session: FTPSession) async -> CloudFileMetadata {
        let entry = try? await session.stat(path)
        return CloudFileMetadata(
            modifiedDate: entry?.modifiedDate ?? .now,
            contentHash: nil,
            size: Int64(data.count),
            rev: rev(of: data)
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
        case FTPClientError.unexpectedReply(let reply), FTPClientError.renameRefused(let reply):
            return mapReply(reply, context: context)
        case FTPClientError.accessDenied:
            return CloudProviderError.permissionDenied
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

    /// `sha256:<hex>` of the file's bytes. Modification stamps are usually
    /// whole seconds, so a stamp-and-size rev misses a same-size write inside
    /// one second; a KDBX re-encryption keeps its length.
    static func rev(of data: Data) -> String {
        "sha256:" + KDBXCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
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

    // MARK: - Scratch files

    enum ScratchKind: String {
        case upload = "keeforge-upload"
        case backup = "keeforge-backup"
    }

    /// Uploads older than this are leftovers of a failed save, not a transfer
    /// still running on another device.
    static let staleUploadAge: TimeInterval = 24 * 60 * 60

    private func scratchPath(beside path: String, kind: ScratchKind) -> String {
        let name = Self.scratchName(for: FTPListingParser.lastComponent(of: path), kind: kind, createdAt: now(), token: makeScratchToken())
        return Self.sibling(of: path, named: name)
    }

    /// `.<name>.<UTC time-val>-<token>.<kind>`: hidden and without the
    /// `.kdbx` extension, so it never shows up in a database listing. The
    /// time lets a later save tell a leftover from a transfer in flight.
    static func scratchName(for name: String, kind: ScratchKind, createdAt: Date, token: String) -> String {
        ".\(name).\(timeVal(for: createdAt))-\(token).\(kind.rawValue)"
    }

    /// The creation time of an upload scratch file, or nil for any name that
    /// does not match `scratchName` exactly. Backups never match: they are
    /// not swept, because nothing proves one is redundant.
    static func creationDate(ofUploadScratchNamed fileName: String) -> Date? {
        let suffix = "." + ScratchKind.upload.rawValue
        guard fileName.hasPrefix("."), fileName.hasSuffix(suffix) else { return nil }
        let stem = fileName.dropFirst().dropLast(suffix.count)
        guard let dot = stem.lastIndex(of: "."), dot > stem.startIndex else { return nil }
        let marker = stem[stem.index(after: dot)...]
        let parts = marker.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 14,
              parts[1].count == 8,
              parts[1].allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        return FTPListingParser.date(fromTimeVal: String(parts[0]))
    }

    private static func timeVal(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}
