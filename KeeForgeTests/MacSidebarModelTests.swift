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
        XCTAssertEqual(snapshot.sections.map(\.kind.showsHeader), [true, true, true, false])

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
        XCTAssertEqual(bin.map(\.id), [.group(recycleBin.id)])
        XCTAssertEqual(bin[0].icon, .standard(43))
        XCTAssertEqual(bin[0].title, "Recycle Bin")
        XCTAssertEqual(bin[0].selection, .group(recycleBin.id))
        XCTAssertEqual(bin[0].accessibilityIdentifier, "group.navlink")
        XCTAssertEqual(bin[0].children.map(\.id), [.group(recycled.id)])
        XCTAssertEqual(bin[0].count, 0, "The bin counts only its own entries, which its list shows")
        XCTAssertEqual(bin[0].children.map(\.count), [1])
        XCTAssertTrue(bin[0].isSelectable)
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
        let bin = try XCTUnwrap(snapshot.section(.recycleBin)?.nodes.first)
        XCTAssertEqual(bin.count, 2)
        XCTAssertEqual(bin.children.map(\.count), [2])
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
                       [root.id, work.id, recycleBin.id, old.id])
    }

    func testABinNestedDeeperIsLiftedOutOfGroups() async throws {
        let recycleBin = KPGroup(name: "Trash")
        let archive = KPGroup(name: "Archive", groups: [recycleBin])
        let root = KPGroup(name: "Root", groups: [archive, KPGroup(name: "Other")], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root)

        let snapshot = MacSidebarSnapshot.make(session: session)

        let archiveNode = try XCTUnwrap(snapshot.section(.groups)?.nodes.first?.children.first { $0.id == .group(archive.id) })
        XCTAssertTrue(archiveNode.children.isEmpty)
        XCTAssertEqual(snapshot.section(.recycleBin)?.nodes.map(\.id), [.group(recycleBin.id)])
    }

    func testAWrapperHoldingOnlyTheBinKeepsTheWrapperAsGroupsRoot() async throws {
        let recycleBin = KPGroup(name: "Recycle Bin")
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
        let recycleBin = KPGroup(name: "Recycle Bin", iconID: 0, customIconUUID: customID)
        let root = KPGroup(name: "Root", groups: [custom, missing, recycleBin], recycleBinUUID: recycleBin.id)
        let session = try await makeSidebarSession(root: root, customIcons: [customID: Data([1, 2, 3])])

        let snapshot = MacSidebarSnapshot.make(session: session)
        let children = try XCTUnwrap(snapshot.section(.groups)?.nodes.first?.children)

        XCTAssertEqual(children.first { $0.title == "Banking" }?.icon, .custom(Data([1, 2, 3]), standardIconID: 0))
        XCTAssertEqual(children.first { $0.title == "Missing" }?.icon, .standard(5))
        XCTAssertEqual(snapshot.section(.recycleBin)?.nodes.first?.icon, .standard(43))
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
final class MacDatabaseStatusTests: MacSidebarSessionTestCase {
    func testACleanLocalWritableSessionHasNoStatus() async throws {
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [KPGroup(name: "Child")]))

        XCTAssertNil(MacDatabaseStatus.make(session: session))
    }

    func testADirtyDraftReportsUnsavedChanges() async throws {
        let child = KPGroup(name: "Child")
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [child]))
        try session.applyEntryEdit(.createEntry(parentGroupID: child.id, draft: EntryDraftPayload(title: "New")))
        XCTAssertTrue(session.isDirty)

        let status = try XCTUnwrap(MacDatabaseStatus.make(session: session))

        XCTAssertEqual(status.lines.map(\.kind), [.unsavedChanges])
        XCTAssertEqual(status.lines.first?.text, String(localized: "Changes not saved"))
        XCTAssertEqual(status.lines.first?.tone, .warning)
    }

    func testAReadOnlySessionSaysSo() async throws {
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [KPGroup(name: "Child")]))
        session.setReadOnly(true)

        let status = try XCTUnwrap(MacDatabaseStatus.make(session: session))

        XCTAssertEqual(status.lines.map(\.kind), [.readOnly])
        XCTAssertEqual(status.lines.first?.text, String(localized: "Read-only database"))
        XCTAssertEqual(status.lines.first?.systemImage, "eyeglasses")
    }

    func testALocalSessionReportsNoCloudState() async throws {
        let session = try await makeSidebarSession(root: KPGroup(name: "Root", groups: [KPGroup(name: "Child")]))

        let state = MacDatabaseStatus.State(session: session)

        XCTAssertNil(state.cloudSync)
        XCTAssertFalse(state.showsPendingUploadNote)
        XCTAssertFalse(state.hasPendingUploadConflict)
    }

    func testSavingSpeaksForTheDraftAndTheConflict() throws {
        var state = MacDatabaseStatus.State()
        state.isSaving = true
        state.isDirty = true
        state.hasPendingUploadConflict = true

        let status = try XCTUnwrap(MacDatabaseStatus(state))

        XCTAssertEqual(status.lines.map(\.kind), [.saving])
        XCTAssertEqual(status.lines.first?.text, String(localized: "Saving…"))
        XCTAssertEqual(status.lines.first?.tone, .neutral)
    }

    func testAnUploadConflictUsesTheBannerText() throws {
        var state = MacDatabaseStatus.State()
        state.hasPendingUploadConflict = true

        let status = try XCTUnwrap(MacDatabaseStatus(state))

        XCTAssertEqual(status.lines.map(\.kind), [.uploadConflict])
        XCTAssertEqual(status.lines.first?.text, String(
            localized: "A change saved through AutoFill couldn’t be uploaded because the cloud copy changed. Merge it into this database to upload it."
        ))
        XCTAssertEqual(status.lines.first?.tone, .warning)
    }

    func testCloudSyncingAndWarningCarryTheToolbarTitle() throws {
        var state = MacDatabaseStatus.State()
        state.cloudSync = .syncing("Checking WebDAV for changes…")
        let syncing = try XCTUnwrap(MacDatabaseStatus(state)).lines
        XCTAssertEqual(syncing.map(\.kind), [.cloudSyncing])
        XCTAssertEqual(syncing.first?.text, "Checking WebDAV for changes…")
        XCTAssertEqual(syncing.first?.tone, .neutral)

        state.cloudSync = .warning("Opened without checking WebDAV for changes.")
        state.showsPendingUploadNote = true
        let warning = try XCTUnwrap(MacDatabaseStatus(state)).lines
        XCTAssertEqual(warning.map(\.kind), [.cloudSyncWarning, .pendingUpload])
        XCTAssertEqual(warning.first?.tone, .warning)
        XCTAssertEqual(
            warning.last?.text,
            String(localized: "Changes saved through AutoFill are still waiting to upload.")
        )
    }

    func testLinesKeepTheirOrder() throws {
        var state = MacDatabaseStatus.State()
        state.isDirty = true
        state.hasPendingUploadConflict = true
        state.cloudSync = .warning("Sync failed")
        state.isReadOnly = true

        XCTAssertEqual(
            try XCTUnwrap(MacDatabaseStatus(state)).lines.map(\.kind),
            [.unsavedChanges, .uploadConflict, .cloudSyncWarning, .readOnly]
        )
        XCTAssertNil(MacDatabaseStatus(MacDatabaseStatus.State()))
    }
}
#endif
