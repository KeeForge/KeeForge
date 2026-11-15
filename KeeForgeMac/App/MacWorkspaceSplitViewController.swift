import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class MacWindowWorkspace {
    private(set) var splitViewController: MacWorkspaceSplitViewController?
    private(set) var toolbar: MacWorkspaceToolbar?
    private let presentation: MacWorkspacePresentation
    private let attachmentPreview: MacAttachmentPreviewController
    private let largeType: MacLargeTypePanelController
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private let splitAutosaveName: NSSplitView.AutosaveName?
    private let currentSession: @MainActor () -> DatabaseViewModel?

    /// `currentSession` is the window's own session while it still owns that window.
    init(
        presentation: MacWorkspacePresentation,
        attachmentPreview: MacAttachmentPreviewController,
        largeType: MacLargeTypePanelController = .shared,
        splitAutosaveName: NSSplitView.AutosaveName? = nil,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?
    ) {
        self.presentation = presentation
        self.attachmentPreview = attachmentPreview
        self.largeType = largeType
        self.splitAutosaveName = splitAutosaveName
        self.currentSession = currentSession
    }

    static func subtitle(for session: DatabaseViewModel?) -> String {
        guard let session else { return "" }
        if session.searchText.isEmpty == false { return String(localized: "Search") }
        if let tag = session.workspace.selectedTag { return tag }
        if let collection = session.workspace.selectedCollection { return collection.title }
        guard let groupID = session.workspace.selectedGroupID ?? session.workspaceRootGroupID else { return "" }
        if groupID == session.currentRootGroup?.recycleBinUUID { return String(localized: "Deleted Entries") }
        return session.group(withID: groupID)?.name ?? ""
    }

    func show(_ session: DatabaseViewModel?) {
        guard splitViewController?.session !== session else { return }
        let controller = session.map {
            MacWorkspaceSplitViewController(session: $0, presentation: presentation,
                                            attachmentPreview: attachmentPreview, largeType: largeType,
                                            autosaveName: splitAutosaveName,
                                            currentSession: currentSession)
        }
        toolbar = controller.map {
            MacWorkspaceToolbar(session: $0.session, presentation: presentation, splitView: $0.splitView)
        }
        splitViewController = controller
    }
}

@MainActor
final class MacWorkspaceSplitViewController: NSSplitViewController {
    let session: DatabaseViewModel
    let entryList: MacEntryListViewController
    private let presentation: MacWorkspacePresentation
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var statusClock: Timer?
    /// The list's width before a hidden sidebar widened it, put back when the sidebar returns.
    private var listWidthBeforeCollapse: CGFloat?
    private var restoresListWidth = false
    private var listFrameObservers: [NSObjectProtocol] = []
    private var hiddenListObserver: NSObjectProtocol?
    private var hiddenListWidth: CGFloat?
    static let defaultSidebarWidth: CGFloat = 240
    static let defaultListWidth: CGFloat = 320
    static let defaultDetailRoom: CGFloat = 440
    private var appliesDefaultWidths = true
    static let listMinimumThickness: CGFloat = 260
    static let listMaximumThickness: CGFloat = 460
    /// With the sidebar hidden the list also holds the window controls and the toggle (about 140 pt on macOS 27),
    /// so it keeps the room search has beside a shown sidebar; any less and the system collapses search to an icon.
    static let collapsedListMinimumThickness: CGFloat = listMinimumThickness + 140

    /// Each database keeps its own widths and collapse state; nil keeps the layout unsaved.
    init(
        session: DatabaseViewModel,
        presentation: MacWorkspacePresentation,
        attachmentPreview: MacAttachmentPreviewController,
        largeType: MacLargeTypePanelController = .shared,
        autosaveName: NSSplitView.AutosaveName? = nil,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?
    ) {
        self.session = session
        self.presentation = presentation
        entryList = MacEntryListViewController(session: session, presentation: presentation, currentSession: currentSession)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebar = NSSplitViewItem(sidebarWithViewController: MacSidebarViewController(session: session, presentation: presentation))
        sidebar.canCollapse = true
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 340
        sidebar.preferredThicknessFraction = 240.0 / 1080.0
        addSplitViewItem(sidebar)
        sidebarCollapseObservation = sidebar.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.noteSidebarCollapse() }
        }

        let entries = NSSplitViewItem(contentListWithViewController: entryList)
        entries.minimumThickness = Self.listMinimumThickness
        entries.maximumThickness = Self.listMaximumThickness
        entries.preferredThicknessFraction = 320.0 / 1080.0
        addSplitViewItem(entries)

        let detail = NSSplitViewItem(viewController: Self.host(session: session, presentation: presentation,
            largeType: largeType,
            MacWorkspaceDetailColumn(viewModel: session, presentation: presentation,
                                     attachmentPreview: attachmentPreview, currentSession: currentSession)
        ))
        detail.minimumThickness = 280
        detail.holdingPriority = .defaultLow
        addSplitViewItem(detail)
        splitView.autosaveName = autosaveName

        if MacSidebarSelection(workspace: session.workspace) == nil {
            session.workspace.selectedGroupID = session.workspaceRootGroupID
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        statusClock?.invalidate()
        listFrameObservers.forEach(NotificationCenter.default.removeObserver)
        hiddenListObserver.map(NotificationCenter.default.removeObserver)
    }

    /// Alerts wait for a window to attach to.
    override func viewDidAppear() {
        super.viewDidAppear()
        applyDefaultWidthsIfUnsaved()
        statusClock?.invalidate()
        statusClock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentation.advanceStatusClock() }
        }
    }

    /// The boards' 240 and 320 pt columns, once, for a database with no saved layout: AppKit opens
    /// a new split at its minimums and ignores `preferredThicknessFraction`. A window too narrow to
    /// leave the detail its room keeps the minimums, as DarkMin draws the 900 pt window.
    func applyDefaultWidthsIfUnsaved(defaults: UserDefaults = .standard) {
        guard appliesDefaultWidths else { return }
        appliesDefaultWidths = false
        if let name = splitView.autosaveName, defaults.object(forKey: "NSSplitView Subview Frames \(name)") != nil { return }
        guard splitViewItems.count == 3, splitViewItems[0].isCollapsed == false,
              splitView.bounds.width >= Self.defaultSidebarWidth + Self.defaultListWidth + Self.defaultDetailRoom else { return }
        splitView.setPosition(Self.defaultSidebarWidth, ofDividerAt: 0)
        splitView.setPosition(Self.defaultSidebarWidth + splitView.dividerThickness + Self.defaultListWidth, ofDividerAt: 1)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        statusClock?.invalidate()
        statusClock = nil
    }

    private func noteSidebarCollapse() {
        let isCollapsed = splitViewItems.first?.isCollapsed ?? false
        if presentation.isSidebarCollapsed != isCollapsed { presentation.isSidebarCollapsed = isCollapsed }
        fitListToSidebar(isCollapsed: isCollapsed)
    }

    /// Thickness limits, not divider positions, so the per-database autosave keeps whatever the layout settles on.
    private func fitListToSidebar(isCollapsed: Bool) {
        guard splitViewItems.count > 1 else { return }
        let entries = splitViewItems[1]
        let width = entries.viewController.view.frame.width
        if isCollapsed {
            guard entries.minimumThickness != Self.collapsedListMinimumThickness else { return }
            listWidthBeforeCollapse = width > 0 && width < Self.collapsedListMinimumThickness ? width : nil
            restoresListWidth = false
            stopObservingListFrame()
            entries.maximumThickness = Self.listMaximumThickness
            entries.minimumThickness = Self.collapsedListMinimumThickness
            observeHiddenListWidth(entries.viewController.view)
        } else {
            guard entries.minimumThickness == Self.collapsedListMinimumThickness else { return }
            entries.minimumThickness = Self.listMinimumThickness
            hiddenListObserver.map(NotificationCenter.default.removeObserver)
            hiddenListObserver = nil
            // A list dragged wider while the sidebar was hidden keeps that width. The show may already have
            // laid out, so the width the list had while hidden decides, not the current one.
            let hiddenWidth = hiddenListWidth ?? width
            hiddenListWidth = nil
            if let saved = listWidthBeforeCollapse, hiddenWidth <= Self.collapsedListMinimumThickness + 1 {
                entries.maximumThickness = saved
                restoresListWidth = true
                releaseListCapOnceNarrowed()
            }
            listWidthBeforeCollapse = nil
        }
    }

    private func observeHiddenListWidth(_ list: NSView) {
        list.postsFrameChangedNotifications = true
        hiddenListObserver.map(NotificationCenter.default.removeObserver)
        hiddenListWidth = nil
        hiddenListObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: list, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.splitViewItems.first?.isCollapsed == true else { return }
                self.hiddenListWidth = list.frame.width
            }
        }
    }

    /// The cap holds until the list has narrowed to it, then the user may drag it wider again.
    private func releaseListCapOnceNarrowed() {
        guard splitViewItems.count > 1 else { return }
        stopObservingListFrame()
        // The list narrowing and the sidebar widening may land in different passes; either may release the cap.
        listFrameObservers = [splitViewItems[0].viewController.view, splitViewItems[1].viewController.view].map { view in
            view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseListCapIfNarrowed() }
            }
        }
    }

    private func releaseListCapIfNarrowed() {
        guard restoresListWidth, splitViewItems.count > 1 else { return }
        let entries = splitViewItems[1]
        let list = entries.viewController.view
        // Released only once the sidebar has its width again, or the list takes that room back.
        guard list.frame.width <= entries.maximumThickness + 1,
              splitViewItems[0].viewController.view.frame.width >= splitViewItems[0].minimumThickness - 1 else { return }
        restoresListWidth = false
        stopObservingListFrame()
        // Not inside the layout pass that narrowed it.
        Task { @MainActor [weak self, weak entries] in
            guard let self, let entries, restoresListWidth == false else { return }
            let width = entries.maximumThickness
            entries.maximumThickness = Self.listMaximumThickness
            // Lifting the cap lets AppKit hand the list back its hidden-sidebar width; keep the restored one.
            splitView.setPosition(splitViewItems[0].viewController.view.frame.maxX + width, ofDividerAt: 1)
        }
    }

    private func stopObservingListFrame() {
        listFrameObservers.forEach(NotificationCenter.default.removeObserver)
        listFrameObservers = []
    }

    private static func host<Content: View>(
        session: DatabaseViewModel, presentation: MacWorkspacePresentation,
        largeType: MacLargeTypePanelController, _ content: Content
    ) -> NSViewController {
        let hosting = NSHostingController(rootView: MacWorkspaceHostedColumn(session: session, presentation: presentation,
                                                                             largeType: largeType, content: content))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        return hosting
    }
}

struct MacWorkspaceSplitView: NSViewControllerRepresentable {
    let controller: MacWorkspaceSplitViewController

    func makeNSViewController(context: Context) -> MacWorkspaceSplitViewController { controller }
    func updateNSViewController(_ controller: MacWorkspaceSplitViewController, context: Context) {}
}

private struct MacWorkspaceHostedColumn<Content: View>: View {
    let session: DatabaseViewModel
    let presentation: MacWorkspacePresentation
    let largeType: MacLargeTypePanelController
    let content: Content

    var body: some View {
        content
            .environment(presentation)
            .environment(largeType)
            .disabled(session.isSaving)
            .modifier(MacHostingAppearance())
    }
}
