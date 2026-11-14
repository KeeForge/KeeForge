#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class MacEntryListModelTests: XCTestCase {
    private static let sortDefaultsKeys = ["KeeForge.sortOrder", "KeeForge.sortAscending"]
    private var savedSortDefaults: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        savedSortDefaults = Self.sortDefaultsKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    override func tearDown() async throws {
        for key in Self.sortDefaultsKeys {
            UserDefaults.standard.set(savedSortDefaults[key], forKey: key)
        }
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    // MARK: - Snapshot

    func testModePrecedenceIsSearchThenTagThenCollectionThenGroupThenRoot() async throws {
        let fixture = try await makeFixture()
        let session = fixture.session
        let workspace = session.workspace

        workspace.selectedGroupID = fixture.work.id
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .group(fixture.work.id))
        workspace.selectedCollection = .verificationCodes
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .collection(.verificationCodes))
        workspace.selectedTag = "Shared"
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .tag("Shared"))
        session.searchText = "zzz"
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .search("zzz"))
        session.searchText = ""
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .tag("Shared"))

        workspace.clearSelection()
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .group(try XCTUnwrap(session.workspaceRootGroupID)))
        workspace.selectedGroupID = UUID()
        XCTAssertEqual(MacEntryListSnapshot.mode(session: session), .none)
        let none = MacEntryListSnapshot.make(session: session)
        XCTAssertEqual(none.rows, [])
        XCTAssertEqual(none.emptyState, .noGroupSelected)
    }

    func testRowsCarryIconsGlyphsAndRawFieldsWithoutSecrets() async throws {
        let iconID = UUID()
        let iconData = Data([1, 2, 3])
        let passkeyFields = [
            PasskeyCredential.credentialIDKey: "Y3JlZA",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.usernameKey: "alice",
            PasskeyCredential.userHandleKey: "aGFuZGxl",
        ]
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rich = KPEntry(
            title: "Rich",
            username: "{REF:U@T:Plain}",
            url: "https://www.example.com/login",
            iconID: 12,
            customFields: passkeyFields,
            passkeyPrivateKey: EncryptedValue(sealedData: Data([0]), hasValue: true),
            totpConfig: Self.totp,
            creationTime: now.addingTimeInterval(-3),
            expires: true,
            expiryTime: now.addingTimeInterval(-1)
        )
        let custom = KPEntry(url: "https://custom.example", iconID: 3, customIconUUID: iconID,
                             creationTime: now.addingTimeInterval(-2), expires: true, expiryTime: now.addingTimeInterval(60))
        let plain = KPEntry(title: "Plain", username: "bob", iconID: 5, creationTime: now.addingTimeInterval(-1))
        let group = KPGroup(name: "Work", entries: [rich, custom, plain])
        let session = try await makeSession(
            root: KPGroup(name: "Root", groups: [group, KPGroup(name: "Home")]),
            customIcons: [iconID: iconData]
        )
        session.workspace.selectedGroupID = group.id
        session.sortOrder = .createdDate
        session.sortAscending = true

        let rows = MacEntryListSnapshot.make(session: session, showsWebsiteIcons: true, now: now).rows
        XCTAssertEqual(rows.map(\.id), [rich.id, custom.id, plain.id])
        XCTAssertEqual(rows.map(\.title), ["Rich", String(localized: "(untitled)"), "Plain"])
        XCTAssertEqual(rows.map(\.rawUsername), ["{REF:U@T:Plain}", "", "bob"])
        XCTAssertEqual(rows.map(\.icon), [.standard(12), .custom(iconData, standardIconID: 3), .standard(5)])
        XCTAssertEqual(rows.map(\.faviconDomain), ["www.example.com", nil, nil])
        XCTAssertEqual(rows.map(\.isExpired), [true, false, false])
        XCTAssertEqual(rows.map(\.hasPasskey), [true, false, false])
        XCTAssertEqual(rows.map(\.hasVerificationCode), [true, false, false])
        XCTAssertEqual(rows.map(\.isMovable), [true, true, true])

        let withoutFavicons = MacEntryListSnapshot.make(session: session, showsWebsiteIcons: false, now: now)
        XCTAssertEqual(withoutFavicons.rows.map(\.faviconDomain), [nil, nil, nil])
    }

    func testFolderPathOnlyWhenTheListSpansGroups() async throws {
        let fixture = try await makeFixture()
        let session = fixture.session
        let workspace = session.workspace

        workspace.selectedGroupID = fixture.work.id
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.folderPath), [nil, nil, nil])

        workspace.selectedCollection = .allEntries
        let collectionRows = MacEntryListSnapshot.make(session: session).rows
        XCTAssertEqual(Set(collectionRows.map(\.folderPath)), ["Work", "Home"])

        workspace.selectedTag = "Shared"
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.folderPath), ["Work", "Home"])

        session.searchText = "account"
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.folderPath), ["Work", "Work", "Work", "Home"])
    }

    func testSortFollowsSortOrderWhileSearchKeepsTreeOrder() async throws {
        let fixture = try await makeFixture()
        let session = fixture.session
        session.workspace.selectedGroupID = fixture.work.id

        session.sortOrder = .title
        session.sortAscending = true
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.title),
                       ["Account A", "Account b", "Account c"])
        session.sortAscending = false
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.title),
                       ["Account c", "Account b", "Account A"])
        session.sortOrder = .createdDate
        session.sortAscending = true
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.title),
                       ["Account b", "Account A", "Account c"])

        session.sortOrder = .title
        session.workspace.selectedCollection = .verificationCodes
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.title), ["Account A", "Home Account"])

        session.searchText = "account"
        let search = MacEntryListSnapshot.make(session: session)
        XCTAssertEqual(search.rows.map(\.title), ["Account b", "Account A", "Account c", "Home Account"])
        XCTAssertEqual(search.resultCount, 4)
    }

    func testEmptyStatesCarryTodaysTexts() async throws {
        let emptyGroup = KPGroup(name: "Empty")
        let session = try await makeSession(root: KPGroup(name: "Root", groups: [emptyGroup, KPGroup(name: "Other")]))
        let workspace = session.workspace

        workspace.selectedGroupID = emptyGroup.id
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).emptyState, .noGroupEntries)
        workspace.selectedCollection = .allEntries
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).emptyState, .noDatabaseEntries)
        workspace.selectedCollection = .verificationCodes
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).emptyState, .noVerificationCodes)
        workspace.selectedTag = "Gone"
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).emptyState, .noTagEntries)
        session.searchText = "   "
        let prompt = MacEntryListSnapshot.make(session: session)
        XCTAssertEqual(prompt.emptyState, .searchPrompt)
        XCTAssertEqual(prompt.resultCount, 0)
        session.searchText = "nothing"
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).emptyState, .noResults(query: "nothing"))

        let expected: [(MacEntryListSnapshot.EmptyState, String, String, String, String?)] = [
            (.searchPrompt, "Search Entries", "Type to search by title, username, URL, notes, or tags.",
             "magnifyingglass", nil),
            (.noResults(query: "x"), "No Results", "No entries matched \"x\".", "doc.text.magnifyingglass",
             "search.no-results"),
            (.noTagEntries, "No Entries", "No entries carry this tag anymore.", "tag.slash", nil),
            (.noVerificationCodes, "No Verification Codes", "Entries with a verification code appear here.",
             DatabaseCollection.verificationCodes.systemImage, nil),
            (.noDatabaseEntries, "No Entries", "This database has no entries.", "tray", nil),
            (.noGroupEntries, "No Entries", "This group has no entries.", "tray", nil),
            (.noGroupSelected, "Select a Group", "Choose a group to view its entries.", "folder", nil),
        ]
        for (state, title, message, symbol, identifier) in expected {
            XCTAssertEqual(state.title, title)
            XCTAssertEqual(state.message, message)
            XCTAssertEqual(state.systemImage, symbol)
            XCTAssertEqual(state.accessibilityIdentifier, identifier)
        }
    }

    func testIdentifiersAndCodeRowsPerMode() async throws {
        let fixture = try await makeFixture()
        let session = fixture.session
        let workspace = session.workspace

        workspace.selectedGroupID = fixture.work.id
        var snapshot = MacEntryListSnapshot.make(session: session)
        XCTAssertEqual(snapshot.rowIdentifier, "entry.navlink")
        XCTAssertNil(snapshot.containerIdentifier)
        XCTAssertFalse(snapshot.showsVerificationCodes)
        XCTAssertNil(snapshot.resultCount)

        workspace.selectedCollection = .verificationCodes
        snapshot = MacEntryListSnapshot.make(session: session)
        XCTAssertEqual(snapshot.rowIdentifier, "entry.navlink")
        XCTAssertNil(snapshot.containerIdentifier)
        XCTAssertTrue(snapshot.showsVerificationCodes)

        workspace.selectedCollection = .allEntries
        XCTAssertFalse(MacEntryListSnapshot.make(session: session).showsVerificationCodes)

        workspace.selectedTag = "Shared"
        snapshot = MacEntryListSnapshot.make(session: session)
        XCTAssertEqual(snapshot.rowIdentifier, "search.entry.navlink")
        XCTAssertEqual(snapshot.containerIdentifier, "tag-entries.list")

        session.searchText = "account"
        snapshot = MacEntryListSnapshot.make(session: session)
        XCTAssertEqual(snapshot.rowIdentifier, "search.entry.navlink")
        XCTAssertEqual(snapshot.containerIdentifier, "search.results")
        session.searchText = "nothing"
        XCTAssertNil(MacEntryListSnapshot.make(session: session).containerIdentifier)
    }

    func testMovabilityFollowsTheRecycleBinAndReadOnly() async throws {
        let live = KPEntry(title: "Live")
        let recycled = KPEntry(title: "Recycled")
        let bin = KPGroup(name: "Recycle Bin", entries: [recycled])
        let work = KPGroup(name: "Work", entries: [live])
        let session = try await makeSession(root: KPGroup(name: "Root", groups: [work, bin], recycleBinUUID: bin.id))
        session.workspace.selectedGroupID = bin.id
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.isMovable), [false])
        session.workspace.selectedGroupID = work.id
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.isMovable), [true])

        DatabaseListStore.update(session.databaseReference)
        session.setReadOnly(true)
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.map(\.isMovable), [false])
    }

    func testMakeDoesNotResolveFieldReferences() async throws {
        var entries = (0..<5_000).map { KPEntry(title: "Account \($0)", username: "user\($0)") }
        entries[4_999].username = "{REF:U@T:Account 0}"
        let group = KPGroup(name: "Accounts", entries: entries)
        let session = try await makeSession(root: KPGroup(name: "Root", groups: [group, KPGroup(name: "Other")]))
        session.workspace.selectedGroupID = group.id
        XCTAssertFalse(try hasBuiltFieldReferenceCache(session))

        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.count, 5_000)
        session.workspace.selectedCollection = .allEntries
        _ = MacEntryListSnapshot.make(session: session)
        session.searchText = "account"
        XCTAssertEqual(MacEntryListSnapshot.make(session: session).rows.count, 5_000)

        XCTAssertFalse(try hasBuiltFieldReferenceCache(session), "make must leave usernames for the cell to resolve")
        XCTAssertEqual(session.resolvingFieldReferences(entries[4_999].username), "user0")
        XCTAssertTrue(try hasBuiltFieldReferenceCache(session), "probe must detect a built resolver")
    }

    // MARK: - Selection policy

    func testTableSelectionShowsTheVisibleBulkPicksOrTheSelectedEntry() {
        let rows = Self.rows(count: 3)
        let workspace = DatabaseWorkspaceState()
        XCTAssertEqual(MacEntryListSelection.tableSelection(rows: rows, workspace: workspace), [])
        workspace.selectedEntryID = rows[1].id
        XCTAssertEqual(MacEntryListSelection.tableSelection(rows: rows, workspace: workspace), [1])
        workspace.selectedEntryID = UUID()
        XCTAssertEqual(MacEntryListSelection.tableSelection(rows: rows, workspace: workspace), [])
        workspace.setEntrySelection([rows[0].id, rows[2].id, UUID()])
        XCTAssertEqual(MacEntryListSelection.tableSelection(rows: rows, workspace: workspace), [0, 2])
        workspace.setEntrySelection([])
        XCTAssertEqual(MacEntryListSelection.tableSelection(rows: rows, workspace: workspace), [])
    }

    func testApplyingAPlainSelectionCollapsesToTheTable() {
        let rows = Self.rows(count: 3)
        let visible = Set(rows.map(\.id))
        let hidden = UUID()
        let workspace = DatabaseWorkspaceState()

        MacEntryListSelection.apply(selectedIDs: [rows[0].id], visibleIDs: visible, isExtending: false, to: workspace)
        XCTAssertNil(workspace.entrySelection)
        XCTAssertEqual(workspace.selectedEntryID, rows[0].id)

        MacEntryListSelection.apply(selectedIDs: [rows[0].id, rows[1].id], visibleIDs: visible, isExtending: false,
                                    to: workspace)
        XCTAssertEqual(workspace.entrySelection, [rows[0].id, rows[1].id])

        workspace.setEntrySelection([hidden, rows[0].id])
        MacEntryListSelection.apply(selectedIDs: [rows[2].id], visibleIDs: visible, isExtending: false, to: workspace)
        XCTAssertNil(workspace.entrySelection, "a plain click drops picks the list does not show")
        XCTAssertEqual(workspace.selectedEntryID, rows[2].id)

        MacEntryListSelection.apply(selectedIDs: [], visibleIDs: visible, isExtending: false, to: workspace)
        XCTAssertNil(workspace.entrySelection)
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testApplyingAnExtendedSelectionKeepsHiddenPicks() {
        let rows = Self.rows(count: 3)
        let visible = Set(rows.map(\.id))
        let hidden = UUID()
        let workspace = DatabaseWorkspaceState()

        workspace.selectedEntryID = rows[0].id
        MacEntryListSelection.apply(selectedIDs: [rows[0].id, rows[1].id], visibleIDs: visible, isExtending: true,
                                    to: workspace)
        XCTAssertEqual(workspace.entrySelection, [rows[0].id, rows[1].id])

        workspace.setEntrySelection([hidden])
        MacEntryListSelection.apply(selectedIDs: [rows[2].id], visibleIDs: visible, isExtending: true, to: workspace)
        XCTAssertEqual(workspace.entrySelection, [hidden, rows[2].id])

        MacEntryListSelection.apply(selectedIDs: [], visibleIDs: visible, isExtending: true, to: workspace)
        XCTAssertNil(workspace.entrySelection, "one pick left is a single selection")
        XCTAssertEqual(workspace.selectedEntryID, hidden)

        workspace.selectedEntryID = nil
        MacEntryListSelection.apply(selectedIDs: [rows[1].id], visibleIDs: visible, isExtending: true, to: workspace)
        XCTAssertNil(workspace.entrySelection)
        XCTAssertEqual(workspace.selectedEntryID, rows[1].id)
    }

    func testProposedSelectionFiltersImmovableRowsAndKeepsOneWhenReadOnly() {
        let rows = Self.rows(count: 4, immovable: [1, 3])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([1], current: [], rows: rows, isReadOnly: false), [1])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([], current: [0], rows: rows, isReadOnly: false), [])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([0, 1, 2, 3], current: [0], rows: rows, isReadOnly: false),
                       [0, 2])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([0, 1], current: [0], rows: rows, isReadOnly: false), [0])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([1, 3], current: [1], rows: rows, isReadOnly: false), [1],
                       "only immovable rows keep the current selection")

        XCTAssertEqual(MacEntryListSelection.proposedSelection([2], current: [0], rows: rows, isReadOnly: true), [2])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([0, 2], current: [0], rows: rows, isReadOnly: true), [0])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([0, 1, 2], current: [], rows: rows, isReadOnly: true), [])
        XCTAssertEqual(MacEntryListSelection.proposedSelection([1, 2], current: [0, 2], rows: rows, isReadOnly: true), [1])
    }

    // MARK: - Verification code clock

    func testClockShowsCodeAndCountdownAndCachesOnlyTheCurrentStep() async throws {
        let entry = KPEntry(title: "Code", totpConfig: Self.totp)
        let other = KPEntry(title: "Other")
        let group = KPGroup(name: "Work", entries: [entry, other])
        let session = try await makeSession(root: KPGroup(name: "Root", groups: [group, KPGroup(name: "Home")]))
        var date = Date(timeIntervalSince1970: 1_000_000_005)
        var generated: [Date] = []
        let clock = MacVerificationCodeClock(now: { date }, generate: { _, _, at in
            generated.append(at)
            return generated.count.isMultiple(of: 2) ? "654321" : "123456"
        })

        XCTAssertEqual(clock.display(for: entry.id, session: session), MacVerificationCodeClock.Display(
            code: "123456", grouped: "123 456", secondsRemaining: 15, progress: 0.5
        ))
        date = date.addingTimeInterval(14)
        XCTAssertEqual(clock.display(for: entry.id, session: session)?.code, "123456")
        XCTAssertEqual(clock.display(for: entry.id, session: session)?.secondsRemaining, 1)
        XCTAssertEqual(generated.count, 1, "the step's code is reused")

        date = date.addingTimeInterval(1)
        XCTAssertEqual(clock.display(for: entry.id, session: session), MacVerificationCodeClock.Display(
            code: "654321", grouped: "654 321", secondsRemaining: 30, progress: 1
        ))
        XCTAssertEqual(generated.count, 2)
        XCTAssertNil(clock.display(for: other.id, session: session))
        XCTAssertNil(clock.display(for: UUID(), session: session))
        XCTAssertEqual(clock.cachedCodeCount, 1)

        clock.forget(entry.id)
        XCTAssertEqual(clock.cachedCodeCount, 0, "a row scrolled away forgets its code")
        _ = clock.display(for: entry.id, session: session)
        XCTAssertEqual(generated.count, 3)

        clock.reset()
        XCTAssertEqual(clock.cachedCodeCount, 0)
        _ = clock.display(for: entry.id, session: session)
        XCTAssertEqual(generated.count, 4)

        let revision = session.contentRevision
        try session.deleteEntry(other.id, sendToRecycleBin: false)
        XCTAssertNotEqual(session.contentRevision, revision)
        _ = clock.display(for: entry.id, session: session)
        XCTAssertEqual(generated.count, 5, "a content change drops the cache")

        session.lockRequest(force: true)
        XCTAssertNil(clock.display(for: entry.id, session: session))
        XCTAssertEqual(clock.cachedCodeCount, 0, "lock clears the cache")
        XCTAssertEqual(generated.count, 5)
        session.workspace.selectedCollection = .verificationCodes
        XCTAssertFalse(MacEntryListSnapshot.make(session: session).showsVerificationCodes, "no session key, no codes")
    }

    func testClockDefaultsToTheRealGenerator() async throws {
        let session = try await makeSession(root: KPGroup(name: "Root"))
        let config = TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: try XCTUnwrap(session.sessionKey)))
        let entry = KPEntry(title: "Real", totpConfig: config)
        let group = KPGroup(name: "Work", entries: [entry])
        session.draft = DatabaseDraft(
            rootGroup: KPGroup(name: "Root", groups: [group, KPGroup(name: "Home")]),
            meta: KPMeta(),
            sessionKey: try XCTUnwrap(session.sessionKey)
        )
        let date = Date(timeIntervalSince1970: 59)
        let display = try XCTUnwrap(MacVerificationCodeClock(now: { date }).display(for: entry.id, session: session))
        XCTAssertEqual(display.code, TOTPGenerator.generateCode(config: config, sessionKey: try XCTUnwrap(session.sessionKey), date: date))
        XCTAssertNotEqual(display.code, TOTPGenerator.placeholderCode)
        XCTAssertEqual(display.secondsRemaining, 1)
    }

    // MARK: - Helpers

    private static let totp = TOTPConfig(secret: EncryptedValue(sealedData: Data([0]), hasValue: true))

    private struct Fixture {
        let session: DatabaseViewModel
        let work: KPGroup
        let home: KPGroup
    }

    /// Work holds three accounts in tree order b, A, c (created in that
    /// order); Home holds one. Two carry codes and the "Shared" tag.
    private func makeFixture() async throws -> Fixture {
        func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
        let work = KPGroup(name: "Work", entries: [
            KPEntry(title: "Account b", tags: ["Shared"], creationTime: date(1)),
            KPEntry(title: "Account A", totpConfig: Self.totp, creationTime: date(2)),
            KPEntry(title: "Account c", creationTime: date(3)),
        ])
        let home = KPGroup(name: "Home", entries: [
            KPEntry(title: "Home Account", tags: ["Shared"], totpConfig: Self.totp, creationTime: date(4)),
        ])
        let session = try await makeSession(root: KPGroup(name: "Root", groups: [work, home]))
        session.sortOrder = .title
        session.sortAscending = true
        return Fixture(session: session, work: work, home: home)
    }

    private func makeSession(
        root: KPGroup,
        customIcons: [UUID: Data] = [:]
    ) async throws -> DatabaseViewModel {
        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Entry List",
                destination: .appOnlyAcknowledged,
                password: "entry list password"
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

    private static func rows(count: Int, immovable: Set<Int> = []) -> [MacEntryListSnapshot.Row] {
        (0..<count).map { index in
            MacEntryListSnapshot.Row(
                id: UUID(), title: "Row \(index)", rawUsername: "", folderPath: nil, icon: .standard(0),
                faviconDomain: nil, isExpired: false, hasPasskey: false, hasVerificationCode: false,
                isMovable: immovable.contains(index) == false
            )
        }
    }

    private func hasBuiltFieldReferenceCache(_ viewModel: DatabaseViewModel) throws -> Bool {
        let cache = try XCTUnwrap(
            Mirror(reflecting: viewModel).children.first { $0.label == "fieldReferenceResolver" },
            "Resolver storage was renamed; update this probe."
        )
        return Mirror(reflecting: cache.value).children.isEmpty == false
    }
}
#endif
