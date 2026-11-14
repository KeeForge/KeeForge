#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

/// An unlocked, writable session over a tree the test controls.
@MainActor
private func makeSidebarSession(root: KPGroup, customIcons: [UUID: Data] = [:]) async throws -> DatabaseViewModel {
    let created = try await DatabaseCreationService.create(
        request: DatabaseCreationRequest(
            displayName: "Sidebar",
            destination: .appOnlyAcknowledged,
            password: "sidebar password"
        )
    )
    let session = DatabaseViewModel(createdDatabase: created)
    session.draft = DatabaseDraft(
        rootGroup: root,
        meta: KPMeta(recycleBin: root.recycleBinUUID.map { .group($0) }, customIcons: customIcons),
        sessionKey: try XCTUnwrap(session.sessionKey)
    )
    return session
}

@MainActor
class MacSidebarSessionTestCase: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }
}

@MainActor
final class MacSidebarSnapshotTests: MacSidebarSessionTestCase {
    private static let sortDefaultsKeys = ["KeeForge.sortOrder", "KeeForge.sortAscending"]
    private var savedSortDefaults: [String: Any] = [:]

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

    func testSectionsCarryLibraryGroupsTagsAndTheRecycleBinWithCounts() async throws {
        let totp = TOTPConfig(secret: EncryptedValue(sealedData: Data([0]), hasValue: true))
        let recycled = KPGroup(name: "Old", entries: [KPEntry(title: "Gone", tags: ["Work"])])
        let recycleBin = KPGroup(name: "Recycle Bin", iconID: 0, groups: [recycled])
        let work = KPGroup(name: "Work", entries: [
            KPEntry(title: "Code", tags: ["Work"], totpConfig: totp),
            KPEntry(title: "Plain", tags: ["Home", "Work"]),
        ])
        let visibleRoot = KPGroup(name: "Passwords", groups: [work, recycleBin])
        let root = KPGroup(name: "Wrapper", groups: [visibleRoot], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)

        let snapshot = MacSidebarSnapshot.make(session: session)

        XCTAssertEqual(snapshot.sections.map(\.kind), [.library, .groups, .tags, .recycleBin])

        let library = try XCTUnwrap(snapshot.section(.library)).nodes
        XCTAssertEqual(library.map(\.id), [.collection(.allEntries), .collection(.verificationCodes), .collection(.passkeys)])
        XCTAssertEqual(library.map(\.title), [DatabaseCollection.allEntries.title, DatabaseCollection.verificationCodes.title,
                                              String(localized: "Passkeys")])
        XCTAssertEqual(library.map(\.count), [2, 1, 0])
        XCTAssertEqual(library.map(\.icon), [.symbol("key"), .symbol("timer"), .symbol("person.badge.key")])
        XCTAssertEqual(library.map(\.selection),
                       [.collection(.allEntries), .collection(.verificationCodes), .collection(.passkeys)])
        XCTAssertEqual(
            library.map(\.accessibilityIdentifier),
            ["sidebar.collection.allEntries", "sidebar.collection.verificationCodes", "sidebar.collection.passkeys"]
        )

        let groups = try XCTUnwrap(snapshot.section(.groups)).nodes
        XCTAssertEqual(groups.map(\.id), [.group(visibleRoot.id)], "A one-child wrapper is skipped")
        XCTAssertEqual(groups[0].children.map(\.id), [.group(work.id)], "The bin is not part of Groups")
        XCTAssertEqual(groups[0].accessibilityIdentifier, "group.navlink")
        XCTAssertEqual(groups[0].count, 2, "The bin's entries are not counted")
        XCTAssertEqual(groups[0].selection, .group(visibleRoot.id))

        let tags = try XCTUnwrap(snapshot.section(.tags)).nodes
        XCTAssertEqual(tags.map(\.title), ["Home", "Work"])
        XCTAssertEqual(tags.map(\.count), [1, 2], "Recycled entries are not counted")
        XCTAssertEqual(tags.map(\.selection), [.tag("Home"), .tag("Work")])
        XCTAssertEqual(tags.map(\.accessibilityIdentifier), ["tag-list.row.home", "tag-list.row.work"])
        XCTAssertEqual(tags.map(\.icon), [.tag, .tag])

        let bin = try XCTUnwrap(snapshot.section(.recycleBin)).nodes
        XCTAssertEqual(bin.map(\.id), [.group(recycleBin.id), .group(recycled.id)],
                       "Deleted Entries, then the deleted groups as its siblings")
        XCTAssertEqual(bin[0].icon, .recycleBin)
        XCTAssertEqual(bin[0].title, String(localized: "Deleted Entries"))
        XCTAssertEqual(bin[0].selection, .group(recycleBin.id))
        XCTAssertEqual(bin[0].accessibilityIdentifier, "group.navlink")
        XCTAssertEqual(bin[0].children, [])
        XCTAssertEqual(bin[0].count, 0, "Deleted Entries counts only the bin's own entries, which its list shows")
        XCTAssertFalse(bin[0].isDeleted)
        XCTAssertTrue(bin[0].isSelectable)
        XCTAssertEqual(bin[1].title, "Old")
        XCTAssertEqual(bin[1].count, 1)
        XCTAssertEqual(bin[1].accessibilityIdentifier, "group.navlink")
        XCTAssertTrue(bin[1].isDeleted, "A deleted group is drawn dimmed")
        XCTAssertFalse(groups[0].isDeleted)
    }

    func testAnEmptyBinLeavesNoSection() async throws {
        let recycleBin = KPGroup(name: "Recycle Bin")
        let root = KPGroup(name: "Root", groups: [KPGroup(name: "Work"), recycleBin], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)
        XCTAssertNil(MacSidebarSnapshot.make(session: session).section(.recycleBin), "An empty bin has no rows")
    }

    func testABinHoldingOnlyGroupsKeepsDeletedEntries() async throws {
        let flights = KPGroup(name: "Flights")
        let travel = KPGroup(name: "Travel 2024", groups: [flights])
        let groupOnlyBin = KPGroup(name: "Recycle Bin", groups: [travel])
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [KPGroup(name: "Work"), groupOnlyBin],
                                                               recycleBinUUID: groupOnlyBin.id))
        let nodes = try XCTUnwrap(MacSidebarSnapshot.make(session: session).section(.recycleBin)).nodes
        XCTAssertEqual(nodes.map(\.id), [.group(groupOnlyBin.id), .group(travel.id)])
        XCTAssertEqual(nodes[0].count, 0, "Deleted Entries stays while the bin holds only groups")
        XCTAssertEqual(nodes[1].children.map(\.id), [.group(flights.id)])
        XCTAssertTrue(nodes[1].children[0].isDeleted)
    }

    func testGroupsCountTheirWholeSubtreeAndPasskeysCountLiveEntriesWithAPasskey() async throws {
        let passkeyFields = [
            PasskeyCredential.credentialIDKey: "Y3JlZA",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.usernameKey: "alice",
            PasskeyCredential.userHandleKey: "aGFuZGxl",
        ]
        func passkeyEntry(_ title: String) -> KPEntry {
            KPEntry(title: title, customFields: passkeyFields,
                    passkeyPrivateKey: EncryptedValue(sealedData: Data([0]), hasValue: true))
        }
        let development = KPGroup(name: "Development", entries: [passkeyEntry("GitHub"), KPEntry(title: "npm")])
        let infrastructure = KPGroup(name: "Infrastructure", entries: [KPEntry(title: "AWS")])
        let work = KPGroup(name: "Work", entries: [KPEntry(title: "Mail")], groups: [development, infrastructure])
        let email = KPGroup(name: "Email", entries: [passkeyEntry("Proton")])
        let recycleBin = KPGroup(name: "Recycle Bin", entries: [passkeyEntry("Gone"), KPEntry(title: "Old")],
                                 groups: [KPGroup(name: "Old Projects", entries: [KPEntry(title: "A"), KPEntry(title: "B")])])
        let root = KPGroup(name: "Personal", groups: [email, work, recycleBin], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)

        let snapshot = MacSidebarSnapshot.make(session: session)
        let personal = try XCTUnwrap(snapshot.section(.groups)?.nodes.first)
        XCTAssertEqual(personal.count, 5, "The root counts every live entry, as All Entries does")
        let counts = Dictionary(uniqueKeysWithValues: personal.children.flatMap { [$0] + $0.children }.map { ($0.title, $0.count) })
        XCTAssertEqual(counts, ["Email": 1, "Work": 4, "Development": 2, "Infrastructure": 1])
        XCTAssertEqual(snapshot.section(.library)?.nodes.map(\.count), [5, 0, 2])
        let bin = try XCTUnwrap(snapshot.section(.recycleBin)?.nodes)
        XCTAssertEqual(bin.map(\.count), [2, 2])
        XCTAssertEqual(Set(session.entries(for: .collection(.passkeys)).map(\.title)), ["GitHub", "Proton"],
                       "The recycle bin's passkeys are left out")
    }

    func testAMultiChildWrapperIsTheGroupsRoot() async throws {
        let first = KPGroup(name: "First")
        let second = KPGroup(name: "Second")
        let root = KPGroup(name: "Root", groups: [first, second])
        let session = try await makeSidebarSession(root: root)

        let groups = try XCTUnwrap(MacSidebarSnapshot.make(session: session).section(.groups)).nodes

        XCTAssertEqual(groups.map(\.id), [.group(root.id)])
        XCTAssertEqual(groups[0].title, "Root")
        XCTAssertEqual(Set(groups[0].children.map(\.id)), [.group(first.id), .group(second.id)])
    }

    func testAWrapperWithEntriesIsTheGroupsRoot() async throws {
        let only = KPGroup(name: "Only")
        let root = KPGroup(name: "Root", entries: [KPEntry(title: "Loose")], groups: [only])
        let session = try await makeSidebarSession(root: root)

        let groups = try XCTUnwrap(MacSidebarSnapshot.make(session: session).section(.groups)).nodes

        XCTAssertEqual(groups.map(\.id), [.group(root.id)])
        XCTAssertEqual(groups[0].children.map(\.id), [.group(only.id)])
    }

    func testNoTagsKeepTheTagsSectionWithACaptionAndNoBinLeavesNoBinRow() async throws {
        let root = KPGroup(name: "Root", entries: [KPEntry(title: "Untagged")], groups: [KPGroup(name: "Child")])
        let session = try await makeSidebarSession(root: root)

        let snapshot = MacSidebarSnapshot.make(session: session)

        XCTAssertEqual(snapshot.sections.map(\.kind), [.library, .groups, .tags])
        XCTAssertEqual(snapshot.section(.library)?.nodes.map(\.count), [1, 0, 0])
        let caption = try XCTUnwrap(snapshot.section(.tags)?.nodes.first)
        XCTAssertEqual(snapshot.section(.tags)?.nodes.count, 1)
        XCTAssertEqual(caption.id, .caption(.tags))
        XCTAssertEqual(caption.title, String(localized: "No tags yet. Tags you add to entries appear here."))
        XCTAssertNil(caption.icon)
        XCTAssertNil(caption.count)
        XCTAssertNil(caption.selection)
        XCTAssertFalse(caption.isSelectable)
        XCTAssertEqual(caption.accessibilityIdentifier, "sidebar.tags.empty")
    }

    func testCollapsibleGroupsAreTheGroupRowsWithSubgroups() async throws {
        let servers = KPGroup(name: "Servers")
        let work = KPGroup(name: "Work", groups: [servers])
        let old = KPGroup(name: "Old", groups: [KPGroup(name: "Older")])
        let recycleBin = KPGroup(name: "Recycle Bin", groups: [old])
        let root = KPGroup(name: "Root", groups: [work, KPGroup(name: "Leaf"), recycleBin], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)

        XCTAssertEqual(MacSidebarSnapshot.make(session: session).collapsibleGroupIDs,
                       [root.id, work.id, old.id])
    }

    func testABinNestedDeeperIsLiftedOutOfGroups() async throws {
        let recycleBin = KPGroup(name: "Trash", entries: [KPEntry(title: "Gone")])
        let archive = KPGroup(name: "Archive", groups: [recycleBin])
        let root = KPGroup(name: "Root", groups: [archive, KPGroup(name: "Other")], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)

        let snapshot = MacSidebarSnapshot.make(session: session)

        let archiveNode = try XCTUnwrap(snapshot.section(.groups)?.nodes.first?.children.first { $0.id == .group(archive.id) })
        XCTAssertTrue(archiveNode.children.isEmpty)
        XCTAssertEqual(snapshot.section(.recycleBin)?.nodes.map(\.id), [.group(recycleBin.id)])
    }

    func testAWrapperHoldingOnlyTheBinKeepsTheWrapperAsGroupsRoot() async throws {
        let recycleBin = KPGroup(name: "Recycle Bin", entries: [KPEntry(title: "Gone")])
        let root = KPGroup(name: "Root", groups: [recycleBin], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)

        let snapshot = MacSidebarSnapshot.make(session: session)

        XCTAssertEqual(snapshot.section(.groups)?.nodes.map(\.id), [.group(root.id)])
        XCTAssertEqual(snapshot.section(.groups)?.nodes.first?.children, [])
        XCTAssertEqual(snapshot.section(.recycleBin)?.nodes.map(\.id), [.group(recycleBin.id)])
    }

    func testChildrenFollowTheSortOrder() async throws {
        let old = KPGroup(name: "Beta", creationTime: Date(timeIntervalSince1970: 1))
        let new = KPGroup(name: "Alpha", creationTime: Date(timeIntervalSince1970: 2))
        let root = KPGroup(name: "Root", groups: [old, new])
        let session = try await makeSidebarSession(root: root)

        session.sortOrder = .title
        session.sortAscending = true
        XCTAssertEqual(
            MacSidebarSnapshot.make(session: session).section(.groups)?.nodes.first?.children.map(\.title),
            ["Alpha", "Beta"]
        )

        session.sortOrder = .createdDate
        session.sortAscending = false
        XCTAssertEqual(
            MacSidebarSnapshot.make(session: session).section(.groups)?.nodes.first?.children.map(\.title),
            ["Alpha", "Beta"]
        )
        session.sortAscending = true
        XCTAssertEqual(
            MacSidebarSnapshot.make(session: session).section(.groups)?.nodes.first?.children.map(\.title),
            ["Beta", "Alpha"]
        )
    }

    func testIconsResolveCustomStandardAndTheBinsTrash() async throws {
        let customID = UUID()
        let custom = KPGroup(name: "Banking", iconID: 0, customIconUUID: customID)
        let missing = KPGroup(name: "Missing", iconID: 5, customIconUUID: UUID())
        let recycleBin = KPGroup(name: "Recycle Bin", iconID: 0, customIconUUID: customID,
                                 entries: [KPEntry(title: "Gone")])
        let root = KPGroup(name: "Root", groups: [custom, missing, recycleBin], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root, customIcons: [customID: Data([1, 2, 3])])

        let snapshot = MacSidebarSnapshot.make(session: session)
        let children = try XCTUnwrap(snapshot.section(.groups)?.nodes.first?.children)

        XCTAssertEqual(children.first { $0.title == "Banking" }?.icon, .custom(Data([1, 2, 3]), standardIconID: 0))
        XCTAssertEqual(children.first { $0.title == "Missing" }?.icon, .standard(5))
        XCTAssertEqual(snapshot.section(.recycleBin)?.nodes.first?.icon, .recycleBin, "The board's tile, not the bin's icon")
    }

    func testReplacingACustomIconsImageUnderItsUUIDChangesTheSnapshot() async throws {
        let customID = UUID()
        let banking = KPGroup(name: "Banking", iconID: 0, customIconUUID: customID)
        let root = KPGroup(name: "Root", groups: [banking, KPGroup(name: "Other")])
        let session = try await makeSidebarSession(root: root, customIcons: [customID: Data([1, 2, 3])])
        let before = MacSidebarSnapshot.make(session: session)

        session.draft = DatabaseDraft(
            rootGroup: root.deepCopy(),
            meta: KPMeta(customIcons: [customID: Data([4, 5, 6])]),
            sessionKey: try XCTUnwrap(session.sessionKey)
        )
        let after = MacSidebarSnapshot.make(session: session)

        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.section(.groups)?.nodes.first?.children.first { $0.title == "Banking" }?.icon,
                       .custom(Data([4, 5, 6]), standardIconID: 0))
    }

    func testItemIDsMapSectionsToNoSelection() {
        XCTAssertNil(MacSidebarItemID.section(.groups).selection)
        XCTAssertNil(MacSidebarItemID.caption(.tags).selection)
        let groupID = UUID()
        XCTAssertEqual(MacSidebarItemID.group(groupID).selection, .group(groupID))
        XCTAssertEqual(MacSidebarItemID.tag("Work").selection, .tag("Work"))
        XCTAssertEqual(MacSidebarItemID.collection(.allEntries).selection, .collection(.allEntries))
    }

    func testTheSnapshotIsEmptyWithoutATree() throws {
        let session = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(
            for: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        ))
        XCTAssertEqual(MacSidebarSnapshot.make(session: session), MacSidebarSnapshot(sections: []))
    }
}

@MainActor
final class MacSidebarGroupActionsTests: MacSidebarSessionTestCase {
    private struct Tree {
        let root = KPGroup(name: "Wrapper")
        let visibleRoot = KPGroup(name: "Passwords")
        let work = KPGroup(name: "Work")
        let recycleBin = KPGroup(name: "Recycle Bin")
        let recycled = KPGroup(name: "Recycled")

        init() {
            recycleBin.groups = [recycled]
            visibleRoot.groups = [work, recycleBin]
            root.groups = [visibleRoot]
            root.recycleBinUUID = recycleBin.id
        }
    }

    func testAnOrdinaryGroupOffersEverythingButRestore() async throws {
        let tree = Tree()
        let session = try await makeSidebarSession(root: tree.root)

        let actions = MacSidebarGroupActions(groupID: tree.work.id, session: session)

        XCTAssertTrue(actions.canAddSubgroup)
        XCTAssertTrue(actions.canEdit)
        XCTAssertFalse(actions.canRestore)
        XCTAssertTrue(actions.canMove)
        XCTAssertTrue(actions.canDelete)
        XCTAssertFalse(actions.deletesPermanently)
        XCTAssertEqual(actions.deleteTitle, String(localized: "Delete"))
        XCTAssertEqual(actions.deleteAccessibilityIdentifier, "group-row.delete-context")
    }

    func testProtectedRootsCanBeExtendedButNeitherMovedNorDeleted() async throws {
        let tree = Tree()
        let session = try await makeSidebarSession(root: tree.root)

        for groupID in [tree.visibleRoot.id, tree.root.id] {
            let actions = MacSidebarGroupActions(groupID: groupID, session: session)
            XCTAssertTrue(actions.canAddSubgroup)
            XCTAssertFalse(actions.canMove)
            XCTAssertFalse(actions.canDelete)
        }
        XCTAssertTrue(MacSidebarGroupActions(groupID: tree.visibleRoot.id, session: session).canEdit)
    }

    func testTheSyntheticRootCannotBeEditedBecauseItsFieldsAreNotSaved() async throws {
        let recycleBin = KPGroup(name: "Recycle Bin")
        let binOnly = KPGroup(name: "Root", groups: [recycleBin], recycleBinUUID: recycleBin.id)
        let multiChild = KPGroup(name: "Root", groups: [KPGroup(name: "Work"), KPGroup(name: "Home")])
        let withEntries = KPGroup(name: "Root", entries: [KPEntry(title: "Loose")], groups: [KPGroup(name: "Work")])

        let session = try await makeSidebarSession(root: binOnly)
        for root in [binOnly, multiChild, withEntries] {
            session.draft = DatabaseDraft(
                rootGroup: root,
                meta: KPMeta(recycleBin: root.recycleBinUUID.map { .group($0) }),
                sessionKey: try XCTUnwrap(session.sessionKey)
            )
            XCTAssertEqual(session.workspaceRootGroupID, root.id, "The wrapper is the Groups root")
            XCTAssertTrue(session.isSyntheticRootGroup(groupID: root.id))
            let actions = MacSidebarGroupActions(groupID: root.id, session: session)
            XCTAssertFalse(actions.canEdit)
            XCTAssertTrue(actions.canAddSubgroup, "Its children are saved")
            XCTAssertFalse(actions.canMove)
            XCTAssertFalse(actions.canDelete)
        }
    }

    func testTheBinItselfOffersNothing() async throws {
        let tree = Tree()
        let session = try await makeSidebarSession(root: tree.root)

        let actions = MacSidebarGroupActions(groupID: tree.recycleBin.id, session: session)

        XCTAssertFalse(actions.offersAnyAction)
    }

    func testAGroupInsideTheBinRestoresOrDeletesPermanently() async throws {
        let tree = Tree()
        let session = try await makeSidebarSession(root: tree.root)

        let actions = MacSidebarGroupActions(groupID: tree.recycled.id, session: session)

        XCTAssertFalse(actions.canAddSubgroup)
        XCTAssertFalse(actions.canEdit)
        XCTAssertTrue(actions.canRestore)
        XCTAssertFalse(actions.canMove)
        XCTAssertTrue(actions.canDelete)
        XCTAssertTrue(actions.deletesPermanently)
        XCTAssertEqual(actions.deleteTitle, String(localized: "Delete Permanently"))
        XCTAssertEqual(actions.deleteAccessibilityIdentifier, "group-row.delete-permanent")
    }

    func testAnAncestorOfTheBinCannotBeDeleted() async throws {
        let recycleBin = KPGroup(name: "Recycle Bin")
        let archive = KPGroup(name: "Archive", groups: [recycleBin])
        let root = KPGroup(name: "Root", groups: [archive, KPGroup(name: "Other")], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)

        let actions = MacSidebarGroupActions(groupID: archive.id, session: session)

        XCTAssertTrue(actions.canEdit)
        XCTAssertFalse(actions.canMove)
        XCTAssertFalse(actions.canDelete)
    }

    func testAReadOnlySessionOffersNothing() async throws {
        let tree = Tree()
        let session = try await makeSidebarSession(root: tree.root)
        session.setReadOnly(true)
        XCTAssertTrue(session.isReadOnly)

        for groupID in [tree.work.id, tree.recycled.id, tree.visibleRoot.id] {
            XCTAssertFalse(MacSidebarGroupActions(groupID: groupID, session: session).offersAnyAction)
        }
    }

    func testAMissingGroupOffersNothing() async throws {
        let session = try await makeSidebarSession(root: Tree().root)

        XCTAssertFalse(MacSidebarGroupActions(groupID: UUID(), session: session).offersAnyAction)
    }

    func testIdentifiersMatchTheUITestSurface() {
        XCTAssertEqual(MacSidebarGroupActions.newSubgroupIdentifier, "group-row.new-subgroup")
        XCTAssertEqual(MacSidebarGroupActions.editIdentifier, "group-row.edit-context")
        XCTAssertEqual(MacSidebarGroupActions.restoreIdentifier, "group-row.restore-context")
        XCTAssertEqual(MacSidebarGroupActions.moveIdentifier, "group-row.move-context")
    }
}

@MainActor
final class MacEntryDropTests: MacSidebarSessionTestCase {
    /// Root ▸ Work (Alpha, Beta), Root ▸ Home (Gamma), and a Recycle Bin holding Gone and the group Old.
    private struct Tree {
        let alpha = KPEntry(title: "Alpha", username: "alpha-user")
        let beta = KPEntry(title: "Beta", username: "beta-user")
        let gamma = KPEntry(title: "Gamma")
        let gone = KPEntry(title: "Gone")
        let work: KPGroup
        let home: KPGroup
        let old = KPGroup(name: "Old")
        let recycleBin: KPGroup
        let root: KPGroup

        init() {
            work = KPGroup(name: "Work", entries: [alpha, beta])
            home = KPGroup(name: "Home", entries: [gamma])
            recycleBin = KPGroup(name: "Recycle Bin", entries: [gone], groups: [old])
            root = KPGroup(name: "Root", groups: [work, home, recycleBin], recycleBinUUID: recycleBin.id)
        }
    }

    private func make() async throws -> (Tree, DatabaseViewModel, MacWorkspacePresentation) {
        let tree = Tree()
        let session = try await makeSidebarSession(root: tree.root)
        XCTAssertEqual(session.state, .unlocked)
        return (tree, session, MacWorkspacePresentation())
    }

    func testThePasteboardCarriesOnlyTheEntryWindowAndDatabaseIDs() async throws {
        let (tree, session, presentation) = try await make()
        let drop = MacEntryDrop(session: session, presentation: presentation)

        let data = try XCTUnwrap(drop.pasteboardData(forEntryID: tree.alpha.id))

        func bytes(_ id: UUID) -> Data { withUnsafeBytes(of: id.uuid) { Data($0) } }
        XCTAssertEqual(data, bytes(session.databaseReference.id) + bytes(presentation.lifetimeID) + bytes(tree.alpha.id),
                       "Three UUIDs and nothing else")
        XCTAssertEqual(MacEntryDrop.pasteboardType, "com.keeforge.mac.entry-drag")
        XCTAssertNil(drop.pasteboardData(forEntryID: tree.gone.id), "A recycled entry restores, it does not drag")
        XCTAssertNil(drop.pasteboardData(forEntryID: UUID()))

        session.setReadOnly(true)
        XCTAssertNil(drop.pasteboardData(forEntryID: tree.alpha.id))
    }

    func testDraggedItemsReadBackOnlyInTheirOwnWindowAndDatabase() async throws {
        let (tree, session, presentation) = try await make()
        let drop = MacEntryDrop(session: session, presentation: presentation)
        let items = try [tree.alpha.id, tree.gamma.id].map { try XCTUnwrap(drop.pasteboardData(forEntryID: $0)) }

        XCTAssertEqual(drop.entryIDs(from: items), [tree.alpha.id, tree.gamma.id])
        XCTAssertNil(drop.entryIDs(from: []))
        XCTAssertNil(drop.entryIDs(from: items + [Data("Alpha".utf8)]), "One unreadable item refuses the drag")
        XCTAssertNil(drop.entryIDs(from: [items[0] + Data([0])]))

        let otherWindow = MacEntryDrop(session: session, presentation: MacWorkspacePresentation())
        XCTAssertNil(otherWindow.entryIDs(from: items))
        let otherSession = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(
            for: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        ))
        XCTAssertNotEqual(otherSession.databaseReference.id, session.databaseReference.id)
        XCTAssertNil(MacEntryDrop(session: otherSession, presentation: presentation).entryIDs(from: items))
        let foreign = try XCTUnwrap(otherWindow.pasteboardData(forEntryID: tree.beta.id))
        XCTAssertNil(drop.entryIDs(from: items + [foreign]), "A drag mixing windows is refused whole")

        presentation.reset()
        XCTAssertNil(MacEntryDrop(session: session, presentation: presentation).entryIDs(from: items),
                     "A lock renews the window's identity")
    }

    func testADropMovesOneOrSeveralEntriesThroughTheMovePath() async throws {
        let (tree, session, presentation) = try await make()
        let drop = MacEntryDrop(session: session, presentation: presentation)

        XCTAssertTrue(drop.canDrop([tree.alpha.id], onto: .group(tree.home.id)))
        XCTAssertTrue(drop.drop([tree.alpha.id], onto: .group(tree.home.id)))
        XCTAssertEqual(session.parentGroupID(forEntryID: tree.alpha.id), tree.home.id)

        session.workspace.setEntrySelection([tree.alpha.id, tree.beta.id])
        XCTAssertTrue(drop.canDrop([tree.alpha.id, tree.beta.id], onto: .group(tree.home.id)),
                      "One of them still has to move")
        XCTAssertTrue(drop.drop([tree.alpha.id, tree.beta.id], onto: .group(tree.home.id)))
        XCTAssertEqual(session.parentGroupID(forEntryID: tree.beta.id), tree.home.id)
        XCTAssertNil(session.workspace.entrySelection, "Moving the picks ends the selection, as Move to Group… does")

        XCTAssertFalse(drop.canDrop([tree.alpha.id, tree.beta.id], onto: .group(tree.home.id)))
        XCTAssertTrue(drop.canDrop([tree.alpha.id, tree.beta.id], onto: .group(tree.root.id)))
    }

    func testDropsAreRefusedWhereMoveToGroupRefuses() async throws {
        let (tree, session, presentation) = try await make()
        let drop = MacEntryDrop(session: session, presentation: presentation)
        let alpha: Set<UUID> = [tree.alpha.id]

        XCTAssertFalse(drop.canDrop(alpha, onto: .group(tree.work.id)), "Already in that group")
        XCTAssertFalse(drop.canDrop(alpha, onto: .group(tree.recycleBin.id)), "No board draws a drop on Deleted Entries")
        XCTAssertFalse(drop.canDrop(alpha, onto: .group(tree.old.id)), "A deleted group is no destination")
        XCTAssertFalse(drop.canDrop(alpha, onto: .group(UUID())))
        for target: MacSidebarItemID in [.collection(.allEntries), .collection(.passkeys), .tag("Work"),
                                         .section(.groups), .caption(.tags)] {
            XCTAssertFalse(drop.canDrop(alpha, onto: target), "\(target)")
        }
        XCTAssertFalse(drop.canDrop([tree.gone.id], onto: .group(tree.home.id)), "Recycled entries come back by Restore")
        XCTAssertFalse(drop.canDrop([tree.alpha.id, tree.gone.id], onto: .group(tree.home.id)))
        XCTAssertFalse(drop.canDrop([], onto: .group(tree.home.id)))
        XCTAssertFalse(drop.canDrop([UUID()], onto: .group(tree.home.id)))

        XCTAssertFalse(drop.drop(alpha, onto: .group(tree.recycleBin.id)))
        XCTAssertEqual(session.parentGroupID(forEntryID: tree.alpha.id), tree.work.id)

        session.setReadOnly(true)
        XCTAssertFalse(drop.canDrop(alpha, onto: .group(tree.home.id)))
        XCTAssertFalse(drop.drop([tree.alpha.id, tree.beta.id], onto: .group(tree.home.id)))
        XCTAssertEqual(session.parentGroupID(forEntryID: tree.beta.id), tree.work.id)
    }
}

@MainActor
final class MacDatabaseStatusTests: MacSidebarSessionTestCase {
    private func make(_ session: DatabaseViewModel) -> MacDatabaseStatus {
        MacDatabaseStatus.make(session: session, presentation: MacWorkspacePresentation())
    }

    private func cloudState(_ configure: (inout MacDatabaseStatus.State) -> Void = { _ in }) -> MacDatabaseStatus.State {
        var state = MacDatabaseStatus.State()
        state.name = "Personal"
        state.storage = .cloud(provider: "WebDAV")
        state.canSyncNow = true
        state.canLock = true
        state.canShowSettings = true
        configure(&state)
        return state
    }

    func testACleanLocalSessionShowsItsFileOnThisMacWithoutSyncNow() async throws {
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [KPGroup(name: "Child")]))

        let status = make(session)

        XCTAssertEqual(status.name, session.databaseDisplayName)
        XCTAssertEqual(status.line, .init(storage: session.databaseFilename, state: String(localized: "On This Mac")))
        XCTAssertEqual(status.line.text, "\(session.databaseFilename) · \(String(localized: "On This Mac"))")
        XCTAssertNil(status.line.dot)
        XCTAssertNil(status.action)
        XCTAssertFalse(status.offersSyncNow)
        XCTAssertFalse(status.isReadOnly)
        XCTAssertTrue(status.canLock)
        XCTAssertTrue(status.canShowSettings)
        XCTAssertEqual(status.notices, [])
    }

    func testADirtyDraftOffersRetrySave() async throws {
        let child = KPGroup(name: "Child")
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [child]))
        try session.applyEntryEdit(.createEntry(parentGroupID: child.id, draft: EntryDraftPayload(title: "New")))
        XCTAssertTrue(session.isDirty)

        let status = make(session)

        XCTAssertEqual(status.line, .init(state: String(localized: "Changes not saved"), dot: .warning))
        XCTAssertEqual(status.line.text, String(localized: "Changes not saved"), "The board drops the storage here")
        XCTAssertEqual(status.action, .retrySave)
        XCTAssertEqual(status.action?.title, String(localized: "Retry Save"))
        XCTAssertEqual(status.action?.accessibilityIdentifier, "database.unsaved-indicator")
        XCTAssertTrue(status.isActionEnabled)
    }

    func testAReadOnlySessionCarriesTheBadge() async throws {
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [KPGroup(name: "Child")]))
        session.setReadOnly(true)

        let status = make(session)

        XCTAssertTrue(status.isReadOnly)
        XCTAssertEqual(status.line.state, String(localized: "On This Mac"))
    }

    func testSavingSpeaksForEverythingAndDimsTheButtons() {
        let status = MacDatabaseStatus(cloudState {
            $0.isSaving = true
            $0.isDirty = true
            $0.hasSaveConflict = true
            $0.hasPendingUploadConflict = true
        })

        XCTAssertEqual(status.line, .init(storage: "WebDAV", state: String(localized: "Saving…"), dot: .neutral))
        XCTAssertNil(status.action)
        XCTAssertFalse(status.canSyncNow)
        XCTAssertFalse(status.canLock)
        XCTAssertFalse(status.canShowSettings)
        XCTAssertEqual(status.notices.map(\.kind), [], "The upload notice waits for the save")
    }

    func testASaveConflictOffersResolve() {
        let status = MacDatabaseStatus(cloudState {
            $0.hasSaveConflict = true
            $0.isDirty = true
        })

        XCTAssertEqual(status.line.text, "WebDAV · \(String(localized: "Save conflict"))")
        XCTAssertEqual(status.line.dot, .warning)
        XCTAssertEqual(status.action, .resolveConflict)
        XCTAssertEqual(status.action?.title, String(localized: "Resolve…"))
        XCTAssertEqual(status.action?.accessibilityIdentifier, "save-conflict.resolve")
    }

    func testARejectedSignInOffersReconnectInTheCardAndAboveTheList() {
        var status = MacDatabaseStatus(cloudState {
            $0.needsReconnect = true
            $0.isDirty = true
        })

        XCTAssertEqual(status.line.text, "WebDAV · \(String(localized: "Reconnect needed"))")
        XCTAssertEqual(status.action, .reconnect(provider: "WebDAV"))
        XCTAssertEqual(status.action?.title, String(localized: "Reconnect \("WebDAV")"))
        let notice = status.notices.first
        XCTAssertEqual(notice?.kind, .reconnect)
        XCTAssertEqual(notice?.text, String(localized: "Reconnect \("WebDAV") to save changes."))
        XCTAssertEqual(notice?.action, .reconnect(provider: "WebDAV"))
        XCTAssertEqual(notice?.accessibilityIdentifier, "cloud-reauth-banner")
        XCTAssertEqual(notice?.actionAccessibilityIdentifier, "cloud-reauth-banner.reconnect")
        XCTAssertTrue(status.isActionEnabled)

        status = MacDatabaseStatus(cloudState {
            $0.needsReconnect = true
            $0.isReconnectInFlight = true
        })
        XCTAssertFalse(status.isActionEnabled)
        XCTAssertEqual(status.notices.first?.isActionEnabled, false)
    }

    func testAnUploadConflictCountsInTheCardAndOffersMergeAboveTheList() {
        let status = MacDatabaseStatus(cloudState {
            $0.hasPendingUploadConflict = true
            $0.pendingUploads = .init(waiting: 0, conflicts: 1)
        })

        XCTAssertEqual(status.line.text, "WebDAV · \(String(localized: "\(1) pending upload conflicts"))")
        XCTAssertEqual(status.line.dot, .warning)
        XCTAssertNil(status.action)
        XCTAssertEqual(status.notices.map(\.kind), [.uploadConflict])
        XCTAssertEqual(status.notices.first?.text, String(
            localized: "A change saved through AutoFill couldn’t be uploaded because the cloud copy changed. Merge it into this database to upload it."
        ))
        XCTAssertEqual(status.notices.first?.action, .mergePendingUploads)
        XCTAssertEqual(status.notices.first?.action?.title, String(localized: "Merge Changes"))
        XCTAssertEqual(status.notices.first?.actionAccessibilityIdentifier, "pending-upload-banner.merge")
    }

    func testWaitingUploadsOfferPush() {
        let status = MacDatabaseStatus(cloudState { $0.pendingUploads = .init(waiting: 2, conflicts: 0) })

        XCTAssertEqual(status.line.text, "WebDAV · \(String(localized: "\(2) changes waiting to upload"))")
        XCTAssertEqual(status.line.dot, .warning)
        XCTAssertEqual(status.action, .pushPendingUploads)
        XCTAssertEqual(status.action?.title, String(localized: "Push Pending Changes"))
    }

    func testSyncedStatesFollowTheLastSync() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var status = MacDatabaseStatus(cloudState { $0.lastSyncedAt = now.addingTimeInterval(-20) }, now: now)
        XCTAssertEqual(status.line, .init(storage: "WebDAV", state: String(localized: "Synced just now"), dot: .synced))
        XCTAssertEqual(status.line.shortText, String(localized: "Synced just now"))
        XCTAssertTrue(status.offersSyncNow)
        XCTAssertTrue(status.canSyncNow)

        let twoHoursAgo = now.addingTimeInterval(-7200)
        status = MacDatabaseStatus(cloudState { $0.lastSyncedAt = twoHoursAgo }, now: now)
        XCTAssertEqual(status.line.state, MacDatabaseStatus.syncedText(at: twoHoursAgo, now: now))
        XCTAssertNotEqual(status.line.state, String(localized: "Synced just now"))

        status = MacDatabaseStatus(cloudState {
            $0.lastSyncedAt = twoHoursAgo
            $0.isRefreshPending = true
        }, now: now)
        XCTAssertEqual(status.line.dot, .neutral, "Opened without checking: not shown as synced")
        XCTAssertEqual(status.notices.map(\.text), [String(localized: "Opened without checking \("WebDAV") for changes.")])

        status = MacDatabaseStatus(cloudState(), now: now)
        XCTAssertEqual(status.line, .init(storage: "WebDAV", dot: .neutral), "Never synced: no claim")

        status = MacDatabaseStatus(cloudState { $0.isSyncing = true }, now: now)
        XCTAssertEqual(status.line, .init(storage: "WebDAV", state: String(localized: "Syncing…"), dot: .neutral))
    }

    func testCachedCopiesAndFailedSyncs() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoHoursAgo = now.addingTimeInterval(-7200)
        var status = MacDatabaseStatus(cloudState {
            $0.cachedCopy = .offline
            $0.lastSyncedAt = twoHoursAgo
        }, now: now)
        XCTAssertEqual(status.line.text, [
            "WebDAV", String(localized: "Offline"), MacDatabaseStatus.syncedText(at: twoHoursAgo, now: now),
        ].joined(separator: " · "))
        XCTAssertEqual(status.line.dot, .neutral, "Grey, not amber")
        XCTAssertEqual(status.notices.map(\.text), [CloudSyncResolution.offlineCachedBannerMessage])
        XCTAssertEqual(status.notices.first?.isWarning, false)
        XCTAssertNil(status.notices.first?.action)

        status = MacDatabaseStatus(cloudState { $0.cachedCopy = .disconnected })
        XCTAssertEqual(status.line.text, "WebDAV · \(String(localized: "Reconnect needed"))")
        XCTAssertNil(status.action)
        XCTAssertEqual(status.notices.map(\.text), [CloudSyncResolution.disconnectedCachedBannerMessage])

        status = MacDatabaseStatus(cloudState { $0.cachedCopy = .failed("Server said no") })
        XCTAssertEqual(status.line.text, "WebDAV · \(String(localized: "Sync failed"))")
        XCTAssertEqual(status.notices.map(\.text), ["Server said no"])

        status = MacDatabaseStatus(cloudState { $0.syncResult = .failed })
        XCTAssertEqual(status.line.text, "WebDAV · \(String(localized: "Sync failed"))")
        XCTAssertEqual(status.notices, [], "A failed Sync Now is an alert")

        status = MacDatabaseStatus(cloudState { $0.syncResult = .waits("Newer copy waits") })
        XCTAssertEqual(status.notices.map(\.kind), [.syncResult])
        XCTAssertEqual(status.notices.first?.action, .dismissSyncResult)
        XCTAssertEqual(status.notices.first?.action?.title, String(localized: "Dismiss"))
    }

    func testProblemsKeepTheBoardsPrecedence() {
        let state = cloudState {
            $0.hasSaveConflict = true
            $0.needsReconnect = true
            $0.isDirty = true
            $0.hasPendingUploadConflict = true
            $0.pendingUploads = .init(waiting: 3, conflicts: 1)
            $0.cachedCopy = .offline
        }
        XCTAssertEqual(MacDatabaseStatus(state).action, .resolveConflict)
        XCTAssertEqual(MacDatabaseStatus(state).notices.map(\.kind), [.reconnect, .uploadConflict, .cloud])
        var next = state
        next.hasSaveConflict = false
        XCTAssertEqual(MacDatabaseStatus(next).action, .reconnect(provider: "WebDAV"))
        next.needsReconnect = false
        XCTAssertEqual(MacDatabaseStatus(next).action, .retrySave)
        next.isDirty = false
        XCTAssertNil(MacDatabaseStatus(next).action, "Upload conflicts are merged from the notice")
        next.hasPendingUploadConflict = false
        XCTAssertEqual(MacDatabaseStatus(next).action, .pushPendingUploads)
    }

    func testALocalStateHasNoNoticesOrSync() {
        var state = MacDatabaseStatus.State()
        state.storage = .local(filename: "Personal.kdbx")
        state.hasSaveConflict = true
        let status = MacDatabaseStatus(state)
        XCTAssertEqual(status.line.text, "Personal.kdbx · \(String(localized: "Save conflict"))")
        XCTAssertFalse(status.offersSyncNow)
        XCTAssertEqual(status.notices, [])
    }
}
#endif
