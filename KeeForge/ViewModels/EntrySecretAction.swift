import Foundation

@MainActor
@Observable
final class EntrySecretAction {
    private(set) var isAuthenticating = false
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    static func currentSession(_ viewModel: DatabaseViewModel) -> @MainActor () -> Bool {
        let lockCycleID = viewModel.lockCycleID
        let contentRevision = viewModel.contentRevision
        let selectedEntryID = viewModel.workspace.selectedEntryID
        let selectedGroupID = viewModel.workspace.selectedGroupID
        let selectedTag = viewModel.workspace.selectedTag
        let navigationPath = viewModel.workspace.navigationPath
        return {
            viewModel.state == .unlocked && viewModel.sessionKey != nil && viewModel.lockCycleID == lockCycleID
                && viewModel.contentRevision == contentRevision
                && viewModel.workspace.selectedEntryID == selectedEntryID
                && viewModel.workspace.selectedGroupID == selectedGroupID
                && viewModel.workspace.selectedTag == selectedTag
                && viewModel.workspace.navigationPath == navigationPath
        }
    }

    @discardableResult
    func perform(
        authenticate: @escaping @MainActor () async throws -> Void,
        isCurrent: @escaping @MainActor () -> Bool,
        disclose: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        guard !isAuthenticating, isCurrent() else { return nil }
        let requestID = UUID()
        self.requestID = requestID
        isAuthenticating = true
        let task = Task { [weak self] in
            defer {
                if self?.requestID == requestID {
                    self?.requestID = nil
                    self?.task = nil
                    self?.isAuthenticating = false
                }
            }
            do {
                try await authenticate()
            } catch {
                return
            }
            guard !Task.isCancelled, self?.requestID == requestID, isCurrent() else { return }
            disclose()
        }
        self.task = task
        return task
    }

    func invalidate() {
        requestID = nil
        task?.cancel()
        task = nil
        isAuthenticating = false
    }
}
