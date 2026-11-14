import AppKit
import Quartz

/// The system Quick Look panel, behind a seam so tests never show it.
@MainActor
protocol MacPreviewPanelPresenting: AnyObject {
    /// The panel went off screen by any route: its own close control, the system, or `close`.
    var onHide: (@MainActor () -> Void)? { get set }
    func show()
    func reload()
    /// Closes the panel if `controller` controls it.
    func close(controlledBy controller: AnyObject)
}

@MainActor
final class MacSystemPreviewPanel: MacPreviewPanelPresenting {
    var onHide: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var isAppActive = true

    func show() {
        guard let panel = QLPreviewPanel.shared() else { return }
        observeHiding(of: panel)
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Quick Look may keep its controller while hidden, so control ending is not enough: a close
    /// posts `willClose`, an order-out only changes occlusion. The panel also hides while the app
    /// is inactive and comes back with it, which is not an end.
    private func observeHiding(of panel: QLPreviewPanel) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let hidden: @Sendable (Notification) -> Void = { [weak self] notification in
            let closing = notification.name == NSWindow.willCloseNotification
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, closing || (self.isAppActive && window?.isVisible == false) else { return }
                self.onHide?()
            }
        }
        let activity: @Sendable (Notification) -> Void = { [weak self] notification in
            let active = notification.name == NSApplication.didBecomeActiveNotification
            MainActor.assumeIsolated { self?.isAppActive = active }
        }
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main, using: hidden),
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main,
                               using: hidden),
            center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main,
                               using: activity),
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
                               using: activity),
        ]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        QLPreviewPanel.shared()?.reloadData()
    }

    func close(controlledBy controller: AnyObject) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.currentController as AnyObject? === controller else { return }
        panel.orderOut(nil)
    }
}

/// A database window's Quick Look and Share for attachments, over its `AttachmentPreviewSession`.
/// It sits in the window's responder chain (after the window), so the shared `QLPreviewPanel`
/// takes this window's preview as its data source. It closes the panel or forgets the share when
/// the session closes its file (lock, another entry, a content change, window close), and tells
/// the session when the panel gives up control or a share ends, which removes the file.
@MainActor
final class MacAttachmentPreviewController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate,
    NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    /// Returns the picker it showed, whose callbacks then belong to that share.
    typealias SharePickerPresenter = @MainActor (URL, NSView, MacAttachmentPreviewController) -> NSSharingServicePicker?

    let previews: AttachmentPreviewSession
    private let database: DatabaseViewModel
    private let panel: any MacPreviewPanelPresenting
    private let presentSharePicker: SharePickerPresenter
    private let observation = MacObservation()
    private weak var window: NSWindow?
    private weak var shareAnchor: NSView?
    private var presentedShareURL: URL?
    /// The picker shown for `presentedShareURL`; an older picker's cancel is ignored.
    private weak var presentedSharePicker: NSSharingServicePicker?
    private(set) var isControllingPanel = false

    /// `previews` belongs to `database`'s window; `currentSession` is that window's while it owns it.
    init(
        database: DatabaseViewModel,
        previews: AttachmentPreviewSession,
        panel: any MacPreviewPanelPresenting = MacSystemPreviewPanel(),
        presentSharePicker: @escaping SharePickerPresenter = MacAttachmentPreviewController.showSystemSharePicker
    ) {
        self.database = database
        self.previews = previews
        self.panel = panel
        self.presentSharePicker = presentSharePicker
        super.init()
        panel.onHide = { [weak self] in self?.panelHid() }
        observation.start(reading: { [weak self] in
            self?.readState()
        }, onChange: { [weak self] _ in
            self?.previews.reconcile()
            self?.syncPresentation()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts the controller right after `window` in its responder chain.
    func install(in window: NSWindow) {
        self.window = window
        guard window.nextResponder !== self else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    // MARK: - Requests from the detail

    func isPreviewing(entryID: UUID, attachmentIndex: Int) -> Bool {
        guard case .previewing(let request, _) = previews.state else { return false }
        return request.entryID == entryID && request.attachmentIndex == attachmentIndex
    }

    @discardableResult
    func preview(attachmentAt index: Int, ofEntry entryID: UUID) -> Task<Void, Never>? {
        previews.preview(attachmentAt: index, ofEntry: entryID, in: database)
    }

    /// Space on a row: Quick Look for that attachment, or closes the one already shown.
    @discardableResult
    func togglePreview(attachmentAt index: Int, ofEntry entryID: UUID) -> Task<Void, Never>? {
        guard isPreviewing(entryID: entryID, attachmentIndex: index) == false else {
            previews.close()
            return nil
        }
        return preview(attachmentAt: index, ofEntry: entryID)
    }

    /// `anchor` is the Share button the picker opens from.
    @discardableResult
    func share(attachmentAt index: Int, ofEntry entryID: UUID, from anchor: NSView?) -> Task<Void, Never>? {
        shareAnchor = anchor
        return previews.share(attachmentAt: index, ofEntry: entryID, in: database)
    }

    /// The window is closing: removes the file and closes the panel.
    func windowClosed() {
        observation.cancel()
        previews.windowClosed()
        syncPresentation()
    }

    // MARK: - State

    private struct ObservedState: Equatable {
        let state: DatabaseViewModel.State
        let lockCycleID: Int
        let contentRevision: Int
        let selectedEntryID: UUID?
        let previewState: AttachmentPreviewSession.State
    }

    private func readState() -> ObservedState {
        ObservedState(state: database.state, lockCycleID: database.lockCycleID,
                      contentRevision: database.contentRevision,
                      selectedEntryID: database.workspace.selectedEntryID, previewState: previews.state)
    }

    private func syncPresentation() {
        switch previews.state {
        case .previewing:
            presentedShareURL = nil
            if isControllingPanel { panel.reload() } else { panel.show() }
        case .loading(let request) where request.purpose == .preview:
            // The panel stays up while the next attachment loads.
            presentedShareURL = nil
        case .sharing(_, let url):
            panel.close(controlledBy: self)
            guard presentedShareURL != url else { return }
            presentedShareURL = url
            guard let anchor = shareAnchor ?? window?.contentView else {
                previews.shareFinished(url)
                return
            }
            presentedSharePicker = presentSharePicker(url, anchor, self)
        case .idle, .loading, .unavailable:
            presentedShareURL = nil
            panel.close(controlledBy: self)
        }
    }

    static func showSystemSharePicker(
        _ url: URL, from anchor: NSView, delegate: MacAttachmentPreviewController
    ) -> NSSharingServicePicker? {
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = delegate
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        return picker
    }

    // MARK: - QLPreviewPanelController

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previews.previewURL != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            isControllingPanel = true
            panel?.dataSource = self
            panel?.delegate = self
            panel?.reloadData()
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            isControllingPanel = false
            if panel?.dataSource === self { panel?.dataSource = nil }
            if panel?.delegate === self { panel?.delegate = nil }
            endPreview()
        }
    }

    /// The panel left the screen while this window's preview was in it.
    private func panelHid() {
        guard isControllingPanel else { return }
        endPreview()
    }

    private func endPreview() {
        switch previews.state {
        case .loading(let request) where request.purpose == .preview:
            previews.close()
        default:
            previews.previewEnded()
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previews.previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { previews.previewURL }
        return url.map { $0 as NSURL }
    }

    // MARK: - QLPreviewPanelDelegate

    /// Space closes the panel, as it opened it.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event?.type == .keyDown, event?.charactersIgnoringModifiers == " " else { return false }
        MainActor.assumeIsolated { previews.close() }
        return true
    }

    // MARK: - NSSharingServicePickerDelegate

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        MainActor.assumeIsolated { self }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let cancelled = service == nil
        let picker = ObjectIdentifier(sharingServicePicker)
        MainActor.assumeIsolated {
            guard cancelled, presentedSharePicker.map(ObjectIdentifier.init) == picker,
                  let url = presentedShareURL else { return }
            previews.shareFinished(url)
        }
    }

    // MARK: - NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        shareFinished(items)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        shareFinished(items)
    }

    /// A service's callback carries the items it was given, which name the share's file.
    private func shareFinished(_ items: [Any]) {
        for case let url as URL in items { previews.shareFinished(url) }
    }
}
