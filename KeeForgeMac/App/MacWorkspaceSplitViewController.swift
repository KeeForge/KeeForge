import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class MacWindowWorkspace {
    private(set) var splitViewController: MacWorkspaceSplitViewController?
    private(set) var toolbar: MacWorkspaceToolbar?
    private let presentation: MacWorkspacePresentation
    private let splitAutosaveName: NSSplitView.AutosaveName?

    init(presentation: MacWorkspacePresentation, splitAutosaveName: NSSplitView.AutosaveName? = nil) {
        self.presentation = presentation
        self.splitAutosaveName = splitAutosaveName
    }

    static func subtitle(for session: DatabaseViewModel?) -> String {
        guard let session else { return "" }
        if session.searchText.isEmpty == false { return String(localized: "Search") }
        if let tag = session.workspace.selectedTag { return tag }
        guard let groupID = session.workspace.selectedGroupID ?? session.visibleRootGroupID else { return "" }
        return session.group(withID: groupID)?.name ?? ""
    }

    func show(_ session: DatabaseViewModel?) {
        guard splitViewController?.session !== session else { return }
        let controller = session.map {
            MacWorkspaceSplitViewController(session: $0, presentation: presentation, autosaveName: splitAutosaveName)
        }
        toolbar = controller.map { MacWorkspaceToolbar(session: $0.session, presentation: presentation) }
        splitViewController = controller
    }
}

@MainActor
final class MacWorkspaceSplitViewController: NSSplitViewController {
    let session: DatabaseViewModel

    /// Each database keeps its own widths and collapse state; nil keeps the layout unsaved.
    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation, autosaveName: NSSplitView.AutosaveName? = nil) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.host(session: session, presentation: presentation,
            MacWorkspaceSidebarColumn(viewModel: session, presentation: presentation)
        ))
        sidebar.canCollapse = true
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 340
        sidebar.preferredThicknessFraction = 240.0 / 1080.0
        addSplitViewItem(sidebar)

        let entries = NSSplitViewItem(contentListWithViewController: Self.host(session: session, presentation: presentation,
            MacWorkspaceEntriesColumn(viewModel: session, presentation: presentation)
        ))
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

        if session.workspace.selectedGroupID == nil, session.workspace.selectedTag == nil {
            session.workspace.selectedGroupID = session.visibleRootGroupID
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
