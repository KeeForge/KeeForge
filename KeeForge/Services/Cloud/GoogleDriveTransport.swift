import Foundation

protocol GoogleDriveTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class GoogleDriveURLSessionTransport: NSObject, GoogleDriveTransport, URLSessionTaskDelegate {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw CloudProviderError.serviceUnavailable
            }
            return (data, response)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch where CloudProviderError.isLikelyOffline(error) {
            throw CloudProviderError.networkUnavailable
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Authenticated Drive REST calls must never forward a bearer token to a redirect target.
        completionHandler(nil)
    }
}

enum GoogleDriveResponse {
    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw error(data: data, status: response.statusCode)
        }
    }

    static func error(data: Data, status: Int) -> CloudProviderError {
        struct Envelope: Decodable {
            struct Failure: Decodable {
                struct Detail: Decodable { let reason: String? }
                let errors: [Detail]?
            }
            let error: Failure?
        }
        let reasons = Set((try? JSONDecoder().decode(Envelope.self, from: data))?.error?.errors?.compactMap(\.reason) ?? [])
        if status == 401 || reasons.contains("authError") { return .notAuthenticated }
        if !reasons.isDisjoint(with: ["storageQuotaExceeded", "teamDriveFileLimitExceeded", "activeItemCreationLimitExceeded"]) {
            return .insufficientSpace
        }
        if status == 429 || !reasons.isDisjoint(with: ["rateLimitExceeded", "quotaExceeded", "downloadQuotaExceeded", "userRateLimitExceeded", "sharingRateLimitExceeded", "dailyLimitExceeded"]) {
            return .rateLimited
        }
        switch status {
        case 403: return .permissionDenied
        case 404: return .fileNotFound
        case 409, 412: return .conflict(remoteRev: nil)
        case 400: return .invalidConfiguration
        case 500...599: return .serviceUnavailable
        default: return .serviceUnavailable
        }
    }
}
