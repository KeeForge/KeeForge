#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

/// The window's Discard Pending Upload through the coordinator's list wiring and the real discard:
/// live markers, the shared cache, the backup and the list reload that reconciles the session.
@MainActor
final class MacPendingUploadDiscardTests: XCTestCase {
    private var shown: [(alert: NSAlert, answer: @MainActor (NSApplication.ModalResponse) -> Void)] = []
    private var reference: DatabaseReference?

    override func tearDown() async throws {
        if let reference {
            for marker in PendingUploadQueue.listMarkers(for: reference.id) { _ = try? PendingUploadQueue.dropIfUnchanged(marker) }
            try? FileManager.default.removeItem(at: DatabaseListStore.cacheLocation(for: reference))
            try? FileManager.default.removeItem(at: DatabaseListStore.databaseBackupDirectoryURL(for: reference))
            DatabaseListStore.remove(id: reference.id)
        }
        try await super.tearDown()
    }

    func testDiscardBacksUpDropsTheMarkerAndHoldsOffMergeAndASecondDiscardWhileItRuns() async throws {
        let payload = Data("autofill-payload".utf8)
        let (session, presentation, alerts) = try await open(cache: payload, status: .downloaded)
        let commands = MacWorkspaceCommands(session: session, presentation: presentation)
        XCTAssertTrue(session.hasPendingUploadConflict)
        XCTAssertFalse(session.holdsPendingUploadPayload, "The window opened the cloud copy, not the AutoFill save")
        XCTAssertTrue(commands.canDiscardPendingUpload)
        XCTAssertEqual(mergeNotice(session, presentation)?.isActionEnabled, true)

        alerts.requestDiscardPendingUpload()
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .discardPendingUpload)
        shown.last?.answer(.alertFirstButtonReturn)
        XCTAssertFalse(commands.canDiscardPendingUpload, "No second discard while one runs")
        XCTAssertEqual(mergeNotice(session, presentation)?.isActionEnabled, false, "Merge Changes waits for the discard")
        alerts.requestDiscardPendingUpload()
        await settle()
        XCTAssertNil(alerts.presented)

        try await waitUntil { session.hasPendingUploadConflict == false }
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: session.databaseReference.id).isEmpty)
        XCTAssertEqual(backups(for: session.databaseReference), [payload], "The AutoFill save is kept as a backup")
        XCTAssertNil(mergeNotice(session, presentation))
        XCTAssertFalse(commands.canDiscardPendingUpload)
        XCTAssertEqual(shown.count, 1)
    }

    func testAWindowThatOpenedTheAutoFillSaveFromTheCacheCannotDiscardIt() async throws {
        let fixture = try Data(contentsOf: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self)))
        let (session, presentation, alerts) = try await open(cache: fixture, status: .offlineCached)
        XCTAssertTrue(session.hasPendingUploadConflict)
        XCTAssertTrue(session.holdsPendingUploadPayload, "The cached copy it opened is the AutoFill save")
        XCTAssertNotNil(mergeNotice(session, presentation), "Merge Changes stays the way forward")
        XCTAssertFalse(MacWorkspaceCommands(session: session, presentation: presentation).canDiscardPendingUpload,
                       "Its next save would upload the change again")
        alerts.requestDiscardPendingUpload()
        await settle()
        XCTAssertNil(alerts.presented)
        XCTAssertEqual(PendingUploadQueue.listMarkers(for: session.databaseReference.id).count, 1)
    }

    func testAReadOnlyWindowShowsNoConflictAndOffersNoDiscard() async throws {
        let (session, presentation, _) = try await open(cache: Data("autofill-payload".utf8), status: .downloaded)
        XCTAssertTrue(MacWorkspaceCommands(session: session, presentation: presentation).canDiscardPendingUpload)
        session.setReadOnly(true)
        XCTAssertFalse(session.hasPendingUploadConflict)
        XCTAssertGreaterThan(presentation.pendingUploads.counts(session.databaseReference.id).conflicts, 0)
        XCTAssertNil(mergeNotice(session, presentation))
        XCTAssertFalse(MacDatabaseStatus.make(session: session, presentation: presentation).line.text
            .contains(String(localized: "\(1) pending upload conflicts")))
        XCTAssertFalse(MacWorkspaceCommands(session: session, presentation: presentation).canDiscardPendingUpload,
                       "Command, card and notice agree")
    }

    func testTheDiscardAlertIsWithdrawnWhenASheetOpens() async throws {
        let (session, presentation, alerts) = try await open(cache: Data("autofill-payload".utf8), status: .downloaded)
        alerts.requestDiscardPendingUpload()
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .discardPendingUpload)
        presentation.passwordImport = true
        await settle()
        XCTAssertNil(alerts.presented, "Not left over the Import sheet")
        XCTAssertFalse(MacWorkspaceCommands(session: session, presentation: presentation).canDiscardPendingUpload)
    }

    // MARK: - Helpers

    /// A cloud database whose shared cache holds `cache` and whose one conflicted marker records it as the AutoFill
    /// save; the window opens the test fixture with `status`, through the coordinator's list wiring.
    private func open(cache: Data, status: CloudSyncResolution.Status)
        async throws -> (DatabaseViewModel, MacWorkspacePresentation, MacWorkspaceAlerts) {
        let fixture = try Data(contentsOf: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self)))
        let reference = DatabaseReference(
            id: UUID(), nickname: nil, filename: "vault.kdbx", bookmarkData: nil, keyFileBookmarkData: nil,
            keyFileFilename: nil, isQuickLaunch: false, lastOpenedAt: nil, addedAt: Date(timeIntervalSince1970: 50),
            colorTag: nil, legacyKeychainFilename: nil,
            source: .cloud(CloudSyncMetadata(
                provider: CloudProviderKind.dropbox.rawValue, accountId: "acct-1", fileId: "/Vaults/vault.kdbx",
                displayPath: "/Vaults/vault.kdbx", remoteContentHash: nil, remoteModifiedAt: nil,
                lastSyncedAt: nil, lastSyncIssue: nil)))
        self.reference = reference
        DatabaseListStore.testUpsert(reference)
        try DatabaseListStore.cacheDatabaseCopy(cache, for: reference)
        _ = try PendingUploadQueue.enqueue(PendingUploadQueue.Marker(
            databaseId: reference.id, encryptedBytesCacheURL: "cloud-cache/\(reference.id.uuidString).kdbx",
            openTimeSHA512: FileDigest.sha512(cache), expectedRev: "rev-1", createdAt: Date(timeIntervalSince1970: 1_000),
            isConflicted: true, baseRev: "rev-1"))

        let session = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(reference: reference, localURL: DatabaseListStore.cacheLocation(for: reference),
                                    data: fixture, status: status)
            },
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false })
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }

        let list = DatabaseListViewModel()
        // What DatabaseSessionStore.installListHooks does for an open session.
        list.referencesDidChange = { references in references.forEach(session.reconcileReference) }
        list.reload()
        let presentation = MacWorkspacePresentation()
        presentation.pendingUploads = .list(list)
        let alerts = MacWorkspaceAlerts(session: session, presentation: presentation) { nil }
        alerts.present = { [weak self] alert, _, answer in self?.shown.append((alert, answer)) }
        alerts.start()
        addTeardownBlock { @MainActor in alerts.invalidate() }
        return (session, presentation, alerts)
    }

    private func mergeNotice(_ session: DatabaseViewModel, _ presentation: MacWorkspacePresentation) -> MacDatabaseStatus.Notice? {
        MacDatabaseStatus.make(session: session, presentation: presentation).notices.first { $0.kind == .uploadConflict }
    }

    private func backups(for reference: DatabaseReference) -> [Data] {
        let directory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { try? Data(contentsOf: $0) }
    }

    private func settle() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where condition() == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}
#endif
