import AuthenticationServices
import Foundation

final class UITestDropboxCloudProvider: CloudProvider, @unchecked Sendable {
    static let shared = UITestDropboxCloudProvider()

    static let environmentKey = "UI_TEST_DROPBOX_PAYLOAD_JSON"
    private static let uiTestingLaunchArg = "-ui-testing"

    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    private init() {}

    static func recordedUploads() async -> [RecordedUpload] {
        await uploadStore.all()
    }

    static func resetRecordedUploads() async {
        await uploadStore.reset()
    }

    static var isEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(uiTestingLaunchArg)
            && processInfo.environment[environmentKey]?.isEmpty == false
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        let payload = try Self.currentPayload()

        if let error = payload.authenticateError?.providerError {
            throw error
        }

        guard let account = payload.accounts.first else {
            throw CloudProviderError.notAuthenticated
        }

        payload.accounts.forEach(CloudAccountStore.upsert)
        payload.accounts.forEach { account in
            CloudAccountStore.setDropboxWriteScope(true, accountId: account.id)
        }
        return account
    }

    func isAuthenticated(accountId: String) -> Bool {
        CloudAccountStore.isConnected(provider: id, accountId: accountId)
    }

    func signOut(accountId: String) {
        CloudAccountStore.remove(provider: id, accountId: accountId)
    }

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        guard isAuthenticated(accountId: accountId) else {
            throw CloudProviderError.notAuthenticated
        }

        let payload = try Self.currentPayload()
        if let error = payload.listError?.providerError {
            throw error
        }

        let files = payload.files(at: path)
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sort(files)
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sort(
            files.filter { file in
                file.name.lowercased().contains(normalizedQuery) || file.path.lowercased().contains(normalizedQuery)
            }
        )
    }

    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard isAuthenticated(accountId: accountId) else {
            throw CloudProviderError.notAuthenticated
        }

        let payload = try Self.currentPayload()
        if let error = payload.downloadError?.providerError {
            throw error
        }

        guard let data = payload.data(for: fileId) else {
            throw CloudProviderError.fileNotFound
        }

        try data.write(to: localURL, options: .atomic)
        progress(1)
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        guard isAuthenticated(accountId: accountId) else {
            throw CloudProviderError.notAuthenticated
        }

        let payload = try Self.currentPayload()
        if let error = payload.metadataError?.providerError {
            throw error
        }

        guard let file = payload.file(withID: fileId), file.isFolder == false else {
            throw CloudProviderError.fileNotFound
        }

        let fileData = payload.data(for: fileId)
        return CloudFileMetadata(
            modifiedDate: file.modifiedDate ?? Date(timeIntervalSince1970: 0),
            contentHash: payload.contentHashByFileID[fileId],
            size: Int64(fileData?.count ?? Int(file.size ?? 0)),
            rev: payload.revByFileID?[fileId]
        )
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        guard isAuthenticated(accountId: accountId) else {
            throw CloudProviderError.notAuthenticated
        }

        guard CloudAccountStore.hasDropboxWriteScope(accountId: accountId) else {
            throw CloudProviderError.writeScopeRequired
        }

        let payload = try Self.currentPayload()
        if let error = payload.uploadError?.providerError {
            throw error
        }

        guard payload.file(withID: fileId)?.isFolder == false else {
            throw CloudProviderError.fileNotFound
        }

        await Self.uploadStore.append(
            RecordedUpload(
                accountId: accountId,
                fileId: fileId,
                expectedRev: expectedRev,
                data: data
            )
        )

        progress(1)

        let fallbackRev = expectedRev.map { "\($0)-uploaded" } ?? "uploaded-\(fileId.replacingOccurrences(of: "/", with: "_"))"
        return CloudFileMetadata(
            modifiedDate: Date(),
            contentHash: payload.contentHashByFileID[fileId],
            size: Int64(data.count),
            rev: payload.revByFileID?[fileId] ?? fallbackRev
        )
    }

    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        guard isAuthenticated(accountId: accountId) else {
            throw CloudProviderError.notAuthenticated
        }

        guard CloudAccountStore.hasDropboxWriteScope(accountId: accountId) else {
            throw CloudProviderError.writeScopeRequired
        }

        let payload = try Self.currentPayload()
        if let error = payload.uploadError?.providerError {
            throw error
        }

        if payload.file(withID: path) != nil {
            throw CloudProviderError.conflict(remoteRev: payload.revByFileID?[path])
        }

        let parentPath = Self.parentPath(for: path)
        guard payload.directories.contains(where: { $0.normalizedPath == Self.normalize(parentPath) }) else {
            throw CloudProviderError.fileNotFound
        }

        await Self.uploadStore.append(
            RecordedUpload(
                accountId: accountId,
                fileId: path,
                expectedRev: nil,
                data: data
            )
        )

        progress(1)

        let filename = (path as NSString).lastPathComponent
        let file = CloudFile(
            id: path,
            name: filename,
            path: path,
            isFolder: false,
            modifiedDate: Date(),
            size: Int64(data.count)
        )
        let metadata = CloudFileMetadata(
            modifiedDate: file.modifiedDate ?? Date(),
            contentHash: payload.contentHashByFileID[path],
            size: Int64(data.count),
            rev: payload.revByFileID?[path] ?? "created-\(path.replacingOccurrences(of: "/", with: "_"))"
        )
        return CloudCreatedFile(file: file, metadata: metadata)
    }

    private func sort(_ files: [CloudFile]) -> [CloudFile] {
        files.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func currentPayload() throws -> Payload {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains(uiTestingLaunchArg),
              let rawValue = processInfo.environment[environmentKey],
              !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8) else {
            throw CloudProviderError.invalidConfiguration
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Payload.self, from: data)
    }

    private static func parentPath(for path: String) -> String? {
        let trimmed = normalize(path)
        guard !trimmed.isEmpty else { return nil }
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent == "/" ? nil : parent
    }
}

private extension UITestDropboxCloudProvider {
    static let uploadStore = UploadStore()

    actor UploadStore {
        private var uploads: [RecordedUpload] = []

        func append(_ upload: RecordedUpload) {
            uploads.append(upload)
        }

        func all() -> [RecordedUpload] {
            uploads
        }

        func reset() {
            uploads.removeAll()
        }
    }

    struct Payload: Decodable {
        let accounts: [CloudAccount]
        let directories: [Directory]
        let fileContentsByID: [String: String]
        let contentHashByFileID: [String: String]
        let revByFileID: [String: String]?
        let authenticateError: ErrorKind?
        let listError: ErrorKind?
        let metadataError: ErrorKind?
        let downloadError: ErrorKind?
        let uploadError: ErrorKind?

        func files(at path: String?) -> [CloudFile] {
            directories.first(where: { $0.normalizedPath == normalize(path) })?.files.map(\.cloudFile) ?? []
        }

        func file(withID id: String) -> CloudFile? {
            directories.lazy
                .flatMap(\.files)
                .first(where: { $0.id == id })?
                .cloudFile
        }

        func data(for fileID: String) -> Data? {
            guard let encoded = fileContentsByID[fileID] else { return nil }
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        }
    }

    struct Directory: Decodable {
        let path: String?
        let files: [File]

        var normalizedPath: String {
            normalize(path)
        }
    }

    struct File: Decodable {
        let id: String
        let name: String
        let path: String
        let isFolder: Bool
        let modifiedDate: Date?
        let size: Int64?

        var cloudFile: CloudFile {
            CloudFile(
                id: id,
                name: name,
                path: path,
                isFolder: isFolder,
                modifiedDate: modifiedDate,
                size: size
            )
        }
    }

    enum ErrorKind: String, Decodable {
        case invalidConfiguration
        case authenticationCancelled
        case notAuthenticated
        case networkUnavailable
        case fileNotFound
        case conflict
        case writeScopeRequired

        var providerError: CloudProviderError {
            switch self {
            case .invalidConfiguration:
                .invalidConfiguration
            case .authenticationCancelled:
                .authenticationCancelled
            case .notAuthenticated:
                .notAuthenticated
            case .networkUnavailable:
                .networkUnavailable
            case .fileNotFound:
                .fileNotFound
            case .conflict:
                .conflict(remoteRev: nil)
            case .writeScopeRequired:
                .writeScopeRequired
            }
        }
    }

    static func normalize(_ path: String?) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "/" else {
            return ""
        }
        return trimmed
    }
}

struct RecordedUpload: Equatable, Sendable {
    let accountId: String
    let fileId: String
    let expectedRev: String?
    let data: Data
}
