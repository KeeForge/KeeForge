#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class MacRemoteBrowserModel {
    enum Mode { case chooseDatabase, chooseFolder }
    struct Folder: Equatable {
        let path: String?
        let name: String
    }
    let mode: Mode
    private(set) var account: CloudAccount
    private(set) var pathComponents: [Folder] = [Folder(path: nil, name: "/")]
    private var history: [[Folder]] = []
    private var forwardHistory: [[Folder]] = []
    private var folder = CloudFolderBrowserViewModel(path: nil)
    private var generation = UUID()
    private var ended = false
    var showsAllFiles = false
    var selectedID: String?
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var files: [CloudFile] = []

    init(account: CloudAccount, mode: Mode = .chooseDatabase) {
        self.account = account
        self.mode = mode
    }
    var rows: [CloudFile] {
        files.filter { mode != .chooseFolder || $0.isFolder }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var path: String? { pathComponents.last?.path }
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var selectedFile: CloudFile? { rows.first { $0.id == selectedID && isSelectable($0) } }
    var canOpen: Bool { !ended && !isLoading && errorMessage == nil && (mode == .chooseFolder || selectedFile != nil) }
    func isSelectable(_ file: CloudFile) -> Bool {
        !file.isFolder && mode == .chooseDatabase && (showsAllFiles || file.name.lowercased().hasSuffix(".kdbx"))
    }
    func navigate(to file: CloudFile) {
        guard !ended, file.isFolder else { return }
        visit(pathComponents + [Folder(path: file.id, name: file.name)])
    }
    func visitAncestor(_ index: Int) {
        guard pathComponents.indices.contains(index), index < pathComponents.count - 1 else { return }
        visit(Array(pathComponents.prefix(index + 1)))
    }
    func goBack() {
        guard let previous = history.popLast() else { return }
        forwardHistory.append(pathComponents)
        pathComponents = previous
        resetListing()
    }
    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        history.append(pathComponents)
        pathComponents = next
        resetListing()
    }
    func replaceAccount(_ account: CloudAccount) {
        self.account = account
        pathComponents = [Folder(path: nil, name: "/")]
        history = []; forwardHistory = []
        resetListing()
    }
    func end() { ended = true; generation = UUID(); files = []; selectedID = nil; isLoading = false }
    func load(provider: any CloudProvider) async {
        guard !ended else { return }
        let token = UUID()
        generation = token
        let accountID = account.id
        let listing = folder
        isLoading = true
        await listing.load(provider: provider, accountID: accountID, includesAllFiles: true)
        guard generation == token, account.id == accountID, !Task.isCancelled else { return }
        files = listing.files
        errorMessage = listing.errorMessage
        isLoading = false
    }
    func databaseSelection() -> CloudDatabaseSelection? {
        guard canOpen, let file = selectedFile else { return nil }
        return CloudDatabaseSelection(provider: account.provider, account: account, file: file)
    }
    private func visit(_ chain: [Folder]) {
        history.append(pathComponents)
        forwardHistory = []
        pathComponents = chain
        resetListing()
    }
    private func resetListing() {
        generation = UUID()
        folder = CloudFolderBrowserViewModel(path: path)
        files = []; selectedID = nil; errorMessage = nil; isLoading = true
    }
}
#endif
