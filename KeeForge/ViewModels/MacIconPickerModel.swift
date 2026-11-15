#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class MacIconPickerModel {
    enum Purpose { case entry, group }
    let purpose: Purpose
    let original: EntryIconSelection
    var selection: EntryIconSelection
    private(set) var customIcons: [DatabaseViewModel.CustomIcon]
    let standardIconIDs = KPEntry.standardIconNames.keys.sorted()
    let websiteHost: String?
    private(set) var isDownloading = false
    var errorMessage: String?
    private var downloadTask: Task<Void, Never>?
    private var ended = false
    var canUse: Bool {
        guard !ended, !isDownloading, selection != original else { return false }
        switch selection {
        case .standard(let id): return standardIconIDs.contains(id)
        case .custom(let id): return customIcons.contains { $0.id == id }
        }
    }

    init(purpose: Purpose, selection: EntryIconSelection, customIcons: [DatabaseViewModel.CustomIcon] = [], websiteURL: String = "") {
        self.purpose = purpose
        original = selection
        self.selection = selection
        self.customIcons = purpose == .group ? [] : customIcons
        websiteHost = purpose == .entry ? FaviconService.extractDomain(from: websiteURL) : nil
    }

    func refreshCustomIcons(_ icons: [DatabaseViewModel.CustomIcon]) {
        guard !ended, purpose == .entry else { return }
        customIcons = icons
    }

    func download(_ operation: @escaping @MainActor () async throws -> Void, completion: @escaping @MainActor () -> Void) {
        guard !ended, !isDownloading, websiteHost != nil else { return }
        isDownloading = true
        errorMessage = nil
        downloadTask = Task { [weak self] in
            do {
                try await operation()
                guard let self, !ended, !Task.isCancelled else { return }
                isDownloading = false
                completion()
            } catch {
                guard let self, !ended else { return }
                isDownloading = false
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func end() {
        ended = true
        customIcons = []
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        errorMessage = nil
    }
}
#endif
