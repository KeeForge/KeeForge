// Runs on both iOS and macOS: slice 05 gave CredentialProviderCoordinator
// macOS target membership. The coordinator's save/generate-password paths are
// `#if os(iOS)` (those AuthenticationServices types are `API_UNAVAILABLE(macos)`);
// one-time-code paths are gated `macOS 15.0`. Individual tests below platform-gate
// only where the underlying API is genuinely unavailable.
import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

/// Verifies that `CredentialProviderCoordinator.cleanup()` — the extension's
/// only "lock" — runs on every completion path: success, user cancel, error
/// alert dismissal, and extension-context cancellation.
@MainActor
final class CredentialProviderCoordinatorTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    // MARK: - Required cleanup-path tests

    func test_cleanup_runsOnCancel() throws {
        let (coordinator, presenter) = makeCoordinator()

        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        coordinator.presentationDidBecomeActive()

        let prompt = try XCTUnwrap(presenter.unlockPrompt, "Unlock prompt should be requested")
        // Simulate an unlocked vault that must be torn down on cancel.
        seedUnlockedVaultState(coordinator)

        prompt.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnError() async throws {
        let (coordinator, presenter) = makeCoordinator()

        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        coordinator.presentationDidBecomeActive()

        let prompt = try XCTUnwrap(presenter.unlockPrompt, "Unlock prompt should be requested")
        // Simulate stale vault state that must be torn down when the user
        // dismisses the error alert.
        seedUnlockedVaultState(coordinator)

        let errorPresented = expectation(description: "unlock error presented")
        presenter.onUnlockErrorPresented = { errorPresented.fulfill() }

        // No active AutoFill database is configured, so unlocking fails.
        prompt.onSubmitPassword("wrong-password")
        await fulfillment(of: [errorPresented], timeout: 10)

        let unlockError = try XCTUnwrap(presenter.unlockError)
        XCTAssertNotNil(coordinator.sessionKey, "State should survive until the error alert is dismissed")

        unlockError.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnSuccessfulCompletion() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        var sessionKeyWasNilAtCompletion = false
        presenter.onCompleteRequest = { _ in
            sessionKeyWasNilAtCompletion = coordinator.sessionKey == nil
        }

        coordinator.presentPasswordMatchesOrFinish()

        let credential = try XCTUnwrap(presenter.completedCredential)
        XCTAssertEqual(credential.user, "octocat")
        XCTAssertEqual(credential.password, "hunter2")
        XCTAssertTrue(
            sessionKeyWasNilAtCompletion,
            "cleanup() must run before the credential is handed to the shell"
        )
        assertCleanedUp(coordinator)
    }

    // MARK: - Additional cleanup paths the pre-existing suite did not cover

    func test_cleanup_runsOnSearchViewCancel() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = [
            KPEntry(
                title: "GitHub",
                username: "octocat",
                password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
                url: "https://github.com/login"
            ),
            KPEntry(
                title: "GitHub Work",
                username: "worktocat",
                password: try EncryptedValue.encrypt("hunter3", using: sessionKey),
                url: "https://github.com/enterprise"
            ),
        ]

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView, "Multiple matches should present the search view")
        XCTAssertEqual(searchView.entries.count, 2)

        searchView.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnReadOnlyNoticeDismissal() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedUnlockedVaultState(coordinator)

        coordinator.presentReadOnlyAlertAndCancel(message: "This database is read-only.")

        let notice = try XCTUnwrap(presenter.readOnlyNotice)
        XCTAssertEqual(notice.message, "This database is read-only.")

        notice.onAcknowledge()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnExtensionConfigurationCancellation() {
        let (coordinator, presenter) = makeCoordinator()
        seedUnlockedVaultState(coordinator)

        coordinator.prepareInterfaceForExtensionConfiguration()

        XCTAssertEqual(presenter.cancelledError?.code, .failed)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnOneTimeCodeCompletion() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(
            title: "TOTP Entry",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )

        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        coordinator.completeOTCRequest(with: entry)

        let code = try XCTUnwrap(presenter.completedOneTimeCode)
        XCTAssertEqual(code.count, 6)
        XCTAssertNotEqual(code, "------")
        assertCleanedUp(coordinator)
    }

    // MARK: - One-time-code list requests (issue #20)

    func test_otcList_singleMatch_completesWithCode() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let matching = KPEntry(
            title: "GitHub",
            url: "https://github.com/login",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )
        let other = KPEntry(
            title: "Example",
            url: "https://example.com",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        XCTAssertTrue(coordinator.hasPendingOTCListRequest, "List request must be recorded for post-unlock handling")
        seedUnlockedVaultState(coordinator, entries: [matching, other], sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        let code = try XCTUnwrap(presenter.completedOneTimeCode, "A single service match should complete without a picker")
        XCTAssertEqual(code.count, 6)
        XCTAssertNotEqual(code, "------")
        assertCleanedUp(coordinator)
    }

    func test_otcList_multipleMatches_presentsPickerAndCompletesOnSelection() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try ["GitHub", "GitHub Work"].map { title in
            KPEntry(
                title: title,
                url: "https://github.com/login",
                totpConfig: TOTPConfig(
                    secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
                )
            )
        }

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView, "Multiple matches should present the picker")
        XCTAssertEqual(searchView.entries.count, 2)
        XCTAssertEqual(searchView.initialSearchText, "")

        searchView.onSelect(entries[0])

        let code = try XCTUnwrap(presenter.completedOneTimeCode)
        XCTAssertEqual(code.count, 6)
        assertCleanedUp(coordinator)
    }

    func test_otcList_noMatches_presentsAllTOTPEntriesWithDomainPrefilled() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let totpEntry = KPEntry(
            title: "Example",
            url: "https://example.com",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )
        let passwordOnlyEntry = KPEntry(
            title: "No TOTP",
            username: "user",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        seedUnlockedVaultState(coordinator, entries: [totpEntry, passwordOnlyEntry], sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView, "No matches should still present the full TOTP list")
        XCTAssertEqual(searchView.entries.map(\.title), ["Example"], "Only TOTP-capable entries belong in the OTC picker")
        XCTAssertEqual(searchView.initialSearchText, "github.com")

        searchView.onSelect(totpEntry)

        XCTAssertNotNil(presenter.completedOneTimeCode)
        assertCleanedUp(coordinator)
    }

    func test_otcList_noTOTPEntries_cancelsWithCredentialIdentityNotFound() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let passwordOnlyEntry = KPEntry(
            title: "No TOTP",
            username: "user",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        seedUnlockedVaultState(coordinator, entries: [passwordOnlyEntry], sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        XCTAssertEqual(presenter.cancelledError?.code, .credentialIdentityNotFound)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnPasskeyAssertionCompletion() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let privateKey = P256.Signing.PrivateKey()
        let entry = KPEntry(
            title: "Passkey Entry",
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                PasskeyCredential.privateKeyPEMKey: pemEncode(privateKey),
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
            ]
        )

        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        try coordinator.completePasskeyRequest(
            with: entry,
            relyingPartyID: "example.com",
            clientDataHash: Data(repeating: 7, count: 32)
        )

        let credential = try XCTUnwrap(presenter.completedAssertion)
        XCTAssertEqual(credential.relyingParty, "example.com")
        assertCleanedUp(coordinator)
    }

    // MARK: - Helpers

    @MainActor
    private final class PresenterSpy: CredentialProviderPresenting {
        var isDisplayingContent = false

        struct UnlockPrompt {
            let biometricOptionTitle: String?
            let onSubmitPassword: (String?) -> Void
            let onChooseBiometrics: () -> Void
            let onCancel: () -> Void
        }

        struct UnlockError {
            let message: String
            let onRetry: () -> Void
            let onCancel: () -> Void
        }

        struct ReadOnlyNotice {
            let message: String
            let onAcknowledge: () -> Void
        }

        struct SearchView {
            let entries: [KPEntry]
            let initialSearchText: String
            let onSelect: (KPEntry) -> Void
            let onCancel: () -> Void
        }

        var unlockPrompt: UnlockPrompt?
        var unlockError: UnlockError?
        var readOnlyNotice: ReadOnlyNotice?
        var searchView: SearchView?

        var completedCredential: ASPasswordCredential?
        var completedAssertion: ASPasskeyAssertionCredential?
        var completedOneTimeCode: String?
        var didCompleteSavePassword = false
        var completedGeneratedPasswords: [String]?
        var cancelledError: ASExtensionError?

        var onUnlockErrorPresented: (() -> Void)?
        var onCompleteRequest: ((ASPasswordCredential) -> Void)?

        func presentSearchView(
            entries: [KPEntry],
            initialSearchText: String,
            onSelect: @escaping (KPEntry) -> Void,
            onCancel: @escaping () -> Void
        ) {
            searchView = SearchView(
                entries: entries,
                initialSearchText: initialSearchText,
                onSelect: onSelect,
                onCancel: onCancel
            )
        }

        func presentEntryCreator(
            initialDraft: EntryDraftPayload,
            onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
            onCancel: @escaping () -> Void
        ) {}

        func presentUnlockPrompt(
            biometricOptionTitle: String?,
            onSubmitPassword: @escaping (String?) -> Void,
            onChooseBiometrics: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            unlockPrompt = UnlockPrompt(
                biometricOptionTitle: biometricOptionTitle,
                onSubmitPassword: onSubmitPassword,
                onChooseBiometrics: onChooseBiometrics,
                onCancel: onCancel
            )
        }

        func presentUnlockError(
            message: String,
            onRetry: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            unlockError = UnlockError(message: message, onRetry: onRetry, onCancel: onCancel)
            onUnlockErrorPresented?()
        }

        func presentReadOnlyNotice(
            message: String,
            onAcknowledge: @escaping () -> Void
        ) {
            readOnlyNotice = ReadOnlyNotice(message: message, onAcknowledge: onAcknowledge)
        }

        func presentGeneratedPassword(
            _ password: String,
            onUse: @escaping () -> Void,
            onRegenerate: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {}

        func completeRequest(withSelectedCredential credential: ASPasswordCredential) {
            onCompleteRequest?(credential)
            completedCredential = credential
        }

        func completeAssertionRequest(using credential: ASPasskeyAssertionCredential) {
            completedAssertion = credential
        }

        func completeOneTimeCodeRequest(code: String) {
            completedOneTimeCode = code
        }

        func completeSavePasswordRequest() {
            didCompleteSavePassword = true
        }

        func completeGeneratePasswordRequest(passwords: [String]) {
            completedGeneratedPasswords = passwords
        }

        func cancelRequest(withError error: ASExtensionError) {
            cancelledError = error
        }
    }

    private func makeCoordinator() -> (CredentialProviderCoordinator, PresenterSpy) {
        let presenter = PresenterSpy()
        let coordinator = CredentialProviderCoordinator(presenter: presenter)
        return (coordinator, presenter)
    }

    private func githubServiceIdentifier() -> ASCredentialServiceIdentifier {
        ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)
    }

    /// Seed the coordinator with state equivalent to an unlocked vault so that
    /// teardown is observable.
    private func seedUnlockedVaultState(
        _ coordinator: CredentialProviderCoordinator,
        entries: [KPEntry] = [],
        sessionKey: SymmetricKey = SymmetricKey(size: .bits256)
    ) {
        coordinator.parsedEntries = entries
        coordinator.parsedRootGroup = KPGroup(name: "Root")
        coordinator.parsedMeta = KPMeta()
        coordinator.sessionKey = sessionKey
        coordinator.compositeKey = Data("composite-key".utf8)
        coordinator.openTimeSHA512 = Data("open-sha".utf8)
    }

    private func assertCleanedUp(
        _ coordinator: CredentialProviderCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(coordinator.sessionKey, "session key must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.compositeKey, "composite key must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.openTimeSHA512, "open-time hash must be cleared", file: file, line: line)
        XCTAssertTrue(coordinator.parsedEntries.isEmpty, "parsed entries must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.parsedRootGroup, "parsed root group must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.parsedMeta, "parsed meta must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.parsedFormatVersion, "parsed format version must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.activeDatabaseReference, "active database reference must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.targetRecordIdentifier, "target record identifier must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingPasskeyRequest, "pending passkey request must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingPasskeyRequestParameters, "pending passkey parameters must be cleared", file: file, line: line)
        XCTAssertFalse(coordinator.hasPendingOTCRequest, "pending OTC flag must be cleared", file: file, line: line)
        XCTAssertFalse(coordinator.hasPendingOTCListRequest, "pending OTC list flag must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingReadOnlyCancellationMessage, "pending read-only message must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingSavePasswordRequestStorage, "pending save request must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingGeneratePasswordsRequestStorage, "pending generate request must be cleared", file: file, line: line)
    }

    /// Encode a P256 private key as PKCS#8 PEM (same shape the passkey
    /// importer produces).
    private func pemEncode(_ key: P256.Signing.PrivateKey) -> String {
        let derData = key.derRepresentation
        let base64 = derData.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----"
    }
}
