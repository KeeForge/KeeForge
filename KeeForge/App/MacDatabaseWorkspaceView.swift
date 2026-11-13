#if os(macOS)
import SwiftUI

/// The window's `MacWorkspaceToolbar` owns the toolbar and search field while
/// this is shown; the root host stops bridging SwiftUI toolbars for it.
struct MacDatabaseWorkspaceView: View {
    let viewModel: DatabaseViewModel
    let presentation: MacWorkspacePresentation
    @Environment(MacWindowWorkspace.self) private var workspace

    var body: some View {
        MacWorkspacePresentationHost(viewModel: viewModel, presentation: presentation) {
            Group {
                if let controller = workspace.splitViewController, controller.session === viewModel {
                    MacWorkspaceSplitView(controller: controller)
                        .id(ObjectIdentifier(controller))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
