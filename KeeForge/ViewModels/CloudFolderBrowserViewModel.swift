import Foundation

@MainActor
@Observable
final class CloudFolderBrowserViewModel {
    let path: String?
    var searchText = ""
    private(set) var files: [CloudFile] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var loadGeneration = 0

    init(path: String?) {
        self.path = path
    }

    func requestKey(accountID: String) -> String {
        "\(accountID)|\(path ?? "")|\(searchText)"
    }

    func load(provider: CloudProvider, accountID: String) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true

        let result: Result<[CloudFile], Error>
        do {
            let loadedFiles = try await provider.listFiles(
                accountId: accountID,
                path: path,
                query: trimmedSearchText
            )
            result = .success(loadedFiles)
        } catch {
            result = .failure(error)
        }

        // `.task(id:)` cancels and restarts this on every keystroke, so a
        // resumed task may be cancelled or superseded by a newer request. In
        // that case the newer request owns `isLoading` and the published
        // state, so drop these results without mutating anything.
        guard !Task.isCancelled, generation == loadGeneration else { return }
        isLoading = false

        switch result {
        case .success(let loadedFiles):
            files = loadedFiles
            errorMessage = nil
        case .failure(let error):
            // A cancelled request must not surface a user-facing error.
            if error is CancellationError { return }
            errorMessage = error.localizedDescription
            files = []
        }
    }

    private var trimmedSearchText: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
