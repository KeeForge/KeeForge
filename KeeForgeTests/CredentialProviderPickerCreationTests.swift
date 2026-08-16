// Covers the picker-initiated entry creation route (issue #46): when the
// credential picker offers a create action, what the creator is prefilled
// with, and that saving fills the form instead of completing a save-password
// request. The save mechanics themselves live in CredentialProviderSaveTests.
import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class CredentialProviderPickerCreationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    // MARK: - When the picker offers creation

    func test_passwordPicker_writableDatabase_offersEntryCreation() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView)
        #if os(iOS)
        XCTAssertNotNil(searchView.onCreateEntry, "A writable database must offer entry creation")
        #else
        XCTAssertNil(searchView.onCreateEntry, "Entry creation is iOS-only")
        #endif
    }

    func test_passwordPicker_readOnlyDatabase_hidesEntryCreation() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference(isReadOnly: true))

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView)
        XCTAssertNil(searchView.onCreateEntry, "A read-only database must not offer entry creation")
    }

    func test_passwordPicker_legacyKDBX31_hidesEntryCreation() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())
        coordinator.parsedFormatVersion = .kdbx3_1

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView)
        XCTAssertNil(
            searchView.onCreateEntry,
            "KDBX 3.1 is read-only in KeeForge, so creation must not be offered"
        )
    }

    func test_passwordPicker_noServiceIdentifier_hidesEntryCreation() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())
        coordinator.serviceIdentifiers = []

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView)
        XCTAssertNil(
            searchView.onCreateEntry,
            "Without a service identifier there is nothing to prefill the entry from"
        )
    }

    // `AutoFillEntryCreatorView` and the creation route are `#if os(iOS)`, so
    // everything below is unreachable in the `KeeForgeMacTests` build.
#if os(iOS)

    // MARK: - What the creator is prefilled with

    func test_createEntryAction_presentsCreatorPrefilledFromServiceIdentifier() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())

        coordinator.presentPasswordMatchesOrFinish()
        let createEntry = try XCTUnwrap(presenter.searchView?.onCreateEntry)
        createEntry()

        let creator = try XCTUnwrap(presenter.entryCreator)
        XCTAssertTrue(
            creator.allowsPasswordEditing,
            "The account does not exist yet, so its password must be editable and generatable"
        )
        XCTAssertEqual(creator.initialDraft.title, "github.com")
        XCTAssertEqual(creator.initialDraft.url, "github.com")
        XCTAssertTrue(creator.initialDraft.username.isEmpty)
        XCTAssertFalse(
            creator.initialDraft.password.isEmpty,
            "The draft must arrive with a generated password"
        )
    }

    func test_createEntryAction_cancel_cancelsRequestAndCleansUp() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())

        coordinator.presentPasswordMatchesOrFinish()
        try XCTUnwrap(presenter.searchView?.onCreateEntry)()
        try XCTUnwrap(presenter.entryCreator).onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        XCTAssertNil(coordinator.sessionKey, "Cancelling must tear the vault down")
    }

    // MARK: - Saving fills the form

    func test_saveFromCreator_missingTitleAndUsername_showsErrorWithoutCompleting() async throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())

        coordinator.presentPasswordMatchesOrFinish()
        try XCTUnwrap(presenter.searchView?.onCreateEntry)()
        let creator = try XCTUnwrap(presenter.entryCreator)

        let outcome = await creator.onSave(
            EntryDraftPayload(title: "", username: "", password: "secret", url: "github.com")
        )

        guard case .showError(let message) = outcome else {
            return XCTFail("Expected an error outcome, got \(outcome)")
        }
        XCTAssertEqual(message, String(localized: "Enter a title or username for this credential."))
        XCTAssertNil(presenter.completedCredential, "Nothing may be filled without a user")
        XCTAssertFalse(presenter.didCompleteSavePassword)
    }

    /// The picker route unlocks the password field, so the generated value can
    /// be cleared. An empty password would persist an entry `hasPassword`
    /// rejects — never published to AutoFill — and fill the form with nothing.
    func test_saveFromCreator_emptyPassword_showsErrorWithoutSavingOrFilling() async throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())

        coordinator.presentPasswordMatchesOrFinish()
        try XCTUnwrap(presenter.searchView?.onCreateEntry)()
        let creator = try XCTUnwrap(presenter.entryCreator)

        let outcome = await creator.onSave(
            EntryDraftPayload(title: "GitHub", username: "octocat", password: "", url: "github.com")
        )

        // The specific message matters: a bare `.showError` would also match a
        // save that failed for unrelated reasons, which is what this seeded
        // vault does anyway, and the test would pass with the guard removed.
        guard case .showError(let message) = outcome else {
            return XCTFail("Expected an error outcome, got \(outcome)")
        }
        XCTAssertEqual(message, String(localized: "Enter a password for this credential."))
        XCTAssertNil(presenter.completedCredential, "An empty password must not be filled")
        XCTAssertFalse(presenter.didCompleteSavePassword)
        XCTAssertNotNil(coordinator.sessionKey, "The vault must stay open so the user can correct the draft")
    }

    func test_saveFromCreator_missingVaultState_showsErrorWithoutCompleting() async throws {
        let (coordinator, presenter) = makeCoordinator()
        seedPickerState(coordinator, reference: makeLocalReference())

        coordinator.presentPasswordMatchesOrFinish()
        try XCTUnwrap(presenter.searchView?.onCreateEntry)()
        let creator = try XCTUnwrap(presenter.entryCreator)

        // The vault is torn down (e.g. a cancelled sibling flow) before save.
        coordinator.sessionKey = nil

        let outcome = await creator.onSave(
            EntryDraftPayload(title: "GitHub", username: "octocat", password: "secret", url: "github.com")
        )

        guard case .showError = outcome else {
            return XCTFail("Expected an error outcome, got \(outcome)")
        }
        XCTAssertNil(presenter.completedCredential)
    }
#endif

    // MARK: - Helpers

    private func makeCoordinator() -> (CredentialProviderCoordinator, CredentialProviderPresentingSpy) {
        let presenter = CredentialProviderPresentingSpy()
        let coordinator = CredentialProviderCoordinator(presenter: presenter)
        return (coordinator, presenter)
    }

    /// Unlocked vault with no entry matching `github.com`, so
    /// `presentPasswordMatchesOrFinish` lands in the picker rather than
    /// auto-filling a single strict match.
    private func seedPickerState(
        _ coordinator: CredentialProviderCoordinator,
        reference: DatabaseReference
    ) {
        DatabaseListStore.update(reference)
        coordinator.activeDatabaseReference = reference
        coordinator.serviceIdentifiers = [
            ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)
        ]
        coordinator.parsedEntries = []
        coordinator.parsedRootGroup = KPGroup(name: "Root", groups: [KPGroup(name: "MyDatabase")])
        coordinator.parsedMeta = KPMeta()
        coordinator.parsedFormatVersion = .kdbx4(minor: 0)
        coordinator.sessionKey = SymmetricKey(size: .bits256)
        coordinator.compositeKey = SymmetricKey(data: Data("composite-key".utf8))
        coordinator.openTimeSHA512 = Data("open-sha".utf8)
    }

    private func makeLocalReference(
        id: UUID = UUID(),
        isReadOnly: Bool = false,
        autoFillEnabled: Bool = true
    ) -> DatabaseReference {
        DatabaseReference(
            id: id,
            nickname: nil,
            filename: "local.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: isReadOnly,
            autoFillEnabled: autoFillEnabled
        )
    }
}
