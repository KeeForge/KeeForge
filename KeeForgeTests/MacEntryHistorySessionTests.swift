#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class MacEntryHistorySessionTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testItOpensOnTheNewestVersionAndComparesItWithTheCurrentEntry() async throws {
        let entry = try entryWithHistory()
        let session = try await makeSession(entries: [entry])
        defer { session.lockRequest(force: true) }
        let presentation = MacWorkspacePresentation()

        presentation.showEntryHistory(entryID: entry.id, in: session, currentSession: { session })
        XCTAssertNil(presentation.entryHistory, "Only for the selected entry")
        session.workspace.selectedEntryID = entry.id
        presentation.showEntryHistory(entryID: entry.id, in: session, currentSession: { session })
        let history = try XCTUnwrap(presentation.currentEntryHistory(in: session))
        history.appeared()

        XCTAssertEqual(history.versions.map(\.index), [1, 0], "Newest first")
        XCTAssertEqual(history.selectedIndex, 1)
        XCTAssertEqual(history.selectedVersion?.title, "GitHub")
        XCTAssertEqual(history.versionModel?.source, .history(entryID: entry.id, index: 1))
        XCTAssertEqual(history.versionModel?.fields.map(\.kind), [.username, .password, .notes])
        let comparison = try XCTUnwrap(history.comparison)
        XCTAssertEqual(comparison.differences.map(\.field), [.username, .password, .website(0), .notes])
        XCTAssertEqual(history.difference(for: .notes)?.current, .text("Codes in Finance"))
        XCTAssertEqual(history.difference(for: .username)?.current, .text("alice"))
        XCTAssertEqual(history.difference(for: .password)?.current, .concealed)
        XCTAssertNil(history.difference(for: .passkeyUsername))
        XCTAssertEqual(history.differencesWithoutVersionRow.map(\.field), [.website(0)],
                       "The website only the current entry has still gets a row")
        XCTAssertEqual(MacEntryHistorySession.currentValueText(try XCTUnwrap(history.difference(for: .username))),
                       String(localized: "Now: \("alice")"))
        XCTAssertEqual(MacEntryHistorySession.currentValueText(try XCTUnwrap(history.difference(for: .password))),
                       String(localized: "Different from the current password"),
                       "A protected value only says that it differs")

        let firstModel = try XCTUnwrap(history.versionModel)
        history.select(0)
        XCTAssertEqual(history.selectedVersion?.title, "GitHub (work)")
        XCTAssertFalse(history.versionModel === firstModel)
        XCTAssertTrue(history.comparison?.differs(.title) == true)
        history.select(7)
        XCTAssertEqual(history.selectedIndex, 0, "A version that does not exist is not selected")
    }

    func testRevealsAndCopiesTakeTheGateAndTickOnlyTheSheet() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let entry = try entryWithHistory()
        let session = try await makeSession(entries: [entry], secretAccess: harness.gate)
        defer { session.lockRequest(force: true) }
        session.workspace.selectedEntryID = entry.id
        let presentation = MacWorkspacePresentation()
        let live = presentation.detailModel(for: entry.id, in: session, currentSession: { session })
        live.appeared()
        var copied: [String] = []
        let history = MacEntryHistorySession(entryID: entry.id, session: session, currentSession: { session },
                                             copyFeedback: MacCopyFeedback(sleep: { _ in try await Task.sleep(for: .seconds(60)) }),
                                             copy: { copied.append($0) })
        history.appeared()
        let model = try XCTUnwrap(history.versionModel)
        func password() -> MacEntryField.Display? { model.fields.first { $0.kind == .password }?.display }

        XCTAssertEqual(password(), .concealed, "Masked until the gated reveal")
        harness.promptSucceeds = false
        await model.toggleReveal(.password)?.value
        await model.copy(.password)?.value
        XCTAssertEqual(password(), .concealed)
        XCTAssertTrue(copied.isEmpty, "A declined prompt shows and copies nothing")

        harness.promptSucceeds = true
        await model.toggleReveal(.password)?.value
        XCTAssertEqual(password(), .revealed("old-password"))
        await model.copy(.password)?.value
        XCTAssertEqual(copied, ["old-password"])
        XCTAssertEqual(harness.promptReasons, [
            String(localized: "View password"), String(localized: "Copy password"),
            String(localized: "View password"), String(localized: "Copy password"),
        ])
        XCTAssertTrue(model.isShowingCopied(.password))
        XCTAssertNil(presentation.copyFeedback.copied, "The live detail's tick is separate")
        XCTAssertFalse(live.isShowingCopied(.password))
        XCTAssertEqual(live.fields.first { $0.kind == .password }?.display, .concealed)

        history.close()
        XCTAssertNil(history.copyFeedback.copied)
        XCTAssertNil(history.versionModel)
        XCTAssertEqual(password(), .concealed, "Closing drops the reveal")
    }

    func testLockContentChangeSelectionChangeAndResetCloseTheSheet() async throws {
        let entry = try entryWithHistory()
        let other = KPEntry(title: "Other")
        let session = try await makeSession(entries: [entry, other])
        defer { session.lockRequest(force: true) }
        let presentation = MacWorkspacePresentation()
        func open() throws -> MacEntryHistorySession {
            session.workspace.selectedEntryID = entry.id
            presentation.showEntryHistory(entryID: entry.id, in: session, currentSession: { session })
            let history = try XCTUnwrap(presentation.currentEntryHistory(in: session))
            history.appeared()
            XCTAssertNotNil(history.versionModel)
            return history
        }
        func assertStale(_ history: MacEntryHistorySession, _ message: String) {
            XCTAssertNil(presentation.currentEntryHistory(in: session), message)
            XCTAssertNil(history.versionModel, message)
            XCTAssertNil(history.comparison, message)
            XCTAssertTrue(history.versions.isEmpty, message)
            presentation.closeEntryHistory(history)
            XCTAssertNil(presentation.entryHistory, message)
            XCTAssertTrue(history.isClosed, message)
        }

        var history = try open()
        session.workspace.selectedEntryID = other.id
        assertStale(history, "Another selection")

        history = try open()
        try session.applyEntryEdit(.updateEntry(entryID: other.id, draft: EntryDraftPayload(title: "Renamed")))
        assertStale(history, "A content change: the history list may have changed under it")

        history = try open()
        _ = presentation.detailModel(for: entry.id, in: session, currentSession: { session })
        XCTAssertTrue(presentation.entryHistory === history, "The same entry's detail keeps it")
        _ = presentation.detailModel(for: other.id, in: session, currentSession: { session })
        XCTAssertTrue(history.isClosed, "Another entry's detail closes it")
        XCTAssertNil(presentation.entryHistory)

        history = try open()
        presentation.reset()
        XCTAssertTrue(history.isClosed, "A window reset closes it")
        XCTAssertNil(presentation.entryHistory)

        history = try open()
        let newer = try XCTUnwrap({ () -> MacEntryHistorySession? in
            presentation.showEntryHistory(entryID: entry.id, in: session, currentSession: { session })
            return presentation.entryHistory
        }())
        XCTAssertTrue(history.isClosed, "Opening again replaces the old sheet's session")
        presentation.closeEntryHistory(history)
        XCTAssertTrue(presentation.entryHistory === newer, "A late dismissal of the old sheet leaves the new one")

        session.lockRequest(force: true)
        assertStale(newer, "Lock")
    }

    func testRestoreUsesTheExistingRestorePathThenClosesAndSaves() async throws {
        let entry = try entryWithHistory()
        let session = try await makeSession(entries: [entry])
        defer { session.lockRequest(force: true) }
        session.workspace.selectedEntryID = entry.id
        let presentation = MacWorkspacePresentation()
        presentation.showEntryHistory(entryID: entry.id, in: session, currentSession: { session })
        let history = try XCTUnwrap(presentation.currentEntryHistory(in: session))
        history.select(0)
        XCTAssertTrue(history.canRestore)

        await history.restore()?.value
        XCTAssertEqual(session.entry(withID: entry.id)?.title, "GitHub (work)")
        XCTAssertEqual(session.entry(withID: entry.id)?.username, "alice-work")
        XCTAssertTrue(history.isClosed)
        XCTAssertNil(presentation.currentEntryHistory(in: session))
        XCTAssertFalse(history.canRestore)
        XCTAssertNil(history.restore(), "A closed sheet restores nothing")
    }

    // MARK: - Support

    /// The current entry and two stored versions, the newer stored second, as KeePass appends.
    private func entryWithHistory() throws -> KPEntry {
        let older = KPEntry(
            title: "GitHub (work)", username: "alice-work",
            password: try EncryptedValue.encrypt("work-password", using: key),
            lastModificationTime: Date(timeIntervalSince1970: 1_000_000)
        )
        let newer = KPEntry(
            title: "GitHub", username: "alice-old",
            password: try EncryptedValue.encrypt("old-password", using: key),
            notes: "Printed codes", lastModificationTime: Date(timeIntervalSince1970: 2_000_000)
        )
        return KPEntry(
            title: "GitHub", username: "alice",
            password: try EncryptedValue.encrypt("hunter2", using: key),
            url: "https://github.com", notes: "Codes in Finance",
            lastModificationTime: Date(timeIntervalSince1970: 3_000_000),
            history: [older, newer]
        )
    }

    private func makeSession(
        entries: [KPEntry], secretAccess: SecretAccessGate = SecretAccessGate()
    ) async throws -> DatabaseViewModel {
        try await TestDatabaseSupport.makeUnlockedSession(root: KPGroup(name: "Root", entries: entries), key: key,
                                                          secretAccess: secretAccess, bundle: Bundle(for: Self.self))
    }
}
#endif
