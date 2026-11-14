#if os(macOS)
import Foundation
import Observation

/// A Mac window's attachment Quick Look and Share. It writes a plaintext temporary copy only for
/// an explicit preview or share, holds at most one, and removes it when the preview ends, the share
/// finishes or fails, the request stops being current (lock, another entry, another session, the
/// attachment changed) or the window closes. The session's `clear(owner:)` on lock and the launch
/// purge stay as backstops.
@MainActor @Observable
final class AttachmentPreviewSession {
    enum Purpose: Equatable {
        case preview
        case share
    }

    struct Request: Equatable {
        let entryID: UUID
        let attachmentIndex: Int
        let purpose: Purpose
    }

    enum State: Equatable {
        case idle
        case loading(Request)
        case previewing(Request, URL)
        case sharing(Request, URL)
        /// The database no longer holds the file's bytes.
        case unavailable(Request)
    }

    private struct Context {
        let session: DatabaseViewModel
        let lockCycleID: Int
        let attachment: KPAttachment
    }

    private(set) var state: State = .idle
    private var context: Context?
    private let loadCoordinator = AttachmentLoadCoordinator()
    private let currentSession: @MainActor () -> DatabaseViewModel?
    private let store: any AttachmentPreviewFileStoring.Type
    private let loadData: @MainActor (KPAttachment, DatabaseViewModel) async -> Data?

    /// `currentSession` answers which session the window shows now.
    init(
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        store: any AttachmentPreviewFileStoring.Type = AttachmentPreviewFileStore.self,
        loadData: @escaping @MainActor (KPAttachment, DatabaseViewModel) async -> Data? = {
            await $1.attachmentData(for: $0)
        }
    ) {
        self.currentSession = currentSession
        self.store = store
        self.loadData = loadData
        loadCoordinator.activate()
    }

    var previewURL: URL? {
        if case .previewing(_, let url) = state { return url }
        return nil
    }

    var shareURL: URL? {
        if case .sharing(_, let url) = state { return url }
        return nil
    }

    func isLoading(entryID: UUID, attachmentIndex: Int) -> Bool {
        guard case .loading(let request) = state else { return false }
        return request.entryID == entryID && request.attachmentIndex == attachmentIndex
    }

    // MARK: - Requests

    @discardableResult
    func preview(attachmentAt index: Int, ofEntry entryID: UUID, in session: DatabaseViewModel) -> Task<Void, Never>? {
        start(Request(entryID: entryID, attachmentIndex: index, purpose: .preview), in: session)
    }

    @discardableResult
    func share(attachmentAt index: Int, ofEntry entryID: UUID, in session: DatabaseViewModel) -> Task<Void, Never>? {
        start(Request(entryID: entryID, attachmentIndex: index, purpose: .share), in: session)
    }

    // MARK: - Cleanup triggers

    /// The Quick Look panel gave up control. A share in progress keeps its file.
    func previewEnded() {
        if case .previewing = state { close() }
    }

    /// The share picker or the chosen service finished, successfully or not.
    func shareFinished() {
        if case .sharing = state { close() }
    }

    /// Called when the lock cycle, the selected entry, the window's session or the entry's content
    /// may have changed; closes whatever is no longer current.
    func reconcile() {
        guard let request = activeRequest, isCurrent(request) == false else { return }
        close()
    }

    /// The window is closing: nothing is written after this.
    func windowClosed() {
        loadCoordinator.deactivate()
        close()
    }

    /// Removes the file, cancels a load and returns to idle.
    func close() {
        loadCoordinator.invalidate()
        switch state {
        case .previewing(_, let url), .sharing(_, let url):
            if let session = context?.session {
                store.remove(url, owner: session.attachmentPreviewOwnerID)
            }
        case .idle, .loading, .unavailable:
            break
        }
        state = .idle
        context = nil
    }

    // MARK: - Private

    private var activeRequest: Request? {
        switch state {
        case .idle: nil
        case .loading(let request), .previewing(let request, _), .sharing(let request, _),
             .unavailable(let request): request
        }
    }

    private func start(_ request: Request, in session: DatabaseViewModel) -> Task<Void, Never>? {
        close()
        guard loadCoordinator.isActive, currentSession() === session, isUsable(session),
              session.workspace.selectedEntryID == request.entryID,
              let attachments = session.entry(withID: request.entryID)?.attachments,
              attachments.indices.contains(request.attachmentIndex) else { return nil }
        let attachment = attachments[request.attachmentIndex]
        context = Context(session: session, lockCycleID: session.lockCycleID, attachment: attachment)
        state = .loading(request)
        let loadData = loadData
        return loadCoordinator.load(
            operation: { await loadData(attachment, session) },
            isCurrent: { [weak self] in self?.isCurrent(request) == true && self?.state == .loading(request) },
            onCompletion: { [weak self] data in self?.finish(request, data: data, session: session) }
        )
    }

    /// Runs on the main actor right after `isCurrent`, so nothing can lock between the check and the write.
    private func finish(_ request: Request, data: Data?, session: DatabaseViewModel) {
        guard let data else {
            state = .unavailable(request)
            return
        }
        guard let url = try? store.write(data, suggestedName: context?.attachment.name ?? "",
                                         owner: session.attachmentPreviewOwnerID) else {
            state = .idle
            context = nil
            return
        }
        state = request.purpose == .preview ? .previewing(request, url) : .sharing(request, url)
    }

    private func isCurrent(_ request: Request) -> Bool {
        guard let context, currentSession() === context.session, isUsable(context.session),
              context.session.lockCycleID == context.lockCycleID,
              context.session.workspace.selectedEntryID == request.entryID,
              let attachments = context.session.entry(withID: request.entryID)?.attachments,
              attachments.indices.contains(request.attachmentIndex) else { return false }
        return attachments[request.attachmentIndex] == context.attachment
    }

    private func isUsable(_ session: DatabaseViewModel) -> Bool {
        session.state == .unlocked && session.sessionKey != nil
    }
}
#endif
