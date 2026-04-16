import Foundation

@MainActor
@Observable
final class CloudFolderBrowserViewModel {
    let path: String?
    var searchText = ""
    private(set) var files: [CloudFile] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(path: String?) {
        self.path = path
    }

    func requestKey(accountID: String) -> String {
        "\(accountID)|\(path ?? "")|\(searchText)"
    }

    func load(provider: CloudProvider, accountID: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            files = try await provider.listFiles(
                accountId: accountID,
                path: path,
                query: trimmedSearchText
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            files = []
        }
    }

    private var trimmedSearchText: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
