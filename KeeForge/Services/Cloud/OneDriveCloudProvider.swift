import AuthenticationServices
import Foundation
@preconcurrency import MSAL
#if os(iOS)
import UIKit
#endif

final class OneDriveCloudProvider: CloudProvider, @unchecked Sendable {
    static let shared = OneDriveCloudProvider()

    private static let scopes = [
        "Files.ReadWrite",
        "User.Read",
    ]
    private static let graphBaseURLString = "https://graph.microsoft.com/v1.0"
    private static let uploadChunkSize = 5 * 1_024 * 1_024

    let id = CloudProviderKind.oneDrive.rawValue
    let displayName = CloudProviderKind.oneDrive.displayName
    let iconName = CloudProviderKind.oneDrive.iconName

    private let decoder: JSONDecoder
    private var cachedApplication: MSALPublicClientApplication?

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseISO8601Date(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid OneDrive date: \(value)"
            )
        }
        self.decoder = decoder
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        #if os(iOS)
        let application = try application()
        let webParameters = MSALWebviewParameters(authPresentationViewController: presentingController(from: anchor))
        let parameters = MSALInteractiveTokenParameters(scopes: Self.scopes, webviewParameters: webParameters)
        parameters.promptType = .selectAccount

        let result = try await acquireToken(application: application, parameters: parameters)
        let account = makeCloudAccount(from: result.account)
        CloudAccountStore.upsert(account)
        return account
        #else
        // MSAL's desktop auth presentation lands in slice 03 of the macOS
        // port; until then, OneDrive sign-in is unavailable on the Mac.
        throw CloudProviderError.unknown("OneDrive sign-in isn't available in this Mac build yet.")
        #endif
    }

    func isAuthenticated(accountId: String) -> Bool {
        do {
            _ = try application().account(forIdentifier: accountId)
            return true
        } catch {
            return false
        }
    }

    func signOut(accountId: String) {
        do {
            let application = try application()
            let account = try application.account(forIdentifier: accountId)
            try application.remove(account)
        } catch {
            // The local account row is still stale even if MSAL has already dropped its token cache.
        }

        CloudAccountStore.remove(provider: id, accountId: accountId)
    }

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        let token = try await accessToken(accountId: accountId)
        var files: [CloudFile] = []
        var nextURL: URL? = try graphURL(
            path: listChildrenPath(for: path),
            queryItems: [
                URLQueryItem(name: "$top", value: "200"),
                URLQueryItem(name: "$select", value: "id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"),
            ]
        )

        while let currentURL = nextURL {
            let response: OneDriveCollectionResponse = try await decodedGraphResponse(
                OneDriveCollectionResponse.self,
                request: authorizedRequest(url: currentURL, token: token)
            )
            files.append(contentsOf: response.value.compactMap(Self.makeCloudFile(from:)))
            nextURL = response.nextLink.flatMap(URL.init(string:))
        }

        let filteredFiles = filter(files: files, query: query)
        return filteredFiles.sorted(by: Self.sortCloudFiles)
    }

    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let token = try await accessToken(accountId: accountId)
        let request = authorizedRequest(url: try graphURL(path: contentPath(for: fileId)), token: token)

        do {
            let (downloadURL, response) = try await URLSession.shared.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudProviderError.unknown("OneDrive download failed.")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: nil)
            }

            let directoryURL = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: downloadURL, to: localURL)
            progress(1)
        } catch let error as CloudProviderError {
            throw error
        } catch {
            throw Self.mapGenericError(error)
        }
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        let token = try await accessToken(accountId: accountId)
        let item: OneDriveDriveItem = try await decodedGraphResponse(
            OneDriveDriveItem.self,
            request: authorizedRequest(
                url: try graphURL(
                    path: itemPath(for: fileId),
                    queryItems: [
                        URLQueryItem(name: "$select", value: "id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"),
                    ]
                ),
                token: token
            )
        )

        guard item.file != nil else {
            throw CloudProviderError.fileNotFound
        }

        return Self.makeCloudFileMetadata(from: item)
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        let token = try await accessToken(accountId: accountId)
        let item = try await uploadUsingSession(
            path: fileId,
            data: data,
            expectedRev: expectedRev,
            conflictBehavior: "replace",
            token: token,
            progress: progress
        )
        return Self.makeCloudFileMetadata(from: item)
    }

    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        let token = try await accessToken(accountId: accountId)
        let item = try await uploadUsingSession(
            path: path,
            data: data,
            expectedRev: nil,
            conflictBehavior: "fail",
            token: token,
            progress: progress
        )

        guard let file = Self.makeCloudFile(from: item) else {
            throw CloudProviderError.unknown("OneDrive upload did not return a file.")
        }

        return CloudCreatedFile(
            file: file,
            metadata: Self.makeCloudFileMetadata(from: item)
        )
    }

    @MainActor
    func handleRedirectURL(_ url: URL) -> Bool {
        #if os(iOS)
        MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
        #else
        // `handleMSALResponse` is iOS-only; the macOS MSAL redirect flow lands
        // in slice 03 of the macOS port alongside desktop auth presentation.
        false
        #endif
    }

    // MARK: - Authentication

    private func application() throws -> MSALPublicClientApplication {
        if let cachedApplication {
            return cachedApplication
        }

        guard let clientID else {
            throw CloudProviderError.invalidConfiguration
        }

        guard let authorityURL = URL(string: "https://login.microsoftonline.com/consumers") else {
            throw CloudProviderError.invalidConfiguration
        }
        let authority = try MSALAADAuthority(url: authorityURL)
        let configuration = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: redirectURI,
            authority: authority
        )
        let application = try MSALPublicClientApplication(configuration: configuration)
        cachedApplication = application
        return application
    }

    private var clientID: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "OneDriveClientID") as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "$(ONEDRIVE_CLIENT_ID)",
              trimmed != "ONEDRIVE_CLIENT_ID",
              trimmed != "YOUR_ONEDRIVE_CLIENT_ID",
              trimmed != "00000000-0000-0000-0000-000000000000" else {
            return nil
        }

        return trimmed
    }

    private var redirectURI: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "OneDriveRedirectURI") as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func acquireToken(
        application: MSALPublicClientApplication,
        parameters: MSALInteractiveTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: Self.mapMSALError(error))
                }
            }
        }
    }

    private func accessToken(accountId: String) async throws -> String {
        let application = try application()
        let account: MSALAccount
        do {
            account = try application.account(forIdentifier: accountId)
        } catch {
            throw CloudProviderError.notAuthenticated
        }

        let parameters = MSALSilentTokenParameters(scopes: Self.scopes, account: account)
        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: Self.mapMSALError(error))
                }
            }
        }
        return result.accessToken
    }

    #if os(iOS)
    @MainActor
    private func presentingController(from anchor: ASPresentationAnchor) -> UIViewController {
        topViewController(startingAt: anchor.rootViewController) ?? UIViewController()
    }

    @MainActor
    private func topViewController(startingAt root: UIViewController?) -> UIViewController? {
        var current = root

        while let presented = current?.presentedViewController {
            current = presented
        }

        if let navigationController = current as? UINavigationController {
            return topViewController(startingAt: navigationController.visibleViewController)
        }

        if let tabBarController = current as? UITabBarController {
            return topViewController(startingAt: tabBarController.selectedViewController)
        }

        return current
    }
    #endif

    private func makeCloudAccount(from account: MSALAccount) -> CloudAccount {
        let accountID = account.identifier ?? account.username ?? UUID().uuidString
        let displayName = account.username ?? accountID
        return CloudAccount(id: accountID, displayName: displayName, provider: id)
    }

    // MARK: - Graph requests

    private func uploadUsingSession(
        path: String,
        data: Data,
        expectedRev: String?,
        conflictBehavior: String,
        token: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> OneDriveDriveItem {
        guard data.isEmpty == false else {
            throw CloudProviderError.unknown("OneDrive cannot upload an empty database.")
        }

        var request = authorizedRequest(
            url: try graphURL(path: uploadSessionPath(for: path)),
            method: "POST",
            token: token
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let expectedRev {
            request.setValue(expectedRev, forHTTPHeaderField: "If-Match")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "item": [
                    "@microsoft.graph.conflictBehavior": conflictBehavior,
                    "name": (path as NSString).lastPathComponent,
                ],
            ],
            options: []
        )

        let session: OneDriveUploadSession = try await decodedGraphResponse(
            OneDriveUploadSession.self,
            request: request
        )

        guard let uploadURL = URL(string: session.uploadURL) else {
            throw CloudProviderError.unknown("OneDrive returned an invalid upload URL.")
        }

        var offset = 0
        var completedItem: OneDriveDriveItem?

        while offset < data.count {
            let end = min(offset + Self.uploadChunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            var chunkRequest = URLRequest(url: uploadURL)
            chunkRequest.httpMethod = "PUT"
            chunkRequest.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
            chunkRequest.setValue("bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            chunkRequest.httpBody = chunk

            let (responseData, response) = try await URLSession.shared.data(for: chunkRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudProviderError.unknown("OneDrive upload failed.")
            }

            switch httpResponse.statusCode {
            case 200, 201:
                completedItem = try decoder.decode(OneDriveDriveItem.self, from: responseData)
            case 202:
                break
            default:
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: responseData)
            }

            offset = end
            progress(Double(offset) / Double(data.count))
        }

        guard let completedItem else {
            throw CloudProviderError.unknown("OneDrive upload did not complete.")
        }
        return completedItem
    }

    private func decodedGraphResponse<T: Decodable>(
        _ type: T.Type,
        request: URLRequest
    ) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudProviderError.unknown("OneDrive request failed.")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            return try decoder.decode(type, from: data)
        } catch let error as CloudProviderError {
            throw error
        } catch let decodingError as DecodingError {
            throw CloudProviderError.unknown(String(describing: decodingError))
        } catch {
            throw Self.mapGenericError(error)
        }
    }

    private func authorizedRequest(
        url: URL,
        method: String = "GET",
        token: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func graphURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard let baseURL = URL(string: Self.graphBaseURLString),
              var components = URLComponents(
                  url: baseURL.appendingPathComponent(path),
                  resolvingAgainstBaseURL: false
              ) else {
            throw CloudProviderError.invalidConfiguration
        }

        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw CloudProviderError.invalidConfiguration
        }
        return url
    }

    private func listChildrenPath(for path: String?) -> String {
        let normalized = Self.normalizedCloudPath(path)
        guard normalized != "/" else {
            return "me/drive/root/children"
        }
        return "me/drive/root:\(Self.encodedGraphPath(normalized)):/children"
    }

    private func itemPath(for path: String) -> String {
        "me/drive/root:\(Self.encodedGraphPath(Self.normalizedCloudPath(path))):"
    }

    private func contentPath(for path: String) -> String {
        "me/drive/root:\(Self.encodedGraphPath(Self.normalizedCloudPath(path))):/content"
    }

    private func uploadSessionPath(for path: String) -> String {
        "me/drive/root:\(Self.encodedGraphPath(Self.normalizedCloudPath(path))):/createUploadSession"
    }

    private func filter(files: [CloudFile], query: String?) -> [CloudFile] {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              query.isEmpty == false else {
            return files
        }

        let loweredQuery = query.lowercased()
        return files.filter { file in
            file.name.lowercased().contains(loweredQuery)
                || file.path.lowercased().contains(loweredQuery)
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data?) -> Error {
        let message = data.flatMap { try? decoder.decode(OneDriveErrorResponse.self, from: $0) }?.error.message

        switch statusCode {
        case 401:
            return CloudProviderError.notAuthenticated
        case 403:
            return CloudProviderError.writeScopeRequired
        case 404:
            return CloudProviderError.fileNotFound
        case 409, 412:
            return CloudProviderError.conflict(remoteRev: nil)
        case 400 where message?.localizedCaseInsensitiveContains("quota") == true:
            return CloudProviderError.unknown(message ?? "OneDrive quota is unavailable.")
        default:
            return CloudProviderError.unknown(message ?? "OneDrive request failed with HTTP \(statusCode).")
        }
    }

    private static func mapMSALError(_ error: Error?) -> Error {
        guard let error else {
            return CloudProviderError.unknown("OneDrive sign-in failed.")
        }

        let nsError = error as NSError
        if nsError.domain == MSALErrorDomain,
           nsError.code == MSALError.userCanceled.rawValue {
            return CloudProviderError.authenticationCancelled
        }

        if nsError.domain == MSALErrorDomain,
           nsError.code == MSALError.interactionRequired.rawValue {
            return CloudProviderError.notAuthenticated
        }

        return CloudProviderError.unknown(nsError.localizedDescription)
    }

    private static func mapGenericError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return CloudProviderError.networkUnavailable
        }
        return CloudProviderError.unknown(nsError.localizedDescription)
    }

    private static func makeCloudFile(from item: OneDriveDriveItem) -> CloudFile? {
        let isFolder = item.folder != nil
        if !isFolder {
            guard item.name.lowercased().hasSuffix(".kdbx") else { return nil }
        }

        let path = displayPath(for: item)
        return CloudFile(
            id: path,
            name: item.name,
            path: path,
            isFolder: isFolder,
            modifiedDate: item.lastModifiedDateTime,
            size: item.size
        )
    }

    private static func makeCloudFileMetadata(from item: OneDriveDriveItem) -> CloudFileMetadata {
        CloudFileMetadata(
            modifiedDate: item.lastModifiedDateTime ?? .now,
            contentHash: item.file?.hashes?.sha1Hash ?? item.file?.hashes?.quickXorHash,
            size: item.size ?? 0,
            rev: item.cTag ?? item.eTag
        )
    }

    private static func displayPath(for item: OneDriveDriveItem) -> String {
        let parentPath = item.parentReference?.path ?? "/drive/root:"
        let parentAfterRoot = parentPath.range(of: "root:").map { range in
            String(parentPath[range.upperBound...])
        } ?? parentPath
        let strippedParent = parentAfterRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if strippedParent.isEmpty {
            return "/\(item.name)"
        }
        return "/\(strippedParent)/\(item.name)"
    }

    private static func sortCloudFiles(_ lhs: CloudFile, _ rhs: CloudFile) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func normalizedCloudPath(_ path: String?) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "/" else {
            return "/"
        }

        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/\(withoutTrailingSlash)"
    }

    private static func encodedGraphPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: graphPathAllowedCharacters) ?? String(segment)
            }
            .joined(separator: "/")
            .prependingSlash()
    }

    private static let graphPathAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":?#[]@!$&'()*+,;=%")
        return allowed
    }()

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension String {
    func prependingSlash() -> String {
        hasPrefix("/") ? self : "/\(self)"
    }
}

private struct OneDriveCollectionResponse: Decodable {
    let value: [OneDriveDriveItem]
    let nextLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct OneDriveDriveItem: Decodable {
    let id: String
    let name: String
    let size: Int64?
    let eTag: String?
    let cTag: String?
    let lastModifiedDateTime: Date?
    let folder: OneDriveFolderFacet?
    let file: OneDriveFileFacet?
    let parentReference: OneDriveParentReference?
}

private struct OneDriveFolderFacet: Decodable {}

private struct OneDriveFileFacet: Decodable {
    let hashes: OneDriveHashes?
}

private struct OneDriveHashes: Decodable {
    let sha1Hash: String?
    let quickXorHash: String?
}

private struct OneDriveParentReference: Decodable {
    let path: String?
}

private struct OneDriveUploadSession: Decodable {
    let uploadURL: String

    private enum CodingKeys: String, CodingKey {
        case uploadURL = "uploadUrl"
    }
}

private struct OneDriveErrorResponse: Decodable {
    let error: OneDriveError
}

private struct OneDriveError: Decodable {
    let code: String?
    let message: String
}
