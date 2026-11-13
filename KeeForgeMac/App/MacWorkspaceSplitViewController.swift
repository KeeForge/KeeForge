import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class MacWindowWorkspace {
    private(set) var splitViewController: MacWorkspaceSplitViewController?
    private let presentation: MacWorkspacePresentation

    init(presentation: MacWorkspacePresentation) {
        self.presentation = presentation
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
        splitViewController = session.map {
            MacWorkspaceSplitViewController(session: $0, presentation: presentation)
        }
    }
}

@MainActor
final class MacWorkspaceSplitViewController: NSSplitViewController {
    static let autosaveName = NSSplitView.AutosaveName("MacDatabaseWorkspace")
    let session: DatabaseViewModel

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation) {
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
        splitView.autosaveName = Self.autosaveName

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
