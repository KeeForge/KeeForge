#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import KeeForge

@MainActor
final class MacSidebarViewControllerTests: MacSidebarSessionTestCase {
    private static let sortDefaultsKeys = ["KeeForge.sortOrder", "KeeForge.sortAscending"]
    private var savedSortDefaults: [String: Any] = [:]

    /// Root ▸ Work ▸ Servers, Root ▸ Personal ▸ Family, and a Recycle Bin
    /// holding Old; two tags.
    private struct Tree {
        let ssh: KPEntry
        let servers: KPGroup
        let work: KPGroup
        let family: KPGroup
        let personal: KPGroup
        let old: KPGroup
        let recycleBin: KPGroup
        let root: KPGroup

        init(tagged: Bool = true) {
            let ssh = KPEntry(title: "SSH", tags: tagged ? ["Work"] : [])
            let servers = KPGroup(name: "Servers", entries: [ssh])
            let work = KPGroup(name: "Work", groups: [servers])
            let family = KPGroup(name: "Family", entries: [KPEntry(title: "Bank", tags: tagged ? ["Home"] : [])])
            let personal = KPGroup(name: "Personal", groups: [family])
            let old = KPGroup(name: "Old")
            let recycleBin = KPGroup(name: "Recycle Bin", groups: [old])
            self.ssh = ssh
            self.servers = servers
            self.work = work
            self.family = family
            self.personal = personal
            self.old = old
            self.recycleBin = recycleBin
            root = KPGroup(name: "Root", groups: [work, personal, recycleBin], recycleBinUUID: recycleBin.id)
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        savedSortDefaults = Self.sortDefaultsKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    override func tearDown() async throws {
        for key in Self.sortDefaultsKeys {
            UserDefaults.standard.set(savedSortDefaults[key], forKey: key)
        }
        try await super.tearDown()
    }

    // MARK: - Structure

    func testRowsFollowTheSnapshotWithHeadersOverLibraryGroupsTagsAndTheRecycleBin() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree)
        let outline = controller.outlineView

        XCTAssertEqual(visibleRowIDs(outline), expectedVisibleIDs(session, collapsed: []))
        let topLevel = (0..<outline.numberOfChildren(ofItem: nil)).compactMap {
            (outline.child($0, ofItem: nil) as? MacSidebarOutlineItem)?.id
        }
        XCTAssertEqual(topLevel, [.section(.library), .section(.groups), .section(.tags), .section(.recycleBin)])
        XCTAssertEqual(titles(outline, under: .section(.library)),
                       [DatabaseCollection.allEntries.title, DatabaseCollection.verificationCodes.title,
                        DatabaseCollection.passkeys.title])
        XCTAssertEqual(titles(outline, under: .section(.groups)), ["Root"])
        XCTAssertEqual(titles(outline, under: .section(.tags)), ["Home", "Work"])
        XCTAssertEqual(titles(outline, under: .section(.recycleBin)), [String(localized: "Deleted Entries"), "Old"])
        XCTAssertFalse(titles(outline, under: .group(tree.root.id)).contains("Recycle Bin"))

        let headers = try [MacSidebarItemID.section(.library), .section(.groups), .section(.tags), .section(.recycleBin)]
            .map { try XCTUnwrap(controller.item(for: $0)) }
        XCTAssertEqual(headers.map { cell(outline, $0)?.textField?.stringValue },
                       [String(localized: "Library"), String(localized: "Groups"), String(localized: "Tags"),
                        String(localized: "Recycle Bin")])
        XCTAssertEqual(outline.level(forItem: controller.item(for: .group(tree.root.id))), 1)
        XCTAssertEqual(outline.level(forItem: controller.item(for: .group(tree.recycleBin.id))), 1)
        XCTAssertEqual(outline.level(forItem: controller.item(for: .group(tree.old.id))), 1)
        XCTAssertEqual(outline.style, .sourceList)
        XCTAssertEqual(outline.numberOfColumns, 1)
        XCTAssertNil(outline.headerView)
    }

    func testHeadersAreGroupRowsThatCannotBeSelectedAndDrawTheirOwnChevron() async throws {
        let tree = Tree()
        let (controller, _, _) = try await makeController(tree)
        let outline = controller.outlineView
        let header = try XCTUnwrap(controller.item(for: .section(.groups)))
        let group = try XCTUnwrap(controller.item(for: .group(tree.work.id)))
        let tag = try XCTUnwrap(controller.item(for: .tag("Work")))

        XCTAssertTrue(controller.outlineView(outline, isGroupItem: header))
        XCTAssertFalse(controller.outlineView(outline, shouldSelectItem: header))
        XCTAssertFalse(controller.outlineView(outline, shouldShowOutlineCellForItem: header))
        XCTAssertTrue(outline.isItemExpanded(header))
        let headerCell = try XCTUnwrap(cell(outline, header) as? MacSidebarHeaderCellView)
        XCTAssertFalse(headerCell.isFolded)
        XCTAssertTrue(headerCell.showButton.isHidden)
        XCTAssertEqual(headerCell.disclosureButton.accessibilityLabel(), String(localized: "Hide"))
        for item in [group, tag] {
            XCTAssertFalse(controller.outlineView(outline, isGroupItem: item))
            XCTAssertTrue(controller.outlineView(outline, shouldSelectItem: item))
            XCTAssertTrue(controller.outlineView(outline, shouldShowOutlineCellForItem: item))
        }
    }

    // MARK: - Selection

    func testSelectingARowWritesTheWorkspace() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree)

        select(.tag("Work"), in: controller)
        XCTAssertEqual(session.workspace.selectedTag, "Work")
        select(.collection(.verificationCodes), in: controller)
        XCTAssertEqual(session.workspace.selectedCollection, .verificationCodes)
        XCTAssertNil(session.workspace.selectedTag)
        select(.collection(.passkeys), in: controller)
        XCTAssertEqual(session.workspace.selectedCollection, .passkeys)
        select(.group(tree.recycleBin.id), in: controller)
        XCTAssertEqual(session.workspace.selectedGroupID, tree.recycleBin.id)
        XCTAssertNil(session.workspace.selectedCollection)
    }

    func testAModelSelectionSelectsItsRowAndUnfoldsItsAncestors() async throws {
        let tree = Tree()
        let (controller, session, presentation) = try await makeController(tree)
        let outline = controller.outlineView
        let work = try XCTUnwrap(controller.item(for: .group(tree.work.id)))
        outline.collapseItem(work)
        XCTAssertEqual(presentation.collapsedGroupIDs, [tree.work.id])

        session.revealEntry(tree.ssh.id)
        await settle()

        XCTAssertTrue(outline.isItemExpanded(work))
        XCTAssertEqual(presentation.collapsedGroupIDs, [])
        XCTAssertEqual(selectedID(outline), .group(tree.servers.id))
        XCTAssertEqual(session.workspace.selectedEntryID, tree.ssh.id, "Selecting the row keeps the revealed entry")

        session.workspace.selectedTag = "Home"
        await settle()
        XCTAssertEqual(selectedID(outline), .tag("Home"))
        session.workspace.selectedCollection = .allEntries
        await settle()
        XCTAssertEqual(selectedID(outline), .collection(.allEntries))
    }

    func testATallOutlineOpensAtTheTopAndScrollsToALaterSelection() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree, height: 150)
        let outline = controller.outlineView
        XCTAssertGreaterThan(outline.visibleRect.height, 0)
        XCTAssertGreaterThan(outline.bounds.height, outline.visibleRect.height, "The outline needs to scroll")
        XCTAssertEqual(outline.visibleRect.minY, 0, "The Library section was scrolled away on open")

        session.workspace.selectedGroupID = tree.old.id
        await settle()
        let rowRect = outline.rect(ofRow: outline.row(forItem: controller.item(for: .group(tree.old.id))))
        XCTAssertGreaterThanOrEqual(rowRect.minY, outline.visibleRect.minY, "A later selection was not scrolled into view")
        XCTAssertLessThanOrEqual(rowRect.maxY, outline.visibleRect.maxY, "A later selection was not scrolled into view")
    }

    func testAnEmptyOrHeaderSelectionRestoresTheModelRow() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree)
        let outline = controller.outlineView
        session.workspace.selectedGroupID = tree.work.id
        await settle()
        XCTAssertEqual(selectedID(outline), .group(tree.work.id))

        outline.deselectAll(nil)
        XCTAssertEqual(selectedID(outline), .group(tree.work.id))
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: controller.item(for: .section(.tags)))),
                                 byExtendingSelection: false)
        XCTAssertEqual(selectedID(outline), .group(tree.work.id))
        XCTAssertEqual(session.workspace.selectedGroupID, tree.work.id)
    }

    // MARK: - Edits

    func testRenameCreateDeleteMoveAndResortKeepExpansionSelectionAndRowObjects() async throws {
        let tree = Tree()
        let (controller, session, presentation) = try await makeController(tree)
        let outline = controller.outlineView
        session.sortOrder = .title
        session.sortAscending = true
        await settle()
        outline.collapseItem(try XCTUnwrap(controller.item(for: .group(tree.personal.id))))
        session.workspace.selectedGroupID = tree.servers.id
        await settle()
        let servers = try XCTUnwrap(controller.item(for: .group(tree.servers.id)))
        let work = try XCTUnwrap(controller.item(for: .group(tree.work.id)))

        func assertKept(_ message: String, line: UInt = #line) {
            XCTAssertEqual(visibleRowIDs(outline), expectedVisibleIDs(session, collapsed: presentation.collapsedGroupIDs),
                           message, line: line)
            XCTAssertEqual(presentation.collapsedGroupIDs, [tree.personal.id], message, line: line)
            XCTAssertEqual(selectedID(outline), .group(tree.servers.id), message, line: line)
            XCTAssertEqual(session.workspace.selectedGroupID, tree.servers.id, message, line: line)
            XCTAssertTrue(controller.item(for: .group(tree.servers.id)) === servers, message, line: line)
        }

        try session.updateGroup(groupID: tree.servers.id, draft: GroupDraftPayload(name: "Hosts", iconID: 3))
        await settle()
        assertKept("rename")
        XCTAssertEqual(cell(outline, servers)?.textField?.stringValue, "Hosts")

        try session.createGroup(named: "Alpha", in: tree.work.id)
        await settle()
        assertKept("create")
        XCTAssertEqual(titles(outline, under: .group(tree.work.id)), ["Alpha", "Hosts"])
        let alphaID = try XCTUnwrap(session.group(withID: tree.work.id)?.groups.first { $0.name == "Alpha" }?.id)

        try session.deleteGroup(alphaID, sendToRecycleBin: true)
        await settle()
        assertKept("recycle")
        XCTAssertEqual(titles(outline, under: .group(tree.work.id)), ["Hosts"])
        XCTAssertEqual(titles(outline, under: .section(.recycleBin)), [String(localized: "Deleted Entries"), "Alpha", "Old"])

        try session.moveGroup(groupID: tree.servers.id, toGroupID: tree.root.id)
        await settle()
        assertKept("move")
        XCTAssertEqual(titles(outline, under: .group(tree.root.id)), ["Hosts", "Personal", "Work"])
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: work), "Work lost its only child")

        try session.updateGroup(groupID: tree.servers.id, draft: GroupDraftPayload(name: "Zulu", iconID: 3))
        await settle()
        assertKept("re-sort")
        XCTAssertEqual(titles(outline, under: .group(tree.root.id)), ["Personal", "Work", "Zulu"])
        XCTAssertTrue(controller.item(for: .group(tree.work.id)) === work)
    }

    // MARK: - Expansion

    func testFoldingWritesTheCollapsedSetWhichOutlivesAPresentationReset() async throws {
        let tree = Tree()
        let (controller, session, presentation) = try await makeController(tree)
        let outline = controller.outlineView
        let work = try XCTUnwrap(controller.item(for: .group(tree.work.id)))
        session.workspace.selectedGroupID = tree.servers.id
        await settle()

        outline.collapseItem(work)
        XCTAssertEqual(presentation.collapsedGroupIDs, [tree.work.id])
        XCTAssertEqual(session.workspace.selectedGroupID, tree.work.id, "A folded-away selection moves to the group")
        XCTAssertEqual(selectedID(outline), .group(tree.work.id))

        outline.expandItem(work)
        XCTAssertEqual(presentation.collapsedGroupIDs, [])
        outline.collapseItem(work)
        presentation.reset()
        await settle()
        XCTAssertEqual(presentation.collapsedGroupIDs, [tree.work.id])
        XCTAssertFalse(outline.isItemExpanded(work))

        let rebuilt = await host(session, presentation)
        XCTAssertFalse(rebuilt.outlineView.isItemExpanded(rebuilt.item(for: .group(tree.work.id))),
                       "A rebuilt sidebar in the same window reads the folded set")
        XCTAssertTrue(rebuilt.outlineView.isItemExpanded(rebuilt.item(for: .group(tree.personal.id))))
    }

    func testSectionsFoldPerWindowAndASelectionInsideStaysWithNoRowSelected() async throws {
        let tree = Tree()
        let (controller, session, presentation) = try await makeController(tree)
        let outline = controller.outlineView
        let tags = try XCTUnwrap(controller.item(for: .section(.tags)))
        select(.tag("Work"), in: controller)
        await settle()

        let headerCell = try XCTUnwrap(cell(outline, tags) as? MacSidebarHeaderCellView)
        headerCell.disclosureButton.performClick(nil)
        await settle()
        XCTAssertFalse(outline.isItemExpanded(tags))
        XCTAssertEqual(presentation.collapsedSidebarSections, [.tags])
        XCTAssertTrue(headerCell.isFolded)
        XCTAssertFalse(headerCell.showButton.isHidden, "A folded section says Show")
        XCTAssertEqual(headerCell.showButton.title, String(localized: "Show"))
        XCTAssertEqual(session.workspace.selectedTag, "Work", "Folding keeps the list")
        XCTAssertEqual(outline.selectedRow, -1, "The folded row is not replaced by another")
        XCTAssertEqual(visibleRowIDs(outline), expectedVisibleIDs(session, collapsed: [], sections: [.tags]))

        presentation.reset()
        await settle()
        XCTAssertEqual(presentation.collapsedSidebarSections, [.tags], "The fold lasts for the window")
        let rebuilt = await host(session, presentation)
        XCTAssertFalse(rebuilt.outlineView.isItemExpanded(rebuilt.item(for: .section(.tags))))

        headerCell.showButton.performClick(nil)
        await settle()
        XCTAssertTrue(outline.isItemExpanded(tags))
        XCTAssertEqual(presentation.collapsedSidebarSections, [])
        XCTAssertEqual(selectedID(outline), .tag("Work"), "Unfolding shows the selection again")

        controller.toggleSection(.groups)
        await settle()
        XCTAssertEqual(presentation.collapsedSidebarSections, [.groups])
        XCTAssertEqual(presentation.collapsedGroupIDs, [], "Folding a section keeps its groups' own folds")
        XCTAssertEqual(session.workspace.selectedTag, "Work")
        session.workspace.selectedGroupID = tree.family.id
        await settle()
        XCTAssertEqual(presentation.collapsedSidebarSections, [], "A new selection inside unfolds its section")
        XCTAssertEqual(selectedID(outline), .group(tree.family.id))
        XCTAssertTrue(outline.isItemExpanded(controller.item(for: .group(tree.work.id))), "Its groups reopen as they were")
    }

    func testTheBinSectionDimsDeletedGroupsAndLeavesWhenTheBinEmpties() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree)
        let outline = controller.outlineView
        let old = try XCTUnwrap(cell(outline, controller.item(for: .group(tree.old.id))) as? MacSidebarCellView)
        let work = try XCTUnwrap(cell(outline, controller.item(for: .group(tree.work.id))) as? MacSidebarCellView)
        let deletedEntries = try XCTUnwrap(cell(outline, controller.item(for: .group(tree.recycleBin.id)))
            as? MacSidebarCellView)
        XCTAssertEqual(old.textField?.textColor, .secondaryLabelColor)
        XCTAssertEqual(work.textField?.textColor, .labelColor)
        XCTAssertEqual(deletedEntries.textField?.stringValue, String(localized: "Deleted Entries"))
        XCTAssertEqual(deletedEntries.countField.stringValue, 0.formatted())

        try session.deleteGroup(tree.old.id, sendToRecycleBin: false)
        await settle()
        XCTAssertNil(controller.item(for: .section(.recycleBin)), "An empty bin has no section")
        XCTAssertNil(controller.item(for: .group(tree.recycleBin.id)))
        XCTAssertEqual(visibleRowIDs(outline), expectedVisibleIDs(session, collapsed: []))
    }

    // MARK: - Context menu

    func testGroupMenusFollowTheGroupActionsPolicy() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree)

        func identifiers(_ groupID: UUID) -> [String] {
            controller.contextMenuItems(forGroupID: groupID).compactMap(\.identifier?.rawValue)
        }
        XCTAssertEqual(identifiers(tree.work.id), [
            "group-row.new-subgroup", "group-row.edit-context", "group-row.move-context", "group-row.delete-context",
        ])
        XCTAssertEqual(controller.contextMenuItems(forGroupID: tree.work.id).map(\.title), [
            String(localized: "New Subgroup…"), String(localized: "Edit Group…"),
            String(localized: "Move to Group…"), "", String(localized: "Delete"),
        ])
        XCTAssertTrue(controller.contextMenuItems(forGroupID: tree.work.id)[3].isSeparatorItem, "Delete stands apart")
        XCTAssertEqual(identifiers(tree.root.id), ["group-row.new-subgroup"], "The wrapper's fields are not saved")
        XCTAssertEqual(identifiers(tree.recycleBin.id), [])
        XCTAssertEqual(identifiers(tree.old.id), ["group-row.restore-context", "group-row.delete-permanent"])
        XCTAssertEqual(controller.contextMenuItems(forGroupID: tree.old.id).map(\.title),
                       [String(localized: "Restore"), "", String(localized: "Delete Permanently")])
        XCTAssertTrue(controller.contextMenuItems(forGroupID: tree.old.id).allSatisfy { $0.image == nil })
        let items = controller.contextMenuItems(forGroupID: tree.work.id) + controller.contextMenuItems(forGroupID: tree.old.id)
        for item in items where item.isSeparatorItem == false {
            XCTAssertTrue(controller.validateMenuItem(item), item.title)
        }

        let menu = try XCTUnwrap(controller.outlineView.menu)
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items, [], "No clicked group row, no menu")
        XCTAssertNotNil(session.group(withID: tree.work.id))
    }

    func testMenuActionsSetTheWorkspacePresentation() async throws {
        let tree = Tree()
        let (controller, session, presentation) = try await makeController(tree)
        func perform(_ identifier: String, on groupID: UUID) throws {
            let item = try XCTUnwrap(controller.contextMenuItems(forGroupID: groupID).first {
                $0.identifier?.rawValue == identifier
            }, identifier)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item), identifier)
        }

        try perform("group-row.new-subgroup", on: tree.work.id)
        XCTAssertTrue(presentation.isShowingNewGroupSheet)
        XCTAssertEqual(presentation.newGroupParentID, tree.work.id)

        try perform("group-row.edit-context", on: tree.work.id)
        XCTAssertNotNil(presentation.groupEditor)

        try perform("group-row.move-context", on: tree.work.id)
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.group(tree.work.id).id)

        try perform("group-row.delete-context", on: tree.work.id)
        guard case .group(let deletion) = presentation.pendingDeletion else { return XCTFail("No group deletion") }
        XCTAssertEqual(deletion.groupID, tree.work.id)
        XCTAssertTrue(deletion.sendToRecycleBin)

        presentation.pendingMove = nil
        try perform("group-row.restore-context", on: tree.old.id)
        XCTAssertEqual(presentation.pendingMove?.id, PendingMove.restore(.group(tree.old.id)).id,
                       "No recorded parent: the destination picker")

        try session.deleteGroup(tree.family.id, sendToRecycleBin: true)
        XCTAssertEqual(session.originalRestoreDestination(for: .group(tree.family.id)), tree.personal.id)
        presentation.pendingMove = nil
        try perform("group-row.restore-context", on: tree.family.id)
        XCTAssertNil(presentation.pendingMove, "A recorded parent restores directly")
        XCTAssertFalse(session.isGroupInRecycleBin(groupID: tree.family.id))
        XCTAssertTrue(session.group(withID: tree.personal.id)?.groups.contains { $0.id == tree.family.id } == true)
    }

    // MARK: - Saving and status

    func testSavingDisablesTheOutlineAndItsMenuAndTheCardFollowsTheSave() async throws {
        let tree = Tree()
        let gate = SaveGate()
        let (controller, session, _) = try await makeController(tree, save: { _, _, _, hash, _, _, _ in
            await gate.signalStarted()
            await gate.waitUntilOpen()
            return .saved(newSHA512: hash)
        })
        let card = controller.statusCard
        XCTAssertFalse(card.isHidden, "Always shown for an open database")
        XCTAssertEqual(card.accessibilityIdentifier(), "sidebar.status-card")
        XCTAssertEqual(card.nameField.stringValue, session.databaseDisplayName)
        XCTAssertEqual(card.lineView.textField.stringValue,
                       "\(session.databaseFilename) · \(String(localized: "On This Mac"))")
        XCTAssertTrue(card.lineView.dotView.isHidden)
        XCTAssertTrue(card.actionButton.isHidden)
        XCTAssertTrue(card.syncButton.isHidden, "A database on this Mac has no Sync Now")

        try session.createGroup(named: "Draft", in: tree.work.id)
        await settle()
        XCTAssertEqual(card.lineView.textField.stringValue, String(localized: "Changes not saved"))
        XCTAssertFalse(card.lineView.dotView.isHidden)
        XCTAssertFalse(card.actionButton.isHidden)
        XCTAssertEqual(card.actionButton.title, String(localized: "Retry Save"))
        XCTAssertEqual(card.actionButton.accessibilityIdentifier(), "database.unsaved-indicator")
        let menuItems = controller.contextMenuItems(forGroupID: tree.work.id)

        let save = try XCTUnwrap(DatabaseCommands(session: session).save())
        await gate.waitUntilStarted()
        await settle()
        XCTAssertTrue(session.isSaving)
        XCTAssertFalse(controller.outlineView.isEnabled)
        XCTAssertTrue(menuItems.allSatisfy { controller.validateMenuItem($0) == false })
        XCTAssertEqual(card.lineView.textField.stringValue,
                       "\(session.databaseFilename) · \(String(localized: "Saving…"))")
        XCTAssertTrue(card.actionButton.isHidden)
        XCTAssertFalse(card.lockButton.isEnabled)
        XCTAssertFalse(card.settingsButton.isEnabled)

        await gate.open()
        await save.value
        await settle()
        XCTAssertTrue(controller.outlineView.isEnabled)
        XCTAssertEqual(card.lineView.textField.stringValue,
                       "\(session.databaseFilename) · \(String(localized: "On This Mac"))")
        XCTAssertTrue(card.lockButton.isEnabled)
    }

    func testCardButtonsKeepTheirIdentifiersAndActOnTheSession() async throws {
        let tree = Tree()
        let (controller, session, presentation) = try await makeController(tree)
        let card = controller.statusCard
        XCTAssertEqual(card.settingsButton.accessibilityIdentifier(), "database-details.button")
        XCTAssertEqual(card.syncButton.accessibilityIdentifier(), "database.cloud-sync-now")
        XCTAssertEqual(card.lockButton.accessibilityIdentifier(), "lock.button")
        XCTAssertEqual(card.settingsButton.accessibilityLabel(), String(localized: "Database Settings"))
        XCTAssertEqual(card.lockButton.accessibilityLabel(), String(localized: "Lock Database"))
        XCTAssertEqual(card.syncButton.accessibilityLabel(), String(localized: "Sync Now"))
        XCTAssertTrue(card.readOnlyBadge.isHidden)

        card.settingsButton.performClick(nil)
        XCTAssertTrue(presentation.isShowingDatabaseDetails)

        try session.createGroup(named: "Draft", in: tree.work.id)
        await settle()
        card.lockButton.performClick(nil)
        XCTAssertEqual(session.pendingLockRequest?.reason, .draft, "Lock goes through the guarded lock request")
    }

    func testTheCardFillIsVisibleInLightAndDark() {
        let card = MacSidebarStatusCardView()
        for (name, minimumAlpha) in [(NSAppearance.Name.aqua, 0.5), (.darkAqua, 0.05)] {
            let appearance = try? XCTUnwrap(NSAppearance(named: name))
            var alpha: CGFloat = 0
            appearance?.performAsCurrentDrawingAppearance {
                alpha = card.box.fillColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0
            }
            XCTAssertGreaterThanOrEqual(alpha, minimumAlpha, name.rawValue)
        }
        XCTAssertEqual(card.box.borderWidth, 0.5)
    }

    func testAReadOnlySessionShowsTheBadgeAndOffersNoGroupMenu() async throws {
        let tree = Tree()
        let (controller, _, _) = try await makeController(tree, readOnly: true)
        XCTAssertFalse(controller.statusCard.readOnlyBadge.isHidden)
        XCTAssertEqual(controller.statusCard.readOnlyBadge.accessibilityLabel(), String(localized: "Read-only database"))
        XCTAssertEqual(controller.contextMenuItems(forGroupID: tree.work.id), [])
    }

    // MARK: - Cells

    func testCellsCarryIdentifiersLabelsCountsAndTypeSelectStrings() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree)
        let outline = controller.outlineView
        XCTAssertEqual(outline.accessibilityIdentifier(), "sidebar.outline")

        var nodes: [MacSidebarItemID: MacSidebarSnapshot.Node] = [:]
        func index(_ list: [MacSidebarSnapshot.Node]) {
            for node in list {
                nodes[node.id] = node
                index(node.children)
            }
        }
        index(MacSidebarSnapshot.make(session: session).sections.flatMap(\.nodes))

        for row in 0..<outline.numberOfRows {
            let item = try XCTUnwrap(outline.item(atRow: row) as? MacSidebarOutlineItem)
            let typeSelect = controller.outlineView(outline, typeSelectStringFor: nil, item: item)
            guard let node = nodes[item.id], item.isCaption == false else {
                XCTAssertTrue(item.isHeader)
                XCTAssertNil(typeSelect)
                XCTAssertEqual(cell(outline, item)?.textField?.accessibilityIdentifier() ?? "", "")
                continue
            }
            let view = try XCTUnwrap(cell(outline, item) as? MacSidebarCellView)
            XCTAssertEqual(view.textField?.accessibilityIdentifier(), node.accessibilityIdentifier)
            XCTAssertEqual(view.accessibilityLabel(), node.title)
            XCTAssertEqual(view.textField?.stringValue, node.title)
            XCTAssertEqual(view.toolTip, node.title)
            XCTAssertEqual(view.countField.isHidden, node.count == nil)
            XCTAssertEqual(typeSelect, node.title)
            XCTAssertNotNil(view.imageView?.image)
        }
        let work = try XCTUnwrap(cell(outline, controller.item(for: .tag("Work"))) as? MacSidebarCellView)
        XCTAssertEqual(work.countField.stringValue, 1.formatted())
        let groupCounts = try [tree.root, tree.work, tree.servers, tree.personal].map { group in
            try XCTUnwrap(cell(outline, controller.item(for: .group(group.id))) as? MacSidebarCellView)
        }
        XCTAssertEqual(groupCounts.map(\.countField.stringValue), [2, 1, 1, 1].map { $0.formatted() },
                       "A group counts its whole subtree")
        XCTAssertEqual(groupCounts.map { $0.accessibilityValue() as? String }, [2, 1, 1, 1].map { $0.formatted() })
        let passkeys = try XCTUnwrap(cell(outline, controller.item(for: .collection(.passkeys))) as? MacSidebarCellView)
        XCTAssertEqual(passkeys.textField?.accessibilityIdentifier(), "sidebar.collection.passkeys")
        XCTAssertEqual(passkeys.countField.stringValue, 0.formatted())
        XCTAssertEqual(cell(outline, controller.item(for: .group(tree.work.id)))?.textField?.accessibilityIdentifier(),
                       "group.navlink")
        XCTAssertEqual(cell(outline, controller.item(for: .group(tree.recycleBin.id)))?.textField?.accessibilityIdentifier(),
                       "group.navlink")
    }

    func testIconsResolveStandardCustomAndSymbolImages() throws {
        let png = try Self.png(.green)

        let custom = try XCTUnwrap(MacSidebarCellView.image(for: .custom(png, standardIconID: 0), emphasized: false))
        XCTAssertEqual(custom.size, NSSize(width: MacSidebarCellView.iconSize, height: MacSidebarCellView.iconSize))
        XCTAssertFalse(custom.isTemplate)
        let fallback = MacSidebarCellView.image(for: .custom(Data([0, 1, 2]), standardIconID: 0), emphasized: false)
        XCTAssertNotNil(fallback)
        XCTAssertNotEqual(fallback?.size, custom.size)
        XCTAssertNotNil(MacSidebarCellView.image(for: .standard(43), emphasized: false))
        XCTAssertNotNil(MacSidebarCellView.image(for: .standard(-1), emphasized: true))
        XCTAssertEqual(MacSidebarCellView.image(for: .symbol("tag"), emphasized: false)?.isTemplate, true)
        let bin = try XCTUnwrap(MacSidebarCellView.image(for: .recycleBin, emphasized: false))
        XCTAssertEqual(bin.size, NSSize(width: MacSidebarCellView.iconSize, height: MacSidebarCellView.iconSize))
        XCTAssertFalse(bin.isTemplate, "The bin's tile keeps its orange")
        XCTAssertNotNil(bin.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let tag = try XCTUnwrap(MacSidebarCellView.image(for: .tag, emphasized: false))
        XCTAssertEqual(tag.size, NSSize(width: MacSidebarCellView.iconSize, height: MacSidebarCellView.iconSize))
        XCTAssertFalse(tag.isTemplate, "The \"#\" keeps the accent colour")
        XCTAssertNotNil(tag.cgImage(forProposedRect: nil, context: nil, hints: nil), "The \"#\" draws")
    }

    func testWithoutTagsTheTagsHeaderKeepsACaptionThatCannotBeSelected() async throws {
        let tree = Tree(tagged: false)
        let (controller, session, _) = try await makeController(tree)
        let outline = controller.outlineView

        XCTAssertEqual(visibleRowIDs(outline), expectedVisibleIDs(session, collapsed: []))
        let caption = try XCTUnwrap(controller.item(for: .caption(.tags)))
        XCTAssertTrue(caption.parent === controller.item(for: .section(.tags)))
        XCTAssertFalse(controller.outlineView(outline, shouldSelectItem: caption))
        XCTAssertFalse(controller.outlineView(outline, isGroupItem: caption))
        XCTAssertNil(controller.outlineView(outline, typeSelectStringFor: nil, item: caption))
        let view = try XCTUnwrap(cell(outline, caption) as? MacSidebarCaptionCellView)
        XCTAssertEqual(view.textField?.stringValue, String(localized: "No tags yet. Tags you add to entries appear here."))
        XCTAssertEqual(view.textField?.accessibilityIdentifier(), "sidebar.tags.empty")
        let groupRow = outline.row(forItem: controller.item(for: .group(tree.work.id)))
        let captionHeight = outline.rect(ofRow: outline.row(forItem: caption)).height
        let groupHeight = outline.rect(ofRow: groupRow).height
        XCTAssertGreaterThanOrEqual(groupHeight, 22, "Other rows keep the source list's height")
        XCTAssertGreaterThan(captionHeight, groupHeight, "The caption has room for two lines")

        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: caption)), byExtendingSelection: false)
        XCTAssertEqual(selectedID(outline), .group(try XCTUnwrap(session.visibleRootGroupID)))
    }

    func testTagRowsDrawTheHashGlyph() async throws {
        let (controller, _, _) = try await makeController(Tree())
        let view = try XCTUnwrap(cell(controller.outlineView, controller.item(for: .tag("Work"))) as? MacSidebarCellView)
        XCTAssertEqual(view.imageView?.image?.isTemplate, false)
        XCTAssertEqual(view.imageView?.image?.size,
                       NSSize(width: MacSidebarCellView.iconSize, height: MacSidebarCellView.iconSize))
    }

    func testAMergedReplacementImageUnderTheSameUUIDRedrawsTheCell() async throws {
        let tree = Tree()
        let (controller, session, _) = try await makeController(tree)
        let customID = UUID()
        let red = try Self.png(.red)
        let blue = try Self.png(.blue)
        func useIcon(_ data: Data) throws {
            let root = tree.root.deepCopy()
            root.groups.first { $0.id == tree.work.id }?.customIconUUID = customID
            session.draft = DatabaseDraft(
                rootGroup: root,
                meta: KPMeta(recycleBin: .group(tree.recycleBin.id), customIcons: [customID: data]),
                sessionKey: try XCTUnwrap(session.sessionKey)
            )
        }
        func cellImageData() throws -> Data? {
            let view = try XCTUnwrap(cell(controller.outlineView, controller.item(for: .group(tree.work.id))))
            return view.imageView?.image?.tiffRepresentation
        }

        try useIcon(red)
        await settle()
        let redImage = try cellImageData()
        try useIcon(blue)
        await settle()

        XCTAssertNotNil(redImage)
        XCTAssertNotEqual(try cellImageData(), redImage)
        XCTAssertEqual(try cellImageData(),
                       MacSidebarCellView.image(for: .custom(blue, standardIconID: 0), emphasized: false)?.tiffRepresentation)
    }

    private static func png(_ color: NSColor) throws -> Data {
        try XCTUnwrap(NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
    }

    // MARK: - Helpers

    private func makeController(
        _ tree: Tree,
        readOnly: Bool = false,
        height: CGFloat = 900,
        save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) }
    ) async throws -> (MacSidebarViewController, DatabaseViewModel, MacWorkspacePresentation) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        reference.isReadOnly = readOnly
        let session = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: save,
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false }
        )
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        session.draft = DatabaseDraft(
            rootGroup: tree.root,
            meta: KPMeta(recycleBin: .group(tree.recycleBin.id)),
            sessionKey: try XCTUnwrap(session.sessionKey)
        )
        session.workspace.selectedGroupID = session.visibleRootGroupID
        let presentation = MacWorkspacePresentation()
        return (await host(session, presentation, height: height), session, presentation)
    }

    private func host(
        _ session: DatabaseViewModel, _ presentation: MacWorkspacePresentation, height: CGFloat = 900
    ) async -> MacSidebarViewController {
        let controller = MacSidebarViewController(session: session, presentation: presentation)
        // Never ordered in: the outline only needs a window to lay out its rows.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // Setting the controller sizes the window to the view's empty frame.
        window.setContentSize(NSSize(width: 260, height: height))
        addTeardownBlock { @MainActor in window.close() }
        controller.view.layoutSubtreeIfNeeded()
        await settle()
        return controller
    }

    private func settle() async {
        for _ in 0..<4 { await Task { @MainActor in }.value }
    }

    private func select(_ id: MacSidebarItemID, in controller: MacSidebarViewController) {
        let row = controller.outlineView.row(forItem: controller.item(for: id))
        XCTAssertGreaterThanOrEqual(row, 0, "\(id)")
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func selectedID(_ outline: NSOutlineView) -> MacSidebarItemID? {
        (outline.item(atRow: outline.selectedRow) as? MacSidebarOutlineItem)?.id
    }

    private func visibleRowIDs(_ outline: NSOutlineView) -> [MacSidebarItemID] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? MacSidebarOutlineItem)?.id }
    }

    private func titles(_ outline: NSOutlineView, under id: MacSidebarItemID) -> [String] {
        let parent = (0..<outline.numberOfRows).lazy
            .compactMap { outline.item(atRow: $0) as? MacSidebarOutlineItem }
            .first { $0.id == id }
        guard let parent else { return [] }
        return (0..<outline.numberOfChildren(ofItem: parent)).compactMap {
            (outline.child($0, ofItem: parent) as? MacSidebarOutlineItem)?.content.title
        }
    }

    /// The rows a fresh outline of the current snapshot shows with `collapsed` folded.
    private func expectedVisibleIDs(
        _ session: DatabaseViewModel,
        collapsed: Set<UUID>,
        sections: Set<MacSidebarSnapshot.SectionKind> = []
    ) -> [MacSidebarItemID] {
        func walk(_ nodes: [MacSidebarSnapshot.Node]) -> [MacSidebarItemID] {
            nodes.flatMap { node -> [MacSidebarItemID] in
                if case .group(let groupID) = node.id, collapsed.contains(groupID) { return [node.id] }
                return [node.id] + walk(node.children)
            }
        }
        return MacSidebarSnapshot.make(session: session).sections.flatMap { section -> [MacSidebarItemID] in
            sections.contains(section.kind) ? [section.id] : [section.id] + walk(section.nodes)
        }
    }

    private func cell(_ outline: NSOutlineView, _ item: MacSidebarOutlineItem?) -> NSTableCellView? {
        let row = outline.row(forItem: item)
        guard row >= 0 else { return nil }
        return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
    }
}
#endif
