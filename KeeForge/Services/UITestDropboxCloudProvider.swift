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
            size: Int64(fileData?.count ?? Int(file.size ?? 0))
        )
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
}

private extension UITestDropboxCloudProvider {
    struct Payload: Decodable {
        let accounts: [CloudAccount]
        let directories: [Directory]
        let fileContentsByID: [String: String]
        let contentHashByFileID: [String: String]
        let authenticateError: ErrorKind?
        let listError: ErrorKind?
        let metadataError: ErrorKind?
        let downloadError: ErrorKind?

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
