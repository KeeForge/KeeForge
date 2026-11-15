import Foundation
import Observation

/// Reads a picked key file off the main actor, dropping a result a newer pick or `cancel()` replaced.
@MainActor @Observable
final class UnlockKeyFileSelection {
    private(set) var isLoading = false
    private(set) var revision = UUID()
    private let readData: @Sendable (URL) async throws -> Data

    init(readData: @escaping @Sendable (URL) async throws -> Data = { url in
        try await CoordinatedFileReader.performBlocking(timeout: .seconds(10)) {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try CoordinatedFileReader.readData(from: url)
        }
    }) {
        self.readData = readData
    }

    func read(url: URL) async -> Result<Data, Error>? {
        guard !Task.isCancelled else { return nil }
        let requestID = UUID()
        revision = requestID
        isLoading = true
        let result: Result<Data, Error>
        do {
            result = .success(try await readData(url))
        } catch {
            result = .failure(error)
        }
        guard revision == requestID else { return nil }
        isLoading = false
        guard !Task.isCancelled else { return nil }
        return result
    }

    func cancel() {
        revision = UUID()
        isLoading = false
    }
}
