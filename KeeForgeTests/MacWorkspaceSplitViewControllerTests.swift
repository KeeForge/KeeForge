#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceSplitViewControllerTests: XCTestCase {
    func testNativeColumnConstraintsAndSidebarCommand() throws {
        let session = try makeSession()
        let autosaveName = MacWindowRestorationStore.splitViewAutosaveName(for: session.databaseReference.id)
        let named = MacWorkspaceSplitViewController(session: session, presentation: MacWorkspacePresentation(),
            autosaveName: autosaveName, currentSession: { nil })
        XCTAssertEqual(named.splitView.autosaveName, autosaveName)
        // Unnamed, so toggling below writes nothing into the host app's defaults.
        let controller = MacWorkspaceSplitViewController(session: session, presentation: MacWorkspacePresentation(),
            currentSession: { nil })
        XCTAssertEqual(controller.splitViewItems.count, 3)
        let sidebar = controller.splitViewItems[0]
        let entries = controller.splitViewItems[1]
        XCTAssertEqual(sidebar.behavior, .sidebar)
        let outline = try XCTUnwrap(sidebar.viewController as? MacSidebarViewController)
        XCTAssertTrue(outline.session === session)
        let stack = try XCTUnwrap(outline.view as? NSStackView)
        XCTAssertTrue(stack.arrangedSubviews.last === outline.statusCard, "The status card sits under the outline")
        XCTAssertTrue(sidebar.canCollapse)
        XCTAssertEqual(sidebar.minimumThickness, 200)
        XCTAssertEqual(sidebar.maximumThickness, 340)
        XCTAssertEqual(entries.behavior, .contentList)
        let list = try XCTUnwrap(entries.viewController as? MacEntryListViewController)
        XCTAssertTrue(list === controller.entryList)
        XCTAssertTrue(list.session === session)
        XCTAssertEqual(entries.minimumThickness, 260)
        XCTAssertEqual(entries.maximumThickness, 460)
        XCTAssertNil(controller.splitView.autosaveName)
        XCTAssertTrue(controller.splitView.isVertical)
        sidebar.isCollapsed = false
        controller.toggleSidebar(nil)
        XCTAssertTrue(sidebar.isCollapsed)
        controller.toggleSidebar(nil)
        XCTAssertFalse(sidebar.isCollapsed)
    }

    func testWindowKeepsControllerUntilSessionChangesThenReleasesIt() throws {
        let workspace = MacWindowWorkspace(presentation: MacWorkspacePresentation(), currentSession: { nil })
        let first = try makeSession()
        let second = try makeSession()
        weak var original: MacWorkspaceSplitViewController?
        autoreleasepool {
            workspace.show(first)
            original = workspace.splitViewController
            workspace.show(first)
            XCTAssertTrue(workspace.splitViewController === original)
            workspace.show(second)
        }
        XCTAssertNil(original)
        XCTAssertTrue(workspace.splitViewController?.session === second)
        XCTAssertTrue(workspace.toolbar?.session === second)
        weak var replacement: MacWorkspaceSplitViewController?
        weak var toolbar: MacWorkspaceToolbar?
        autoreleasepool {
            replacement = workspace.splitViewController
            toolbar = workspace.toolbar
            workspace.show(nil)
        }
        XCTAssertNil(workspace.splitViewController)
        XCTAssertNil(workspace.toolbar)
        XCTAssertNil(replacement)
        XCTAssertNil(toolbar)
    }

    private func makeSession() throws -> DatabaseViewModel {
        let reference = try TestDatabaseSupport.makeReference(
            for: KDBXTestFixture.test.url(in: Bundle(for: Self.self)), autoFillEnabled: false
        )
        return DatabaseViewModel(databaseReference: reference)
    }
}
#endif
