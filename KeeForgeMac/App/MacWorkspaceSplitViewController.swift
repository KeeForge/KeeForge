import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class MacWindowWorkspace {
    private(set) var splitViewController: MacWorkspaceSplitViewController?
    private(set) var toolbar: MacWorkspaceToolbar?
    private let presentation: MacWorkspacePresentation
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private let splitAutosaveName: NSSplitView.AutosaveName?
    private let currentSession: @MainActor () -> DatabaseViewModel?

    /// `currentSession` is the window's own session while it still owns that window.
    init(
        presentation: MacWorkspacePresentation,
        splitAutosaveName: NSSplitView.AutosaveName? = nil,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?
    ) {
        self.presentation = presentation
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
            MacWorkspaceSplitViewController(session: $0, presentation: presentation, autosaveName: splitAutosaveName,
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
    private(set) lazy var alerts = MacWorkspaceAlerts(session: session, presentation: presentation) { [weak self] in
        self?.view.window
    }
    private let presentation: MacWorkspacePresentation
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var statusClock: Timer?
    private var hasStartedAlerts = false

    /// Each database keeps its own widths and collapse state; nil keeps the layout unsaved.
    init(
        session: DatabaseViewModel,
        presentation: MacWorkspacePresentation,
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
        entries.minimumThickness = 260
        entries.maximumThickness = 460
        entries.preferredThicknessFraction = 320.0 / 1080.0
        addSplitViewItem(entries)

        let detail = NSSplitViewItem(viewController: Self.host(session: session, presentation: presentation,
            MacWorkspaceDetailColumn(viewModel: session, presentation: presentation)
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
    }

    /// Alerts wait for a window to attach to.
    override func viewDidAppear() {
        super.viewDidAppear()
        if hasStartedAlerts == false {
            hasStartedAlerts = true
            alerts.start()
        }
        statusClock?.invalidate()
        statusClock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentation.advanceStatusClock() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        statusClock?.invalidate()
        statusClock = nil
    }

    private func noteSidebarCollapse() {
        let isCollapsed = splitViewItems.first?.isCollapsed ?? false
        if presentation.isSidebarCollapsed != isCollapsed { presentation.isSidebarCollapsed = isCollapsed }
    }

    private static func host<Content: View>(session: DatabaseViewModel, presentation: MacWorkspacePresentation, _ content: Content) -> NSViewController {
        let hosting = NSHostingController(rootView: MacWorkspaceHostedColumn(session: session, presentation: presentation, content: content))
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
    let content: Content

    var body: some View {
        content
            .environment(presentation)
            .disabled(session.isSaving)
            .modifier(MacHostingAppearance())
    }
}
