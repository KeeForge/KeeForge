#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation

final class GoogleDriveCloudProvider: CloudObservedUploadProvider {
    static let shared = GoogleDriveCloudProvider()
    let id = CloudProviderKind.googleDrive.rawValue
    let displayName = CloudProviderKind.googleDrive.displayName
    let iconName = CloudProviderKind.googleDrive.iconName
    private let authorization: GoogleDriveAuthorization
    private let transport: any GoogleDriveTransport
    var isConfigured: Bool { authorization.configuration != nil }

    init(authorization: GoogleDriveAuthorization = GoogleDriveAuthorization(),
         transport: any GoogleDriveTransport = GoogleDriveURLSessionTransport()) {
        self.authorization = authorization
        self.transport = transport
    }

    @MainActor
    func selectDatabase(from anchor: ASPresentationAnchor, reconnecting expected: CloudSyncMetadata? = nil) async throws -> CloudDatabaseSelection {
        try await authorization.select(from: anchor, expected: expected) { grant in
            let token = grant.token.accessToken
            let account = try await account(accessToken: token)
            guard expected == nil || expected?.accountId == account.id else { throw CloudProviderError.permissionDenied }
            let item = try await resource(fileID: grant.fileID, token: token)
            _ = try item.metadata()
            guard item.isWritable,
                  expected != nil || CloudFile.isListed(name: item.name, isFolder: false, includesAllFiles: false) else {
                throw CloudProviderError.permissionDenied
            }
            return CloudDatabaseSelection(provider: id, account: account, file: item.file)
        }
    }

    @MainActor
    func reconnect(from anchor: ASPresentationAnchor, reference: DatabaseReference) async throws -> DatabaseReference {
        guard let metadata = reference.cloudSyncMetadata, metadata.provider == id else {
            throw CloudProviderError.invalidConfiguration
        }
        _ = try await selectDatabase(from: anchor, reconnecting: metadata)
        try Task.checkCancellation()
        let updated = await Task.detached {
            DatabaseListStore.updateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: metadata, observedReference: reference) {
                if $0.lastSyncIssue == .notAuthenticated || $0.lastSyncIssue == .writeScopeRequired {
                    $0.lastSyncIssue = nil
                }
            }
        }.value
        guard let updated, updated.cloudSyncMetadata?.provider == id,
              updated.cloudSyncMetadata?.accountId == metadata.accountId,
              updated.cloudSyncMetadata?.fileId == metadata.fileId else { throw SaveError.saveContextUnavailable }
        return updated
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        try await selectDatabase(from: anchor).account
    }

    @MainActor
    func cancelPendingAuthentication() { authorization.cancel() }

    func isAuthenticated(accountId: String) -> Bool { authorization.contains(accountID: accountId) }

    func signOut(accountId: String) {
        authorization.signOut(accountID: accountId)
    }

    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] {
        throw CloudProviderError.invalidConfiguration
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let token = try await authorization.accessToken(accountID: accountId)
        return try await resource(fileID: fileId, token: token).metadata()
    }

    func revisionIdentifiesContent(_ revision: String?) -> Bool { revision?.isEmpty == false }

    func download(accountId: String, fileId: String, to localURL: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata? {
        let token = try await authorization.accessToken(accountID: accountId)
        let path = try Self.filePath(fileId)
        for _ in 0..<2 {
            let item = try await resource(fileID: fileId, token: token)
            let metadata = try item.metadata()
            let data = try await request(path, query: [URLQueryItem(name: "alt", value: "media")], token: token)
            guard item.matches(bytes: data) else { continue }
            try Task.checkCancellation()
            try data.write(to: localURL)
            progress(1)
            return metadata
        }
        throw CloudProviderError.serviceUnavailable
    }

    func writeGuarantee(expectedRev: String?, byteCount: Int) -> CloudWriteGuarantee {
        .preflightOnly
    }

    func upload(accountId: String, fileId: String, data: Data, expectedRev: String?,
                progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata {
        throw CloudProviderError.writeScopeRequired
    }

    func upload(accountId: String, fileId: String, data: Data, observed: CloudFileMetadata,
                progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata {
        let token: String
        let path: String
        var upload: URLRequest
        let resumable = data.count > 5_000_000
        let before: CloudFileMetadata
        do {
            guard let revision = observed.rev, !revision.isEmpty, observed.contentHash != nil else {
                throw CloudProviderError.serviceUnavailable
            }
            path = try Self.filePath(fileId)
            token = try await authorization.accessToken(accountID: accountId)
            upload = try Self.requestFor(path, query: [
                URLQueryItem(name: "uploadType", value: resumable ? "resumable" : "multipart"),
                URLQueryItem(name: "fields", value: Resource.fields),
            ], token: token, upload: true)
            upload.httpMethod = "PATCH"
            Self.configureBody(&upload, metadata: Data("{}".utf8), bytes: data, resumable: resumable)
            let item = try await resource(fileID: fileId, token: token)
            guard item.isWritable else { throw CloudProviderError.permissionDenied }
            before = try item.metadata()
            try Task.checkCancellation()
        } catch {
            let underlying = (error as? CloudProviderError) ?? .serviceUnavailable
            throw CloudUploadFailure(underlying: underlying, outcome: .notDispatched)
        }

        guard before.rev == observed.rev, before.contentHash == observed.contentHash, let expected = observed.rev else {
            throw CloudUploadRecovery.preflightConflict(remoteRevision: before.rev)
        }

        let sent: (Data, HTTPURLResponse)
        do {
            let first = try await transport.send(upload)
            sent = resumable ? try await finishResumable(first, bytes: data) : first
        } catch let recovery as CloudUploadRecovery {
            throw recovery
        } catch {
            throw CloudUploadRecovery.responseLost
        }

        let item: Resource
        let result: CloudFileMetadata
        do {
            try GoogleDriveResponse.check(sent.0, sent.1)
            item = try JSONDecoder().decode(Resource.self, from: sent.0)
            result = try item.metadata()
        } catch {
            throw CloudUploadRecovery.verificationIncomplete(ownRevision: nil)
        }
        guard item.id == fileId, item.matches(bytes: data), let ownRevision = result.rev, ownRevision != expected else {
            throw CloudUploadRecovery.verificationIncomplete(ownRevision: nil)
        }
        do {
            try await verifyHistory(path: path, fileID: fileId, token: token, expected: expected, own: ownRevision)
        } catch let recovery as CloudUploadRecovery {
            throw recovery
        } catch {
            throw CloudUploadRecovery.verificationIncomplete(ownRevision: ownRevision)
        }
        progress(1)
        return result
    }

    private func finishResumable(_ initial: (Data, HTTPURLResponse), bytes: Data) async throws -> (Data, HTTPURLResponse) {
        guard (200..<300).contains(initial.1.statusCode),
              let location = initial.1.value(forHTTPHeaderField: "Location"), let url = URL(string: location),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "www.googleapis.com",
              components.port == nil, components.user == nil, components.password == nil, components.fragment == nil,
              components.path == "/upload/drive/v3/files" || components.path.hasPrefix("/upload/drive/v3/files/") else {
            throw CloudUploadRecovery.verificationIncomplete(ownRevision: nil)
        }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            var part = URLRequest(url: url)
            part.httpMethod = "PUT"
            part.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            part.setValue("bytes \(offset)-\(bytes.count - 1)/\(bytes.count)", forHTTPHeaderField: "Content-Range")
            part.httpBody = offset == 0 ? bytes : bytes.subdata(in: offset..<bytes.count)
            let reply = try await transport.send(part)
            if reply.1.statusCode != 308 { return reply }
            guard let range = reply.1.value(forHTTPHeaderField: "Range"),
                  let match = range.wholeMatch(of: /bytes=0-([0-9]+)/),
                  let end = Int(match.1), end >= offset, end < bytes.count - 1,
                  (end + 1) % (256 * 1024) == 0 else {
                throw CloudUploadRecovery.verificationIncomplete(ownRevision: nil)
            }
            offset = end + 1
        }
        throw CloudUploadRecovery.verificationIncomplete(ownRevision: nil)
    }

    private func verifyHistory(path: String, fileID: String, token: String, expected: String, own: String) async throws {
        struct Page: Decodable {
            struct Revision: Decodable { let id: String }
            let revisions: [Revision]
            let nextPageToken: String?
        }
        let inconclusive = CloudUploadRecovery.verificationIncomplete(ownRevision: own)
        let conflict = CloudUploadRecovery.postUploadConflict(ownRevision: own)
        var ids: [String] = []
        var pageToken: String?
        for _ in 0..<10 {
            var query = [URLQueryItem(name: "fields", value: "nextPageToken,revisions(id)"), URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await request(path + "/revisions", query: query, token: token)
            let page = try JSONDecoder().decode(Page.self, from: data)
            ids.append(contentsOf: page.revisions.map(\.id))
            guard let next = page.nextPageToken else {
                guard Set(ids).count == ids.count, let base = ids.firstIndex(of: expected),
                      let sent = ids.firstIndex(of: own), base < sent else { throw inconclusive }
                if sent != base + 1 || ids.last != own { throw conflict }
                let current = try await resource(fileID: fileID, token: token).metadata()
                guard current.rev == own else { throw inconclusive }
                return
            }
            guard !next.isEmpty, next != pageToken else { throw inconclusive }
            pageToken = next
        }
        throw inconclusive
    }

    private static func configureBody(_ request: inout URLRequest, metadata: Data, bytes: Data, resumable: Bool) {
        if resumable {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(bytes.count), forHTTPHeaderField: "X-Upload-Content-Length")
            request.httpBody = metadata
            return
        }
        var boundary = "keeforge-" + UUID().uuidString
        while bytes.range(of: Data(boundary.utf8)) != nil || metadata.range(of: Data(boundary.utf8)) != nil {
            boundary = "keeforge-" + UUID().uuidString
        }
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
    }

    func createFile(accountId: String, path: String, data: Data,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> CloudCreatedFile {
        let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let resumable = data.count > 5_000_000
        let request: URLRequest
        do {
            guard !name.isEmpty, !name.contains("/"), !name.utf8.contains(0) else { throw CloudProviderError.invalidName }
            let token = try await authorization.accessToken(accountID: accountId)
            var upload = try Self.requestFor("files", query: [
                URLQueryItem(name: "uploadType", value: resumable ? "resumable" : "multipart"),
                URLQueryItem(name: "fields", value: Resource.fields),
            ], token: token, upload: true)
            upload.httpMethod = "POST"
            let attributes = try JSONEncoder().encode(["name": name, "mimeType": "application/octet-stream"])
            Self.configureBody(&upload, metadata: attributes, bytes: data, resumable: resumable)
            request = upload
            try Task.checkCancellation()
        } catch {
            throw CloudCreationNotDispatched(underlying: error)
        }
        let initial = try await transport.send(request)
        let (body, response) = resumable ? try await finishResumable(initial, bytes: data) : initial
        try GoogleDriveResponse.check(body, response)
        let item = try JSONDecoder().decode(Resource.self, from: body)
        _ = try Self.filePath(item.id)
        guard item.name == name, item.matches(bytes: data) else { throw CloudProviderError.serviceUnavailable }
        progress(1)
        return CloudCreatedFile(file: item.file, metadata: try item.metadata())
    }

    private func account(accessToken: String) async throws -> CloudAccount {
        struct About: Decodable {
            struct User: Decodable { let permissionId: String; let displayName: String? }
            let user: User
        }
        let data = try await request("about", query: [URLQueryItem(name: "fields", value: "user(permissionId,displayName)")], token: accessToken)
        let user = try JSONDecoder().decode(About.self, from: data).user
        guard !user.permissionId.isEmpty else { throw CloudProviderError.notAuthenticated }
        return CloudAccount(id: user.permissionId, displayName: user.displayName ?? displayName, provider: id)
    }

    private func resource(fileID: String, token: String) async throws -> Resource {
        let data = try await request(Self.filePath(fileID), query: [
            URLQueryItem(name: "fields", value: Resource.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ], token: token)
        let item = try JSONDecoder().decode(Resource.self, from: data)
        guard item.id == fileID, item.trashed != true else { throw CloudProviderError.fileNotFound }
        guard item.driveId == nil, !item.mimeType.hasPrefix("application/vnd.google-apps.") else {
            throw CloudProviderError.permissionDenied
        }
        return item
    }

    private static func filePath(_ id: String) throws -> String {
        guard id.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { throw CloudProviderError.invalidConfiguration }
        return "files/\(id)"
    }

    private func request(_ path: String, query: [URLQueryItem], token: String) async throws -> Data {
        try Task.checkCancellation()
        let request = try Self.requestFor(path, query: query, token: token)
        let (data, response) = try await transport.send(request)
        try GoogleDriveResponse.check(data, response)
        return data
    }

    private static func requestFor(_ path: String, query: [URLQueryItem], token: String, upload: Bool = false) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = (upload ? "/upload" : "") + "/drive/v3/" + path
        components.queryItems = query
        guard let url = components.url else { throw CloudProviderError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private struct Resource: Decodable {
        struct Capabilities: Decodable {
            let canModifyContent: Bool?
            let canDownload: Bool?
            let canReadRevisions: Bool?
        }

        static let fields = "id,name,mimeType,modifiedTime,size,headRevisionId,md5Checksum,sha256Checksum,trashed,driveId,capabilities(canModifyContent,canDownload,canReadRevisions)"
        let id: String
        let name: String
        let mimeType: String
        let modifiedTime: String?
        let size: String?
        let headRevisionId: String?
        let md5Checksum: String?
        let sha256Checksum: String?
        let trashed: Bool?
        let driveId: String?
        let capabilities: Capabilities?

        var isWritable: Bool {
            capabilities?.canDownload == true && capabilities?.canModifyContent == true
                && capabilities?.canReadRevisions == true
        }
        var modifiedDate: Date? {
            guard let modifiedTime else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: modifiedTime) ?? ISO8601DateFormatter().date(from: modifiedTime)
        }
        var file: CloudFile {
            CloudFile(id: id, name: name, path: name, isFolder: false, modifiedDate: modifiedDate, size: size.flatMap(Int64.init))
        }

        func metadata() throws -> CloudFileMetadata {
            guard let modifiedDate, let size = size.flatMap(Int64.init), size >= 0,
                  let headRevisionId, !headRevisionId.isEmpty, let md5Checksum,
                  md5Checksum.wholeMatch(of: /[A-Fa-f0-9]{32}/) != nil else {
                throw CloudProviderError.serviceUnavailable
            }
            return CloudFileMetadata(modifiedDate: modifiedDate, contentHash: md5Checksum.lowercased(),
                                     size: size, rev: headRevisionId)
        }

        func matches(bytes: Data) -> Bool {
            guard size.flatMap(Int64.init) == Int64(bytes.count) else { return false }
            if let sha256Checksum { return Self.hex(SHA256.hash(data: bytes)) == sha256Checksum.lowercased() }
            return Self.hex(Insecure.MD5.hash(data: bytes)) == md5Checksum?.lowercased()
        }

        private static func hex(_ digest: some Sequence<UInt8>) -> String {
            digest.map { String(format: "%02x", $0) }.joined()
        }
    }
}
#endif
