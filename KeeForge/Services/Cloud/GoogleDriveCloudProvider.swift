import AuthenticationServices
import CryptoKit
import Foundation

protocol GoogleDriveAuthorizing: Sendable {
    @MainActor var isConfigured: Bool { get }
    @MainActor func authorize(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> GoogleDriveGrant
    @MainActor func authorizeAccount(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> CloudAccount
    @MainActor func accessToken(accountID: String) async throws -> String
    @MainActor func cancel()
    func contains(accountID: String) -> Bool
    func remove(accountID: String)
}

extension GoogleDriveAuthorizing {
    @MainActor
    func authorizeAccount(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> CloudAccount {
        try await authorize(from: anchor, expectedAccountID: expectedAccountID).account
    }
}

struct GoogleDriveGrant: Sendable {
    let account: CloudAccount
    let pickedFileIDs: [String]
}

final class GoogleDriveCloudProvider: CloudFileSelecting {
    static let shared = GoogleDriveCloudProvider()
    let id = "googledrive"
    let displayName = "Google Drive"
    let iconName = "externaldrive.fill"
    private let authorization: any GoogleDriveAuthorizing
    private let transport: any GoogleDriveTransport
    private let creationEnabled: Bool
    private let accountLock = NSLock()
    private let upsertAccount: @Sendable (CloudAccount) -> Void
    private let removeAccount: @Sendable (String) -> Void
    private let isAccountConnected: @Sendable (String) -> Bool
    private static let fields = "id,name,mimeType,modifiedTime,size,version,headRevisionId,sha256Checksum,trashed"

    init(
        authorization: any GoogleDriveAuthorizing = GoogleDriveAuthorization(),
        transport: any GoogleDriveTransport = GoogleDriveURLSessionTransport(),
        creationEnabled: Bool = false,
        upsertAccount: @escaping @Sendable (CloudAccount) -> Void = { CloudAccountStore.upsert($0) },
        removeAccount: @escaping @Sendable (String) -> Void = { CloudAccountStore.remove(provider: "googledrive", accountId: $0) },
        isAccountConnected: @escaping @Sendable (String) -> Bool = { CloudAccountStore.isConnected(provider: "googledrive", accountId: $0) }
    ) {
        self.authorization = authorization
        self.transport = transport
        self.creationEnabled = creationEnabled
        self.upsertAccount = upsertAccount
        self.removeAccount = removeAccount
        self.isAccountConnected = isAccountConnected
    }

    @MainActor var isConfigurationAvailable: Bool { authorization.isConfigured }
    // Product, durable creation journal, and credentialed Picker verification remain external gates.
    var isAvailableForSynchronization: Bool { false }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        let account = try await authorization.authorizeAccount(from: anchor, expectedAccountID: nil)
        try Task.checkCancellation()
        try register(account)
        return account
    }

    @MainActor
    func selectFiles(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> [CloudDatabaseSelection] {
        let grant = try await authorization.authorize(from: anchor, expectedAccountID: expectedAccountID)
        try Task.checkCancellation()
        try register(grant.account)
        var selections: [CloudDatabaseSelection] = []
        for fileID in grant.pickedFileIDs {
            let item = try await resource(accountID: grant.account.id, fileID: fileID)
            guard !item.isFolder else { throw CloudProviderError.permissionDenied }
            selections.append(CloudDatabaseSelection(provider: id, account: grant.account, file: item.cloudFile))
        }
        return selections
    }

    @MainActor func cancelPendingAuthentication() { authorization.cancel() }
    func isAuthenticated(accountId: String) -> Bool { isAccountConnected(accountId) && authorization.contains(accountID: accountId) }
    func signOut(accountId: String) {
        accountLock.lock()
        defer { accountLock.unlock() }
        authorization.remove(accountID: accountId)
        removeAccount(accountId)
    }

    private func register(_ account: CloudAccount) throws {
        accountLock.lock()
        defer { accountLock.unlock() }
        guard authorization.contains(accountID: account.id) else { throw CloudProviderError.notAuthenticated }
        upsertAccount(account)
    }
    func writeGuarantee(expectedRev: String?, byteCount: Int) -> CloudWriteGuarantee { .disabled }

    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] {
        var q = "trashed = false"
        if let path, !path.isEmpty {
            guard GoogleDriveCallback.validID(path) else { throw CloudProviderError.invalidConfiguration }
            q += " and '\(path)' in parents"
        }
        if let query, !query.isEmpty {
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            q += " and name contains '\(escaped)'"
        }
        struct Page: Decodable { let files: [GoogleDriveResource]; let nextPageToken: String? }
        var token: String?
        var seenTokens = Set<String>()
        var files: [CloudFile] = []
        repeat {
            var parameters = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "spaces", value: "drive"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fields))")]
            if let token { parameters.append(URLQueryItem(name: "pageToken", value: token)) }
            let data = try await request(accountID: accountId, path: "files", query: parameters)
            let page = try JSONDecoder().decode(Page.self, from: data)
            for item in page.files where item.trashed != true {
                try item.validateIdentity()
                if CloudFile.isListed(name: item.name, isFolder: item.isFolder, includesAllFiles: includesAllFiles) {
                    files.append(item.cloudFile)
                }
            }
            token = page.nextPageToken
            if let token, !seenTokens.insert(token).inserted { throw CloudProviderError.serviceUnavailable }
        } while token != nil
        return files
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        try await resource(accountID: accountId, fileID: fileId).metadata()
    }

    func download(accountId: String, fileId: String, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata? {
        let data = try await media(accountID: accountId, fileID: fileId)
        let item = try await resource(accountID: accountId, fileID: fileId)
        try Task.checkCancellation()
        var metadata: CloudFileMetadata?
        // A later metadata observation only describes these bytes if its checksum and size match.
        if item.sha256Checksum == Self.sha256(data), item.size.flatMap(Int64.init) == Int64(data.count) {
            metadata = try item.metadata()
        }
        try data.write(to: localURL, options: .atomic)
        progress(1)
        return metadata
    }

    func upload(accountId: String, fileId: String, data: Data, expectedRev: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata {
        throw CloudProviderError.writeScopeRequired
    }

    func prepareFileCreationID(accountId: String) async throws -> String? {
        guard creationEnabled else { throw CloudProviderError.writeScopeRequired }
        struct IDs: Decodable { let ids: [String] }
        let data = try await request(accountID: accountId, path: "files/generateIds", query: [URLQueryItem(name: "count", value: "1"), URLQueryItem(name: "space", value: "drive"), URLQueryItem(name: "type", value: "files")])
        let ids = try JSONDecoder().decode(IDs.self, from: data).ids
        guard ids.count == 1, let id = ids.first, GoogleDriveCallback.validID(id) else { throw CloudProviderError.serviceUnavailable }
        return id
    }

    func createFile(accountId: String, path: String, data: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudCreatedFile {
        throw CloudProviderError.writeScopeRequired
    }

    func createFile(accountId: String, path: String, data: Data, creationID: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudCreatedFile {
        try await createFile(accountId: accountId, target: CloudFileCreationTarget(path: path), data: data, creationID: creationID, progress: progress)
    }

    func createFile(accountId: String, target: CloudFileCreationTarget, data: Data, creationID: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudCreatedFile {
        guard creationEnabled else { throw CloudProviderError.writeScopeRequired }
        guard let creationID, GoogleDriveCallback.validID(creationID) else { throw CloudProviderError.invalidConfiguration }
        guard !target.path.isEmpty, !target.path.unicodeScalars.contains(where: { $0.value == 0 }) else { throw CloudProviderError.invalidName }
        var attributes: [String: Any] = ["id": creationID, "name": target.path, "mimeType": "application/octet-stream"]
        if let parent = target.parentFileID {
            guard GoogleDriveCallback.validID(parent) else { throw CloudProviderError.invalidConfiguration }
            attributes["parents"] = [parent]
        }
        let metadata = try JSONSerialization.data(withJSONObject: attributes)
        var boundary: String
        repeat { boundary = "keeforge-" + UUID().uuidString } while data.range(of: Data(boundary.utf8)) != nil || metadata.range(of: Data(boundary.utf8)) != nil
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response: Data
        do {
            response = try await request(accountID: accountId, path: "files", query: [URLQueryItem(name: "uploadType", value: "multipart"), URLQueryItem(name: "fields", value: Self.fields)], method: "POST", body: body, contentType: "multipart/related; boundary=\(boundary)", upload: true)
        } catch CloudProviderError.conflict {
            // Only the caller's durable ID is reconciled. Never overwrite or choose a new ID.
            let existing = try await media(accountID: accountId, fileID: creationID)
            guard existing == data else { throw CloudProviderError.conflict(remoteRev: nil) }
            let item = try await resource(accountID: accountId, fileID: creationID)
            guard item.sha256Checksum == Self.sha256(data), item.size.flatMap(Int64.init) == Int64(data.count) else {
                throw CloudProviderError.conflict(remoteRev: item.version)
            }
            progress(1)
            return CloudCreatedFile(file: item.cloudFile, metadata: try item.metadata())
        }
        let item = try JSONDecoder().decode(GoogleDriveResource.self, from: response)
        try item.validateIdentity()
        guard item.id == creationID, item.size.flatMap(Int64.init) == Int64(data.count),
              item.sha256Checksum == nil || item.sha256Checksum == Self.sha256(data) else {
            throw CloudProviderError.serviceUnavailable
        }
        progress(1)
        return CloudCreatedFile(file: item.cloudFile, metadata: try item.metadata())
    }

    private func resource(accountID: String, fileID: String) async throws -> GoogleDriveResource {
        guard GoogleDriveCallback.validID(fileID) else { throw CloudProviderError.invalidConfiguration }
        let data = try await request(accountID: accountID, path: "files/\(fileID)", query: [URLQueryItem(name: "fields", value: Self.fields)])
        let item = try JSONDecoder().decode(GoogleDriveResource.self, from: data)
        try item.validateIdentity()
        guard item.id == fileID, item.trashed != true else { throw CloudProviderError.fileNotFound }
        return item
    }

    private func media(accountID: String, fileID: String) async throws -> Data {
        guard GoogleDriveCallback.validID(fileID) else { throw CloudProviderError.invalidConfiguration }
        return try await request(accountID: accountID, path: "files/\(fileID)", query: [URLQueryItem(name: "alt", value: "media")])
    }

    private func request(accountID: String, path: String, query: [URLQueryItem], method: String = "GET", body: Data? = nil, contentType: String? = nil, upload: Bool = false) async throws -> Data {
        guard isAuthenticated(accountId: accountID) else { throw CloudProviderError.notAuthenticated }
        let token = try await authorization.accessToken(accountID: accountID)
        try Task.checkCancellation()
        guard var components = URLComponents(string: upload ? "https://www.googleapis.com/upload/drive/v3/\(path)" : "https://www.googleapis.com/drive/v3/\(path)") else { throw CloudProviderError.invalidConfiguration }
        components.queryItems = query
        guard let url = components.url else { throw CloudProviderError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.send(request)
        try GoogleDriveResponse.check(data, response)
        return data
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private struct GoogleDriveResource: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let modifiedTime: String?
    let size: String?
    let version: String?
    let headRevisionId: String?
    let sha256Checksum: String?
    let trashed: Bool?

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    var date: Date? {
        guard let modifiedTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: modifiedTime) ?? ISO8601DateFormatter().date(from: modifiedTime)
    }
    var cloudFile: CloudFile { CloudFile(id: id, name: name, path: id, isFolder: isFolder, modifiedDate: date, size: size.flatMap(Int64.init)) }
    func validateIdentity() throws {
        guard GoogleDriveCallback.validID(id) else { throw CloudProviderError.serviceUnavailable }
    }
    func metadata() throws -> CloudFileMetadata {
        guard !isFolder, !mimeType.hasPrefix("application/vnd.google-apps."),
              let date, let size = size.flatMap(Int64.init), size >= 0 else { throw CloudProviderError.serviceUnavailable }
        return CloudFileMetadata(modifiedDate: date, contentHash: sha256Checksum.map { "sha256:" + $0 }, size: size, rev: version ?? headRevisionId)
    }
}
