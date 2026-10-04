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

    private var session: DatabaseViewModel?
    private var copied: [String] = []
    private var authenticationRequests = 0
    private var authenticationGates: [SecretAccessGate] = []
    private var authenticationResult = true
    private var copiedCallbacks = 0
    private var abortedCopies = 0
    private var mainWindowRequests = 0
    private var dismissRequests = 0

    override func setUp() async throws {
        try await super.setUp()
        session = nil
        copied = []
        authenticationRequests = 0
        authenticationGates = []
        authenticationResult = true
        copiedCallbacks = 0
        abortedCopies = 0
        mainWindowRequests = 0
        dismissRequests = 0
    }

    override func tearDown() async throws {
        session?.lockRequest(force: true)
        session = nil
        try await super.tearDown()
    }

    // MARK: - What the panel shows

    func testNoSessionAsksToChooseADatabase() {
        let model = makeModel()

        XCTAssertEqual(model.content, .noDatabase)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testLockedSessionShowsNoEntriesEvenWithAQuery() throws {
        session = try makeSession()
        let model = makeModel()
        model.query = "Twitter"

        XCTAssertEqual(model.content, .locked(databaseName: try XCTUnwrap(session).databaseReference.displayName))
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedEntry)
    }

    func testUnlockedSessionSearchesWithTheMainSearchRules() async throws {
        session = try await makeUnlockedSession()
        let model = makeModel()

        XCTAssertTrue(model.results.isEmpty, "An empty query lists nothing")

        model.query = "  TWITTER "
        XCTAssertEqual(model.results.map(\.title), ["Twitter"])
        XCTAssertEqual(model.username(for: try XCTUnwrap(model.results.first)), "testuser")
        XCTAssertEqual(model.folderPath(for: try XCTUnwrap(model.results.first)), "Social")
    }

    func testQuickSearchDoesNotMoveTheMainWindowSearch() async throws {
        let session = try await makeUnlockedSession()
        self.session = session
        let model = makeModel()

        model.query = "Twitter"

        XCTAssertEqual(session.searchText, "")
        XCTAssertTrue(session.searchResults.isEmpty)
    }

    func testLockingEmptiesAnOpenPanel() async throws {
        let session = try await makeUnlockedSession()
        self.session = session
        let model = makeModel()
        model.query = "Twitter"
        XCTAssertFalse(model.results.isEmpty)

        session.lockRequest(force: true)

        XCTAssertEqual(model.content, .locked(databaseName: session.databaseReference.displayName))
        XCTAssertTrue(model.results.isEmpty)
    }

    func testResultsAreCappedAtTheResultLimit() async throws {
        let entries = (0..<(MacQuickSearchViewModel.resultLimit + 5)).map { KPEntry(title: "Bulk \($0)") }
        session = try await makeInjectedSession(rootGroup: KPGroup(name: "Root", groups: [KPGroup(name: "Bulk", entries: entries)]))
        let model = makeModel()

        model.query = "Bulk"

        XCTAssertEqual(model.results.count, MacQuickSearchViewModel.resultLimit)
    }

    // MARK: - Selection

    func testSelectionDefaultsToTheFirstResultAndClampsAtBothEnds() async throws {
        session = try await makeUnlockedSession()
        let model = makeModel()
        model.query = ".com"
        let results = model.results
        XCTAssertGreaterThan(results.count, 1)

        XCTAssertEqual(model.selectedEntry?.id, results.first?.id)

        model.perform(.moveUp)
        XCTAssertEqual(model.selectedEntry?.id, results.first?.id)

        model.perform(.moveDown)
        XCTAssertEqual(model.selectedEntry?.id, results[1].id)

        for _ in results { model.perform(.moveDown) }
        XCTAssertEqual(model.selectedEntry?.id, results.last?.id)
    }

    func testChangingTheQueryResetsTheSelection() async throws {
        session = try await makeUnlockedSession()
        let model = makeModel()
        model.query = ".com"
        model.perform(.moveDown)
        XCTAssertNotNil(model.selectedEntryID)

        model.query = ".com "

        XCTAssertNil(model.selectedEntryID)
    }

    func testMovingSelectionReadsTheLiveSessionOnceAtTheLastResult() async throws {
        let entries = (0..<MacQuickSearchViewModel.resultLimit).map { KPEntry(title: "Bulk \($0)") }
        let session = try await makeInjectedSession(rootGroup: KPGroup(name: "Root", entries: entries))
        self.session = session
        var sessionReads = 0
        let model = MacQuickSearchViewModel(sessionProvider: {
            sessionReads += 1
            return session
        })
        model.query = "Bulk"
        let results = model.results
        model.selectedEntryID = try XCTUnwrap(results.last).id
        sessionReads = 0

        model.moveSelection(by: -1)

        XCTAssertEqual(sessionReads, 1)
        XCTAssertEqual(model.selectedEntryID, results[results.count - 2].id)
    }

    func testMovingSelectionWithAStaleIDStartsAtTheFirstResult() async throws {
        session = try await makeUnlockedSession()
        let model = makeModel()
        model.query = ".com"
        let results = model.results
        XCTAssertGreaterThan(results.count, 1)
        let staleID = UUID()
        XCTAssertFalse(results.contains { $0.id == staleID })
        model.selectedEntryID = staleID

        model.moveSelection(by: 1)

        XCTAssertEqual(model.selectedEntryID, results[1].id)
        model.selectedEntryID = staleID
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedEntryID, results.first?.id)
    }

    func testPresentingClearsTheLastSearch() async throws {
        session = try await makeUnlockedSession()
        let model = makeModel()
        model.query = "Twitter"
        model.perform(.moveDown)
        let presentationID = model.presentationID

        model.prepareForPresentation()

        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.selectedEntryID)
        XCTAssertEqual(model.presentationID, presentationID + 1)
    }

    // MARK: - Copying

    func testCopyingAPasswordRequiresDeviceOwnerAuthentication() async throws {
        session = try await makeUnlockedSession()
        let model = makeModel()
        let twitter = try entry(titled: "Twitter", in: model)

        let didCopy = await model.copy(.password, from: twitter)

        XCTAssertTrue(didCopy)
        XCTAssertEqual(authenticationRequests, 1)
        XCTAssertTrue(
            authenticationGates.first === session?.secretAccess,
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
        session = try await makeUnlockedSession()
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
        let session = try await makeUnlockedSession()
        self.session = session
        let model = MacQuickSearchViewModel(
            sessionProvider: { session },
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
        let session = try await makeUnlockedSession()
        self.session = session
        let twitterID = try XCTUnwrap(session.entries(matching: "Twitter").first { $0.title == "Twitter" }).id
        let model = MacQuickSearchViewModel(
            sessionProvider: { session },
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
        let source = try await makeUnlockedSession()
        defer { source.lockRequest(force: true) }
        session = source
        let replacement = try await makeUnlockedSession()
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        XCTAssertNotNil(replacement.entry(withID: twitter.id))
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        session = replacement
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 1)
    }

    func testLockingAndReunlockingTheSameSessionDuringAuthenticationCopiesNothing() async throws {
        let source = try await makeUnlockedSession()
        session = source
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
        let source = try await makeUnlockedSession()
        session = source
        let authentication = SuspendedAuthentication()
        let model = makeModel(authenticateDeviceOwner: { _ in await authentication.authenticate() })
        let twitter = try entry(titled: "Twitter", in: model)
        let copy = Task { await model.copy(.password, from: twitter) }
        await authentication.waitUntilRequested()

        let form = EntryEditViewModel(editing: twitter, sessionKey: try XCTUnwrap(source.sessionKey))
        form.password = "changed during authentication"
        try source.applyEntryEdit(.updateEntry(entryID: twitter.id, draft: form.entryDraftPayload))
        authentication.complete()
        let didCopy = await copy.value

        XCTAssertFalse(didCopy)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(abortedCopies, 1)
    }

    func testANewPanelPresentationRejectsTheOldCopyWithoutClosingTheNewPanel() async throws {
        session = try await makeUnlockedSession()
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
        let source = try await makeUnlockedSession()
        session = source
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
        XCTAssertNil(model.selectedEntryID)
        XCTAssertEqual(copied, ["twitterpass123"])
        XCTAssertEqual(copiedCallbacks, 1)
        XCTAssertEqual(abortedCopies, 0)
    }

    func testUsernameAndVerificationCodeCopyWithoutAuthentication() async throws {
        let session = try await makeUnlockedSession()
        self.session = session
        let model = makeModel()
        let discord = try entry(titled: "Discord", in: model)
        let config = try XCTUnwrap(discord.totpConfig)
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

    func testFieldsAnEntryDoesNotHaveCannotBeCopied() async throws {
        session = try await makeUnlockedSession()
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
        let session = try await makeUnlockedSession()
        self.session = session
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

    // MARK: - Hand-offs to the main window

    func testOpenInKeeForgeSelectsTheEntryInItsGroup() async throws {
        let session = try await makeUnlockedSession()
        self.session = session
        let model = makeModel()
        let github = try entry(titled: "GitHub", in: model)

        model.perform(.openInKeeForge)

        XCTAssertEqual(session.workspace.selectedEntryID, github.id)
        XCTAssertEqual(session.workspace.selectedGroupID, session.parentGroupID(forEntryID: github.id))
        XCTAssertEqual(mainWindowRequests, 1)
    }

    func testOpenInKeeForgeLeavesAnOpenEditorAlone() async throws {
        let session = try await makeUnlockedSession()
        self.session = session
        let model = makeModel()
        let github = try entry(titled: "GitHub", in: model)
        session.setEditorHasUnsavedChanges(true, editorID: UUID())
        let selectionBefore = session.workspace.selectedEntryID

        model.openInKeeForge(github)

        XCTAssertEqual(session.workspace.selectedEntryID, selectionBefore)
        XCTAssertEqual(mainWindowRequests, 1, "The window still comes forward, showing the editor")
    }

    func testReturnWhileLockedOpensTheMainWindowToUnlock() throws {
        session = try makeSession()
        let model = makeModel()

        model.perform(.primaryAction)

        XCTAssertEqual(mainWindowRequests, 1)
        XCTAssertTrue(copied.isEmpty)
    }

    func testReturnWithoutADatabaseOpensTheMainWindowToChooseOne() {
        let model = makeModel()

        model.perform(.primaryAction)

        XCTAssertEqual(mainWindowRequests, 1)
    }

    func testEscapeDismisses() {
        let model = makeModel()

        model.perform(.dismiss)

        XCTAssertEqual(dismissRequests, 1)
    }

    // MARK: - Helpers

    private func makeModel(
        authenticateDeviceOwner: MacQuickSearchViewModel.DeviceOwnerAuthenticator? = nil
    ) -> MacQuickSearchViewModel {
        let model = MacQuickSearchViewModel(
            sessionProvider: { [weak self] in self?.session },
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
        model.onShowMainWindow = { [weak self] in self?.mainWindowRequests += 1 }
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
    private func entry(titled title: String, in model: MacQuickSearchViewModel) throws -> KPEntry {
        model.query = title
        let match = try XCTUnwrap(model.results.first { $0.title == title })
        model.selectedEntryID = match.id
        return match
    }

    private func makeSession() throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        return DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url))
    }

    private func makeUnlockedSession() async throws -> DatabaseViewModel {
        let session = try makeSession()
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
                    meta: KPMeta(recycleBinUUID: nil, hasRecycleBinUUIDElement: false),
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
