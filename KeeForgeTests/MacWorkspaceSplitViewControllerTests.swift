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

    func testTheSplitRunsUnderTheTitlebarAndColumnsTakeTheirInsetFromTheSafeArea() async throws {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let session = DatabaseViewModel(
            databaseReference: try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false),
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false }
        )
        let windowController = DatabaseWindowController(session: session,
            windowRegistry: MacDatabaseWindowRegistry(sessionStore: DatabaseSessionStore()),
            enrollment: TOTPEnrollmentCoordinator(), persistsLayout: false)
        windowController.loadWindow()
        let window = try XCTUnwrap(windowController.window)
        addTeardownBlock { @MainActor in
            session.lockRequest(force: true)
            window.close()
        }
        await session.unlock(password: "testpassword123")
        let split = try await waitForSplit(windowController)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertGreaterThan(contentView.safeAreaInsets.top, 0, "The window has a titlebar area to run under")

        let splitFrame = split.splitView.convert(split.splitView.bounds, to: contentView)
        XCTAssertEqual(splitFrame.maxY, contentView.bounds.maxY, accuracy: 0.5, "The split's top is the content view's top")
        XCTAssertEqual(splitFrame.height, contentView.bounds.height, accuracy: 0.5)
        let sidebar = split.splitViewItems[0]
        let sidebarFrame = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: contentView)
        XCTAssertEqual(sidebarFrame.height, contentView.bounds.height, accuracy: 0.5, "The sidebar runs full height")
        for item in split.splitViewItems {
            XCTAssertTrue(item.allowsFullHeightLayout)
        }
        XCTAssertGreaterThan(split.entryList.view.safeAreaInsets.top, 0, "The entries column insets below the toolbar")
        XCTAssertGreaterThan(split.splitViewItems[2].viewController.view.safeAreaInsets.top, 0,
                             "The detail column insets below the toolbar")
        XCTAssertTrue(split.entryList.scrollView.automaticallyAdjustsContentInsets)
        let list = split.entryList.view
        XCTAssertEqual(split.entryList.header.frame.maxY, list.bounds.maxY - list.safeAreaInsets.top, accuracy: 0.5,
                       "The list header sits right under the toolbar")

        let outline = try XCTUnwrap((sidebar.viewController as? MacSidebarViewController)?.outlineView)
        XCTAssertTrue(window.makeFirstResponder(outline))
        sidebar.isCollapsed = false
        split.toggleSidebar(nil)
        XCTAssertTrue(sidebar.isCollapsed)
        split.toggleSidebar(nil)
        XCTAssertFalse(sidebar.isCollapsed)
        contentView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(sidebar.viewController.view.frame.width, 0, "The sidebar shows again")
    }

    private func waitForSplit(_ controller: DatabaseWindowController) async throws -> MacWorkspaceSplitViewController {
        for _ in 0..<100 {
            if let split = controller.workspaceSplitViewController, split.isViewLoaded, split.view.window != nil {
                split.view.window?.contentView?.layoutSubtreeIfNeeded()
                return split
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(controller.workspaceSplitViewController)
    }

    private func makeSession() throws -> DatabaseViewModel {
        let reference = try TestDatabaseSupport.makeReference(
            for: KDBXTestFixture.test.url(in: Bundle(for: Self.self)), autoFillEnabled: false
        )
        return DatabaseViewModel(databaseReference: reference)
    }
}
#endif
