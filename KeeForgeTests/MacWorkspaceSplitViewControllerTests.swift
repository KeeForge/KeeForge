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
            attachmentPreview: .unshown(session), autosaveName: autosaveName, currentSession: { nil })
        XCTAssertEqual(named.splitView.autosaveName, autosaveName)
        // Unnamed, so toggling below writes nothing into the host app's defaults.
        let presentation = MacWorkspacePresentation()
        let controller = MacWorkspaceSplitViewController(session: session, presentation: presentation,
            attachmentPreview: .unshown(session), currentSession: { nil })
        XCTAssertEqual(controller.splitViewItems.count, 3)
        let sidebar = controller.splitViewItems[0]
        let entries = controller.splitViewItems[1]
        XCTAssertEqual(sidebar.behavior, .sidebar)
        let outline = try XCTUnwrap(sidebar.viewController as? MacSidebarViewController)
        XCTAssertTrue(outline.session === session)
        let stack = try XCTUnwrap(outline.view as? NSStackView)
        XCTAssertTrue(stack.arrangedSubviews.last === outline.statusCard, "The status card sits under the outline")
        XCTAssertFalse(outline.statusCard.isHidden, "Always shown for an open database")
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
        XCTAssertFalse(presentation.isSidebarCollapsed)
        controller.toggleSidebar(nil)
        XCTAssertTrue(sidebar.isCollapsed)
        XCTAssertTrue(presentation.isSidebarCollapsed, "The list header learns the sidebar is hidden")
        controller.toggleSidebar(nil)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertFalse(presentation.isSidebarCollapsed)
    }

    func testHidingTheSidebarWidensTheListAndShowingItRestoresTheWidth() async throws {
        let session = try makeSession()
        let controller = MacWorkspaceSplitViewController(session: session, presentation: MacWorkspacePresentation(),
            attachmentPreview: .unshown(session), currentSession: { nil })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1080, height: 700))
        let split = controller.splitView
        split.layoutSubtreeIfNeeded()
        let sidebar = controller.splitViewItems[0]
        let entries = controller.splitViewItems[1]
        let list = entries.viewController.view
        func settle() { for _ in 0..<3 { split.needsLayout = true; split.layoutSubtreeIfNeeded() } }

        split.setPosition(240, ofDividerAt: 0)
        settle()
        split.setPosition(split.arrangedSubviews[1].frame.minX + 280, ofDividerAt: 1)
        settle()
        XCTAssertEqual(list.frame.width, 280, accuracy: 1)

        sidebar.isCollapsed = true
        settle()
        XCTAssertEqual(list.frame.width, MacWorkspaceSplitViewController.collapsedListMinimumThickness, accuracy: 1,
                       "Room for the window controls and a full search field")

        sidebar.isCollapsed = false
        // The cap comes off on a later main-actor turn, after the layout pass that showed the sidebar.
        for _ in 0..<20 where entries.maximumThickness != MacWorkspaceSplitViewController.listMaximumThickness {
            await Task { @MainActor in }.value
            settle()
        }
        XCTAssertEqual(list.frame.width, 280, accuracy: 1, "Back to the width it had")
        XCTAssertEqual(entries.minimumThickness, MacWorkspaceSplitViewController.listMinimumThickness)
        XCTAssertEqual(entries.maximumThickness, MacWorkspaceSplitViewController.listMaximumThickness,
                       "The user can drag it wider again")

        sidebar.isCollapsed = true
        settle()
        split.setPosition(split.arrangedSubviews[1].frame.minX + 440, ofDividerAt: 1)
        settle()
        XCTAssertEqual(list.frame.width, 440, accuracy: 1)
        sidebar.isCollapsed = false
        settle()
        XCTAssertEqual(list.frame.width, 440, accuracy: 1, "A list dragged wider while hidden keeps its width")
    }

    func testAWindowRestoredWithTheSidebarHiddenGivesTheListItsWiderMinimum() throws {
        let session = try makeSession()
        let autosaveName = "MacWorkspaceSplitViewControllerTests-\(UUID().uuidString)"
        let defaultsKey = "NSSplitView Subview Frames \(autosaveName)"
        // NSSplitView's own autosave format: x, y, width, height, hidden, holding.
        UserDefaults.standard.set([
            "0.000000, 0.000000, 240.000000, 700.000000, YES, NO",
            "0.000000, 0.000000, 270.000000, 700.000000, NO, NO",
            "271.000000, 0.000000, 809.000000, 700.000000, NO, NO",
        ], forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        let presentation = MacWorkspacePresentation()
        let controller = MacWorkspaceSplitViewController(session: session, presentation: presentation,
            attachmentPreview: .unshown(session), autosaveName: autosaveName, currentSession: { nil })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1080, height: 700))
        for _ in 0..<3 { controller.splitView.needsLayout = true; controller.splitView.layoutSubtreeIfNeeded() }

        XCTAssertTrue(controller.splitViewItems[0].isCollapsed, "Restored hidden")
        XCTAssertTrue(presentation.isSidebarCollapsed)
        XCTAssertEqual(controller.splitViewItems[1].minimumThickness, MacWorkspaceSplitViewController.collapsedListMinimumThickness)
        XCTAssertGreaterThanOrEqual(controller.splitViewItems[1].viewController.view.frame.width,
                                    MacWorkspaceSplitViewController.collapsedListMinimumThickness - 1)
    }

    func testANewDatabaseOpensWithTheBoardColumnWidthsAndASavedLayoutKeepsItsOwn() throws {
        let session = try makeSession()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacWorkspaceSplitDefaultWidths.\(UUID().uuidString)"))
        defaults.set(["0 0 300 700"], forKey: "NSSplitView Subview Frames Saved")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func layOut(width: CGFloat = 1080) -> MacWorkspaceSplitViewController {
            let controller = MacWorkspaceSplitViewController(session: session, presentation: MacWorkspacePresentation(),
                attachmentPreview: .unshown(session), currentSession: { nil })
            window.contentViewController = controller
            window.setContentSize(NSSize(width: width, height: 700))
            controller.splitView.layoutSubtreeIfNeeded()
            return controller
        }
        func widths(_ controller: MacWorkspaceSplitViewController) -> [CGFloat] {
            controller.splitView.layoutSubtreeIfNeeded()
            return controller.splitView.arrangedSubviews.prefix(2).map(\.frame.width)
        }

        let fresh = layOut()
        fresh.applyDefaultWidthsIfUnsaved(defaults: defaults)
        XCTAssertEqual(widths(fresh)[0], 240, accuracy: 1)
        XCTAssertEqual(widths(fresh)[1], 320, accuracy: 1)
        fresh.splitView.setPosition(300, ofDividerAt: 0)
        let dragged = widths(fresh)
        fresh.applyDefaultWidthsIfUnsaved(defaults: defaults)
        XCTAssertEqual(widths(fresh), dragged, "Applied once, not on every appearance")

        let narrow = layOut(width: 900)
        let minimums = widths(narrow)
        narrow.applyDefaultWidthsIfUnsaved(defaults: defaults)
        XCTAssertEqual(widths(narrow), minimums, "The minimum window keeps the minimum columns")

        // The autosave name is set only for the check and cleared before anything could write it.
        let saved = layOut()
        saved.splitView.setPosition(210, ofDividerAt: 0)
        let before = widths(saved)
        saved.splitView.autosaveName = "Saved"
        saved.applyDefaultWidthsIfUnsaved(defaults: defaults)
        saved.splitView.autosaveName = nil
        XCTAssertEqual(widths(saved), before, "A database with a saved layout keeps it")
    }

    func testWindowKeepsControllerUntilSessionChangesThenReleasesIt() throws {
        let first = try makeSession()
        let workspace = MacWindowWorkspace(presentation: MacWorkspacePresentation(),
                                           attachmentPreview: .unshown(first), currentSession: { nil })
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

    func testTabRunsSidebarSearchListDetailThenTheToolbarButtonsAndRoundAgain() throws {
        let session = try makeSession()
        let workspace = MacWindowWorkspace(presentation: MacWorkspacePresentation(),
                                           attachmentPreview: .unshown(session), currentSession: { nil })
        workspace.show(session)
        let split = try XCTUnwrap(workspace.splitViewController)
        let toolbar = try XCTUnwrap(workspace.toolbar)
        let buttons = toolbar.keyViewButtons
        XCTAssertEqual(buttons.map { $0.accessibilityIdentifier() }, [
            "sidebar.left", "entry-list.add-entry", "database.read-only-indicator",
            "database-details.button", "database.cloud-sync-now", "lock.button",
        ])
        let outline: NSView = split.sidebar.outlineView
        let expected: [NSView] = [outline, toolbar.searchItem.searchField, split.entryList.tableView,
                                  split.splitViewItems[2].viewController.view] + buttons + [outline]
        var chain: [NSView] = []
        var view: NSView? = outline
        while let current = view, chain.count < expected.count {
            chain.append(current)
            view = current.nextKeyView
        }
        XCTAssertEqual(chain.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
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
        let sidebarColumn = split.splitView.arrangedSubviews[0]
        let sidebarColumnFrame = sidebarColumn.convert(sidebarColumn.bounds, to: contentView)
        XCTAssertEqual(sidebarColumnFrame.height, contentView.bounds.height, accuracy: 0.5, "The sidebar column runs full height")
        XCTAssertGreaterThanOrEqual(sidebarFrame.minY, sidebarColumnFrame.minY - 0.5)
        XCTAssertLessThanOrEqual(sidebarFrame.maxY, sidebarColumnFrame.maxY + 0.5)
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
