#if os(macOS)
import AppKit
import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

/// Lifecycle tests for the macOS AutoFill presentation shell
/// (`CredentialProviderViewController` on macOS). These verify the two
/// completion paths that have no iOS analogue — window close / view
/// disappearance and `NSAlert` dismissal — both route back through the
/// coordinator's `cleanup()`. The shell's extension-context calls are captured
/// by a spy completer, and `NSAlert.runModal()` is bypassed by an injected
/// closure, so no system AutoFill harness is required.
@MainActor
final class CredentialProviderShellMacTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Window close / dismissal on a still-pending request must tear the vault
    /// down instead of leaking an unlocked session.
    func test_shellCancel_invokesCleanup() {
        let (shell, spy) = makeShell()
        seedUnlockedVaultState(shell.coordinator)

        // Simulates `viewDidDisappear` firing with no completion yet.
        shell.cancelActiveRequestIfNeeded()

        XCTAssertEqual(spy.cancelledError?.code, .userCanceled)
        assertCleanedUp(shell.coordinator)
    }

    /// A completed request must not be re-cancelled when the window later closes.
    func test_shellCancel_isNoOpAfterCompletion() {
        let (shell, spy) = makeShell()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try! EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )
        shell.coordinator.serviceIdentifiers = [serviceIdentifier()]
        seedUnlockedVaultState(shell.coordinator, entries: [entry], sessionKey: sessionKey)

        shell.coordinator.presentPasswordMatchesOrFinish()
        XCTAssertNotNil(spy.completedCredential, "single match should complete directly")

        // Window closes after the credential was already handed back.
        shell.cancelActiveRequestIfNeeded()

        XCTAssertNil(spy.cancelledError, "must not cancel a request that already completed")
    }

    /// Dismissing the read-only `NSAlert` must route through `cleanup()`.
    func test_alertDismissal_invokesCleanup() {
        let (shell, spy) = makeShell()
        // Bypass the real modal; simulate the user clicking the only button.
        shell.runModalAlert = { _ in .alertFirstButtonReturn }
        seedUnlockedVaultState(shell.coordinator)

        shell.coordinator.presentReadOnlyAlertAndCancel(message: "This database is read-only.")

        XCTAssertEqual(spy.cancelledError?.code, .userCanceled)
        assertCleanedUp(shell.coordinator)
    }

    /// Dismissing the unlock prompt with Cancel must route through `cleanup()`.
    func test_unlockPromptCancel_invokesCleanup() throws {
        let (shell, spy) = makeShell()
        // No biometric button configured, so Cancel is the second button.
        shell.runModalAlert = { _ in .alertSecondButtonReturn }
        seedUnlockedVaultState(shell.coordinator)
        // Since slice 03 an empty registry presents the no-enabled-databases
        // empty state instead of the unlock prompt, so a resolvable default
        // database must exist for the prompt (and its Cancel) to appear.
        try seedResolvableDefaultDatabase()

        shell.coordinator.prepareCredentialList(for: [serviceIdentifier()])
        shell.coordinator.presentationDidBecomeActive()

        XCTAssertEqual(spy.cancelledError?.code, .userCanceled)
        assertCleanedUp(shell.coordinator)
    }

    /// Passkey registration has no macOS creator UI; the shell must answer the
    /// request immediately with `.userCanceled` instead of leaving it pending.
    func test_passkeyRegistration_cancelsImmediately() {
        let (shell, spy) = makeShell()

        let identity = ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: "example.com",
            userName: "alice@example.com",
            credentialID: Data(),
            userHandle: Data("user-handle".utf8),
            recordIdentifier: nil
        )
        let request = ASPasskeyCredentialRequest(
            credentialIdentity: identity,
            clientDataHash: Data(repeating: 7, count: 32),
            userVerificationPreference: .preferred,
            supportedAlgorithms: [.ES256]
        )

        shell.prepareInterface(forPasskeyRegistration: request)

        XCTAssertEqual(spy.cancelledError?.code, .userCanceled)

        // The window closing afterwards must not double-cancel.
        spy.cancelledError = nil
        shell.cancelActiveRequestIfNeeded()
        XCTAssertNil(spy.cancelledError)
    }

    // MARK: - Helpers

    @MainActor
    private final class CompleterSpy: CredentialProviderRequestCompleting {
        var completedCredential: ASPasswordCredential?
        var completedAssertion: ASPasskeyAssertionCredential?
        var completedOneTimeCode: String?
        var cancelledError: ASExtensionError?

        func completeRequest(withSelectedCredential credential: ASPasswordCredential) {
            completedCredential = credential
        }

        func completeAssertionRequest(using credential: ASPasskeyAssertionCredential) {
            completedAssertion = credential
        }

        func completeOneTimeCode(code: String) {
            completedOneTimeCode = code
        }

        func cancelRequest(withError error: ASExtensionError) {
            cancelledError = error
        }
    }

    private func makeShell() -> (CredentialProviderViewController, CompleterSpy) {
        let shell = CredentialProviderViewController(nibName: nil, bundle: nil)
        let spy = CompleterSpy()
        shell.requestCompleter = spy
        return (shell, spy)
    }

    private func serviceIdentifier() -> ASCredentialServiceIdentifier {
        ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)
    }

    /// Registers an AutoFill-enabled database and points the active pointer at
    /// it so identifier-less interactive flows resolve a default database
    /// (mirrors the iOS coordinator suite's helper of the same name).
    private func seedResolvableDefaultDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("default.kdbx")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("fixture".utf8).write(to: url)
        let reference = try TestDatabaseSupport.makeReference(for: url)
        DatabaseListStore.update(reference)
        DatabaseListStore.activeAutoFillDatabaseID = reference.id
    }

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
        XCTAssertNil(coordinator.activeDatabaseReference, "active database reference must be cleared", file: file, line: line)
    }
}

#endif
