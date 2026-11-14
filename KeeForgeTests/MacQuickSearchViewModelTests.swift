#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

/// The menu bar quick search against a real unlocked `test.kdbx` session. The
/// clipboard and the device-owner prompt are injected, so nothing here touches
/// the real pasteboard or raises a system dialog.
@MainActor
final class MacQuickSearchViewModelTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    /// The open sessions the model can resolve, and the focused one.
    private var sessions: [DatabaseViewModel] = []
    private var focusedDatabaseID: UUID?
    private var copied: [String] = []
    private var authenticationRequests = 0
    private var authenticationGates: [SecretAccessGate] = []
    private var authenticationResult = true
    private var copiedCallbacks = 0
    private var abortedCopies = 0
    private var shownDatabases: [UUID] = []
    private var showsDatabaseWindow = true
    private var databaseListRequests = 0
    private var dismissRequests = 0

    override func setUp() async throws {
        try await super.setUp()
        sessions = []
        focusedDatabaseID = nil
        copied = []
        authenticationRequests = 0
        authenticationGates = []
        authenticationResult = true
        copiedCallbacks = 0
        abortedCopies = 0
        shownDatabases = []
        showsDatabaseWindow = true
        databaseListRequests = 0
        dismissRequests = 0
    }

    override func tearDown() async throws {
        for session in sessions { session.lockRequest(force: true) }
        sessions = []
        try await super.tearDown()
    }

    // MARK: - What the panel shows

    func testNoSessionAsksToChooseADatabase() {
        let model = makeModel()

        XCTAssertEqual(model.content, .noDatabase)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testLockedSessionShowsNoEntriesEvenWithAQuery() throws {
        let session = open(try makeSession())
        let model = makeModel()
        model.query = "Twitter"

        XCTAssertEqual(model.content, .locked(databaseName: session.databaseReference.displayName))
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedResult)
    }

    func testUnlockedSessionSearchesWithTheMainSearchRules() async throws {
        let session = open(try await makeUnlockedSession())
        let model = makeModel()

        XCTAssertTrue(model.results.isEmpty, "An empty query lists nothing")

        model.query = "  TWITTER "
        XCTAssertEqual(model.results.map(\.entry.title), ["Twitter"])
        XCTAssertEqual(model.results.map(\.databaseID), [session.databaseReference.id])
        XCTAssertEqual(model.username(for: try XCTUnwrap(model.results.first)), "testuser")
        XCTAssertEqual(model.folderPath(for: try XCTUnwrap(model.results.first)), "Social")
    }

    func testQuickSearchDoesNotMoveTheMainWindowSearch() async throws {
        let session = open(try await makeUnlockedSession())
        let model = makeModel()

        model.query = "Twitter"

        XCTAssertEqual(session.searchText, "")
        XCTAssertTrue(session.searchResults.isEmpty)
    }

    func testLockingEmptiesAnOpenPanel() async throws {
        let session = open(try await makeUnlockedSession())
        let model = makeModel()
        model.query = "Twitter"
        XCTAssertFalse(model.results.isEmpty)

        session.lockRequest(force: true)

        XCTAssertEqual(model.content, .locked(databaseName: session.databaseReference.displayName))
        XCTAssertTrue(model.results.isEmpty)
    }

    func testResultsAreCappedAtTheResultLimit() async throws {
        let entries = (0..<(MacQuickSearchViewModel.resultLimit + 5)).map { KPEntry(title: "Bulk \($0)") }
        open(try await makeInjectedSession(rootGroup: KPGroup(name: "Root", groups: [KPGroup(name: "Bulk", entries: entries)])))
        let model = makeModel()

        model.query = "Bulk"

        XCTAssertEqual(model.results.count, MacQuickSearchViewModel.resultLimit)
    }

    // MARK: - Selection

    func testSelectionDefaultsToTheFirstResultAndClampsAtBothEnds() async throws {
        open(try await makeUnlockedSession())
        let model = makeModel()
        model.query = ".com"
        let results = model.results
        XCTAssertGreaterThan(results.count, 1)

        XCTAssertEqual(model.selectedResult?.id, results.first?.id)

        model.perform(.moveUp)
        XCTAssertEqual(model.selectedResult?.id, results.first?.id)

        model.perform(.moveDown)
        XCTAssertEqual(model.selectedResult?.id, results[1].id)

        for _ in results { model.perform(.moveDown) }
        XCTAssertEqual(model.selectedResult?.id, results.last?.id)
    }

    func testChangingTheQueryResetsTheSelection() async throws {
        open(try await makeUnlockedSession())
        let model = makeModel()
        model.query = ".com"
        model.perform(.moveDown)
        XCTAssertNotNil(model.selectedResultID)

        model.query = ".com "

        XCTAssertNil(model.selectedResultID)
    }

    func testMovingSelectionReadsTheLiveSessionOnceAtTheLastResult() async throws {
        let entries = (0..<MacQuickSearchViewModel.resultLimit).map { KPEntry(title: "Bulk \($0)") }
        let session = open(try await makeInjectedSession(rootGroup: KPGroup(name: "Root", entries: entries)))
        var sessionReads = 0
        let model = MacQuickSearchViewModel(focusedDatabaseID: { session.databaseReference.id }, sessionForDatabase: { _ in
            sessionReads += 1
            return session
        })
        model.query = "Bulk"
        let results = model.results
        model.selectedResultID = try XCTUnwrap(results.last).id
        sessionReads = 0

        model.moveSelection(by: -1)

        XCTAssertEqual(sessionReads, 1)
        XCTAssertEqual(model.selectedResultID, results[results.count - 2].id)
    }

    func testMovingSelectionWithAStaleIDStartsAtTheFirstResult() async throws {
        open(try await makeUnlockedSession())
        let model = makeModel()
        model.query = ".com"
        let results = model.results
        XCTAssertGreaterThan(results.count, 1)
        let staleID = MacQuickSearchViewModel.Result.ID(databaseID: try XCTUnwrap(results.first).databaseID, entryID: UUID())
        XCTAssertFalse(results.contains { $0.id == staleID })
        model.selectedResultID = staleID

        model.moveSelection(by: 1)

        XCTAssertEqual(model.selectedResultID, results[1].id)
        model.selectedResultID = staleID
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedResultID, results.first?.id)
    }

    func testPresentingClearsTheLastSearch() async throws {
        open(try await makeUnlockedSession())
        let model = makeModel()
        model.query = "Twitter"
        model.perform(.moveDown)
        let presentationID = model.presentationID

        model.prepareForPresentation()

        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.selectedResultID)
        XCTAssertEqual(model.presentationID, presentationID + 1)
    }

    // MARK: - Copying

    func testCopyingAPasswordRequiresDeviceOwnerAuthentication() async throws {
        open(try await makeUnlockedSession())
        let model = makeModel()
        let twitter = try entry(titled: "Twitter", in: model)

        let didCopy = await model.copy(.password, from: twitter)

        XCTAssertTrue(didCopy)
        XCTAssertEqual(authenticationRequests, 1)
        XCTAssertTrue(
            authenticationGates.first === sessions.first?.secretAccess,
            "The copy must be authorized by the session it reads from"
        )
        XCTAssertEqual(copied, ["twitterpass123"])
        XCTAssertEqual(copiedCallbacks, 1)
        XCTAssertEqual(abortedCopies, 0)
    }

    func testTheDeviceOwnerGateSkipsThePromptInsideTheGracePeriod() async {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()

        let isAuthorized = await MacQuickSearchViewModel.deviceOwnerGate(harness.gate)

        XCTAssertTrue(isAuthorized)
        XCTAssertTrue(harness.promptReasons.isEmpty)
    }

    func testTheDeviceOwnerGatePromptsOutsideTheGracePeriod() async {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        harness.gate.noteSuccessfulAuthentication()

        let isAuthorized = await MacQuickSearchViewModel.deviceOwnerGate(harness.gate)

        XCTAssertTrue(isAuthorized)
        XCTAssertEqual(harness.promptReasons.count, 1)
    }

    func testTheDeviceOwnerGateRefusesADeclinedPrompt() async {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.promptSucceeds = false

        let isAuthorized = await MacQuickSearchViewModel.deviceOwnerGate(harness.gate)

        XCTAssertFalse(isAuthorized)
        XCTAssertEqual(harness.promptReasons.count, 1)
    }

    func testDeclinedAuthenticationCopiesNothingAndHandsFocusBack() async throws {
        open(try await makeUnlockedSession())
        authenticationResult = false
        let model = makeModel()
        let twitter = try entry(titled: "Twitter", in: model)

        let didCopy = await model.copy(.password, from: twitter)

        XCTAssertFalse(didCopy)
        XCTAssertEqual(authenticationRequests, 1)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(copiedCallbacks, 0)
        XCTAssertEqual(abortedCopies, 1, "The prompt activated KeeForge, so the other app gets focus back")
    }

    func testALockDuringTheAuthenticationPromptCopiesNothingAndHandsFocusBack() async throws {
        let session = open(try await makeUnlockedSession())
        let model = MacQuickSearchViewModel(
            focusedDatabaseID: { session.databaseReference.id },
            sessionForDatabase: { _ in session },
            authenticateDeviceOwner: { _ in
                session.lockRequest(force: true)
                return true
            },
            copyToClipboard: { [weak self] in self?.copied.append($0) }
        )
        model.onCopied = { [weak self] in self?.copiedCallbacks += 1 }
        model.onCopyAborted = { [weak self] in self?.abortedCopies += 1 }
        let twitter = try entry(titled: "Twitter", in: model)

        let didCopy = await model.copy(.password, from: twitter)

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(copiedCallbacks, 0)
        XCTAssertEqual(abortedCopies, 1)
    }

    func testAnEntryDeletedDuringTheAuthenticationPromptCopiesNothingAndHandsFocusBack() async throws {
        let session = open(try await makeUnlockedSession())
        let twitterID = try XCTUnwrap(session.entries(matching: "Twitter").first { $0.title == "Twitter" }).id
        let model = MacQuickSearchViewModel(
            focusedDatabaseID: { session.databaseReference.id },
            sessionForDatabase: { _ in session },
            authenticateDeviceOwner: { _ in
                try? session.deleteEntry(twitterID, sendToRecycleBin: false)
                return true
            },
            copyToClipboard: { [weak self] in self?.copied.append($0) }
        )
        model.onCopyAborted = { [weak self] in self?.abortedCopies += 1 }
        let twitter = try entry(titled: "Twitter", in: model)

        let didCopy = await model.copy(.password, from: twitter)

        XCTAssertNil(session.entry(withID: twitterID), "The entry is gone, not just recycled")
        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 1)
    }

    func testReplacingTheSessionWithTheSameEntryIDsDuringAuthenticationCopiesNothing() async throws {
        open(try await makeUnlockedSession())
        let replacement = try await makeUnlockedSession()
        sessions.append(replacement)
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        XCTAssertNotNil(replacement.entry(withID: twitter.entry.id))
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        focusedDatabaseID = replacement.databaseReference.id
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 1)
    }

    func testLockingAndReunlockingTheSameSessionDuringAuthenticationCopiesNothing() async throws {
        let source = open(try await makeUnlockedSession())
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        source.lockRequest(force: true)
        await source.unlock(password: fixturePassword)
        XCTAssertEqual(source.state, .unlocked)
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 1)
    }

    func testEditingThePasswordDuringAuthenticationCopiesNothing() async throws {
        let source = open(try await makeUnlockedSession())
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        let form = EntryEditViewModel(editing: twitter.entry, sessionKey: try XCTUnwrap(source.sessionKey))
        form.password = "changed during authentication"
        try source.applyEntryEdit(.updateEntry(entryID: twitter.entry.id, draft: form.entryDraftPayload))
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 1)
    }

    func testANewPanelPresentationRejectsTheOldCopyWithoutClosingTheNewPanel() async throws {
        open(try await makeUnlockedSession())
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        model.prepareForPresentation()
        model.query = "GitHub"
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(copiedCallbacks, 0)
        XCTAssertEqual(abortedCopies, 0, "An older prompt must not dismiss the new presentation")
        XCTAssertEqual(model.query, "GitHub")
    }

    func testAuthenticationCanHideThePanelAndClearItsQueryBeforeCopying() async throws {
        let source = open(try await makeUnlockedSession())
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        // The native panel clears its query when authentication takes key focus.
        model.query = ""
        source.workspace.selectedEntryID = try XCTUnwrap(source.entries(matching: "GitHub").first).id
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertTrue(didCopy)
        XCTAssertNil(model.selectedResultID)
        XCTAssertEqual(copied, ["twitterpass123"])
        XCTAssertEqual(copiedCallbacks, 1)
        XCTAssertEqual(abortedCopies, 0)
    }

    func testUsernameAndVerificationCodeCopyWithoutAuthentication() async throws {
        let session = open(try await makeUnlockedSession())
        let model = makeModel()
        let discord = try entry(titled: "Discord", in: model)
        let config = try XCTUnwrap(discord.entry.totpConfig)
        let sessionKey = try XCTUnwrap(session.sessionKey)

        let copiedUsername = await model.copy(.username, from: discord)
        // Generated on either side of the copy, so a code rolling over in
        // between still matches one of them.
        let codeBefore = TOTPGenerator.generateCode(config: config, sessionKey: sessionKey)
        let copiedCode = await model.copy(.verificationCode, from: discord)
        let codeAfter = TOTPGenerator.generateCode(config: config, sessionKey: sessionKey)

        XCTAssertTrue(copiedUsername)
        XCTAssertTrue(copiedCode)
        XCTAssertEqual(authenticationRequests, 0)
        XCTAssertEqual(copied.count, 2)
        XCTAssertEqual(copied.first, "gamer123")
        XCTAssertTrue([codeBefore, codeAfter].contains(try XCTUnwrap(copied.last)))
    }

    func testAUsernameReferencingAPasswordShowsMaskedAndCopiesOnlyAfterAuthentication() async throws {
        let session = open(try await makeUnlockedSession())
        let entries = try XCTUnwrap(session.rootGroup?.allEntries)
        let discordEntry = try XCTUnwrap(entries.first { $0.title == "Discord" })
        let twitterEntry = try XCTUnwrap(entries.first { $0.title == "Twitter" })
        let form = EntryEditViewModel(editing: discordEntry, sessionKey: try XCTUnwrap(session.sessionKey))
        form.username = "{REF:P@I:\(twitterEntry.id.kdbxHexString)}"
        try session.applyEntryEdit(.updateEntry(entryID: discordEntry.id, draft: form.entryDraftPayload))
        let model = makeModel()
        let discord = try entry(titled: "Discord", in: model)

        XCTAssertEqual(model.username(for: discord), String(repeating: "\u{2022}", count: 12))
        authenticationResult = false
        let declined = await model.copy(.username, from: discord)
        XCTAssertFalse(declined)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(authenticationRequests, 1)

        authenticationResult = true
        let didCopy = await model.copy(.username, from: discord)
        XCTAssertTrue(didCopy)
        XCTAssertEqual(authenticationRequests, 2)
        XCTAssertEqual(copied, ["twitterpass123"])
    }

    func testFieldsAnEntryDoesNotHaveCannotBeCopied() async throws {
        open(try await makeUnlockedSession())
        let model = makeModel()
        let offlineKey = try entry(titled: "Offline Key", in: model)
        let publicProfile = try entry(titled: "Public Profile", in: model)

        XCTAssertFalse(model.canCopy(.username, from: offlineKey))
        XCTAssertFalse(model.canCopy(.verificationCode, from: offlineKey))
        XCTAssertFalse(model.canCopy(.password, from: publicProfile))
        let copiedMissingPassword = await model.copy(.password, from: publicProfile)
        XCTAssertFalse(copiedMissingPassword)
        XCTAssertEqual(authenticationRequests, 0, "No prompt for a field that is not there")
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 0, "Nothing activated KeeForge, so the panel stays open")
    }

    func testCopyingFromALockedSessionIsRefused() async throws {
        let session = open(try await makeUnlockedSession())
        let model = makeModel()
        let twitter = try entry(titled: "Twitter", in: model)
        session.lockRequest(force: true)

        let copiedUsername = await model.copy(.username, from: twitter)
        let copiedPassword = await model.copy(.password, from: twitter)

        XCTAssertFalse(copiedUsername)
        XCTAssertFalse(copiedPassword)
        XCTAssertEqual(authenticationRequests, 0)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 0)
    }

    // MARK: - Several open databases

    /// Two copies of one database share every entry UUID. Only the focused
    /// one is searched, and its results say which database they came from.
    func testOnlyTheFocusedOfTwoDatabasesWithTheSameEntriesIsSearched() async throws {
        let personal = try await makeUnlockedSession(nickname: "Personal")
        let work = open(try await makeUnlockedSession(nickname: "Work"))
        sessions.insert(personal, at: 0)
        let model = makeModel()
        model.query = "Twitter"

        XCTAssertEqual(model.content, .unlocked(databaseName: "Work"))
        XCTAssertEqual(model.results.map(\.databaseID), [work.databaseReference.id])

        focusedDatabaseID = personal.databaseReference.id

        XCTAssertEqual(model.content, .unlocked(databaseName: "Personal"))
        XCTAssertEqual(model.results.map(\.databaseID), [personal.databaseReference.id])
        XCTAssertEqual(model.results.map(\.entry.id), work.entries(matching: "Twitter").map(\.id))
    }

    func testAFocusChangeDropsTheSelectionMadeInTheOtherDatabase() async throws {
        let personal = try await makeUnlockedSession(nickname: "Personal")
        sessions.append(personal)
        let work = open(try await makeUnlockedSession(nickname: "Work"))
        let model = makeModel()
        model.query = ".com"
        model.perform(.moveDown)
        let selectedInWork = try XCTUnwrap(model.selectedResult)
        XCTAssertEqual(selectedInWork.databaseID, work.databaseReference.id)

        focusedDatabaseID = personal.databaseReference.id

        let selected = try XCTUnwrap(model.selectedResult)
        XCTAssertEqual(selected.databaseID, personal.databaseReference.id)
        XCTAssertEqual(selected.id, model.results.first?.id, "The same entry UUID in the other database is not selected")
    }

    /// The panel never falls back to another unlocked database.
    func testTheFocusedDatabaseLockingShowsItsLockedStateWhileTheOtherStaysUnlocked() async throws {
        let personal = try await makeUnlockedSession(nickname: "Personal")
        sessions.append(personal)
        let work = open(try await makeUnlockedSession(nickname: "Work"))
        let model = makeModel()
        model.query = "Twitter"
        XCTAssertFalse(model.results.isEmpty)

        work.lockRequest(force: true)

        XCTAssertEqual(personal.state, .unlocked)
        XCTAssertEqual(model.content, .locked(databaseName: "Work"))
        XCTAssertTrue(model.results.isEmpty)

        sessions.removeAll { $0 === work }

        XCTAssertEqual(model.content, .noDatabase, "A closed target is not replaced by the other database")
        XCTAssertTrue(model.results.isEmpty)
    }

    func testAFocusChangeDuringTheAuthenticationPromptCopiesNothing() async throws {
        let personal = try await makeUnlockedSession(nickname: "Personal")
        sessions.append(personal)
        open(try await makeUnlockedSession(nickname: "Work"))
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        focusedDatabaseID = personal.databaseReference.id
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 1)
    }

    /// A result rendered before the focus moved is not copied from the
    /// newly focused database, even though that one has the same entry.
    func testAResultFromADatabaseThatLostFocusIsNotCopied() async throws {
        let personal = try await makeUnlockedSession(nickname: "Personal")
        sessions.append(personal)
        open(try await makeUnlockedSession(nickname: "Work"))
        let model = makeModel()
        let twitter = try entry(titled: "Twitter", in: model)

        focusedDatabaseID = personal.databaseReference.id
        let copiedUsername = await model.copy(.username, from: twitter)
        let copiedPassword = await model.copy(.password, from: twitter)

        XCTAssertFalse(model.canCopy(.username, from: twitter))
        XCTAssertFalse(copiedUsername)
        XCTAssertFalse(copiedPassword)
        XCTAssertEqual(authenticationRequests, 0)
        XCTAssertTrue(copied.isEmpty)
    }

    // MARK: - Hand-offs to KeeForge

    func testOpenInKeeForgeSelectsTheEntryInItsGroup() async throws {
        let session = open(try await makeUnlockedSession())
        let model = makeModel()
        let github = try entry(titled: "GitHub", in: model)

        model.perform(.openInKeeForge)

        XCTAssertEqual(session.workspace.selectedEntryID, github.entry.id)
        XCTAssertEqual(session.workspace.selectedGroupID, session.parentGroupID(forEntryID: github.entry.id))
        XCTAssertEqual(shownDatabases, [session.databaseReference.id])
    }

    /// The entry is selected in the database it was found in, never in
    /// another open database that holds the same entry UUID.
    func testOpenInKeeForgeRoutesByTheResultsDatabase() async throws {
        let personal = try await makeUnlockedSession(nickname: "Personal")
        sessions.append(personal)
        let work = open(try await makeUnlockedSession(nickname: "Work"))
        let model = makeModel()
        let github = try entry(titled: "GitHub", in: model)
        let personalSelection = personal.workspace.selectedEntryID

        focusedDatabaseID = personal.databaseReference.id
        model.openInKeeForge(github)

        XCTAssertEqual(shownDatabases, [work.databaseReference.id])
        XCTAssertEqual(work.workspace.selectedEntryID, github.entry.id)
        XCTAssertEqual(personal.workspace.selectedEntryID, personalSelection)
    }

    func testOpenInKeeForgeSelectsNothingWhenNoWindowShowsTheDatabase() async throws {
        let session = open(try await makeUnlockedSession())
        showsDatabaseWindow = false
        let model = makeModel()
        let github = try entry(titled: "GitHub", in: model)
        let selectionBefore = session.workspace.selectedEntryID

        model.openInKeeForge(github)

        XCTAssertEqual(shownDatabases, [session.databaseReference.id])
        XCTAssertEqual(session.workspace.selectedEntryID, selectionBefore)
    }

    func testOpenInKeeForgeLeavesAnOpenEditorAlone() async throws {
        let session = open(try await makeUnlockedSession())
        let model = makeModel()
        let github = try entry(titled: "GitHub", in: model)
        session.setEditorHasUnsavedChanges(true, editorID: UUID())
        let selectionBefore = session.workspace.selectedEntryID

        model.openInKeeForge(github)

        XCTAssertEqual(session.workspace.selectedEntryID, selectionBefore)
        XCTAssertEqual(shownDatabases, [session.databaseReference.id], "The window still comes forward, showing the editor")
    }

    func testReturnWhileLockedFrontsThatDatabaseToUnlock() throws {
        let session = open(try makeSession())
        let model = makeModel()

        model.perform(.primaryAction)

        XCTAssertEqual(shownDatabases, [session.databaseReference.id])
        XCTAssertEqual(databaseListRequests, 0)
        XCTAssertTrue(copied.isEmpty)
    }

    func testReturnWhileLockedFallsBackToChoosingADatabaseWhenNoWindowShowsIt() throws {
        open(try makeSession())
        showsDatabaseWindow = false
        let model = makeModel()

        model.perform(.primaryAction)

        XCTAssertEqual(databaseListRequests, 1)
    }

    func testReturnWithoutADatabaseOpensKeeForgeToChooseOne() {
        let model = makeModel()

        model.perform(.primaryAction)

        XCTAssertTrue(shownDatabases.isEmpty)
        XCTAssertEqual(databaseListRequests, 1)
    }

    func testEscapeDismisses() {
        let model = makeModel()

        model.perform(.dismiss)

        XCTAssertEqual(dismissRequests, 1)
    }

    // MARK: - Helpers

    /// Opens `session` and focuses it.
    @discardableResult
    private func open(_ session: DatabaseViewModel) -> DatabaseViewModel {
        sessions.append(session)
        focusedDatabaseID = session.databaseReference.id
        return session
    }

    private func makeModel(
        authenticateDeviceOwner: MacQuickSearchViewModel.DeviceOwnerAuthenticator? = nil
    ) -> MacQuickSearchViewModel {
        let model = MacQuickSearchViewModel(
            focusedDatabaseID: { [weak self] in self?.focusedDatabaseID },
            sessionForDatabase: { [weak self] id in self?.sessions.first { $0.databaseReference.id == id } },
            authenticateDeviceOwner: authenticateDeviceOwner ?? { [weak self] gate in
                guard let self else { return false }
                self.authenticationRequests += 1
                self.authenticationGates.append(gate)
                return self.authenticationResult
            },
            copyToClipboard: { [weak self] in self?.copied.append($0) }
        )
        model.onCopied = { [weak self] in self?.copiedCallbacks += 1 }
        model.onCopyAborted = { [weak self] in self?.abortedCopies += 1 }
        model.onShowDatabase = { [weak self] id in
            guard let self else { return false }
            self.shownDatabases.append(id)
            return self.showsDatabaseWindow
        }
        model.onShowDatabaseList = { [weak self] in self?.databaseListRequests += 1 }
        model.onDismiss = { [weak self] in self?.dismissRequests += 1 }
        return model
    }

    @MainActor
    private final class SuspendedAuthentication {
        private var completion: CheckedContinuation<Bool, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func authenticate() async -> Bool {
            await withCheckedContinuation { continuation in
                completion = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilRequested() async {
            guard completion == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func complete() {
            completion?.resume(returning: true)
            completion = nil
        }
    }

    /// Searches for `title` and selects the one exact match.
    private func entry(titled title: String, in model: MacQuickSearchViewModel) throws -> MacQuickSearchViewModel.Result {
        model.query = title
        let match = try XCTUnwrap(model.results.first { $0.entry.title == title })
        model.selectedResultID = match.id
        return match
    }

    private func makeSession(nickname: String? = nil) throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        return DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url, nickname: nickname))
    }

    private func makeUnlockedSession(nickname: String? = nil) async throws -> DatabaseViewModel {
        let session = try makeSession(nickname: nickname)
        await session.unlock(password: fixturePassword)
        guard case .unlocked = session.state else {
            XCTFail("test.kdbx did not unlock")
            return session
        }
        return session
    }

    private func makeInjectedSession(rootGroup: KPGroup) async throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let session = DatabaseViewModel(
            databaseReference: try TestDatabaseSupport.makeReference(for: url),
            reloadOperation: { reference, _ in
                DatabaseViewModel.ReloadedDatabase(
                    reference: reference,
                    rootGroup: rootGroup,
                    meta: KPMeta(),
                    formatVersion: .kdbx4(minor: 1),
                    sessionKey: SymmetricKey(size: .bits256),
                    openTimeSHA512: Data("injected-tree-hash".utf8),
                    binaryPool: BinaryPool(rawFields: [])
                )
            }
        )
        await session.unlock(password: fixturePassword)
        try await session.reloadDiscardingDraft()
        return session
    }
}
#endif
