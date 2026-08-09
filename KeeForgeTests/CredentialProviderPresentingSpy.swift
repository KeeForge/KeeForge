// Shared `CredentialProviderPresenting` recording spy for
// CredentialProviderCoordinatorTests.swift and CredentialProviderSaveTests.swift.
// Recording is purely additive, so a suite that inspects none of it behaves as
// against a no-op stub.
import AuthenticationServices
import Foundation
@testable import KeeForge

@MainActor
final class CredentialProviderPresentingSpy: CredentialProviderPresenting {
    /// On-screen by default; tests that pin off-screen behavior set it false.
    var isPresentationActive = true
    var isDisplayingContent = false
    /// Set false to simulate UIKit refusing a modal despite an active shell.
    var didAttachPresentedContent = true

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
        let searchEntries: [KPEntry]
        let possibleEntries: [KPEntry]
        let initialSearchText: String
        let databaseSwitcher: CredentialProviderDatabaseSwitcherContext?
        let onCreateEntry: (() -> Void)?
        let onSelect: (KPEntry) -> Void
        let onSelectPossible: (KPEntry) -> Void
        let onAddURLToPossible: (KPEntry) -> Void
        let onCancel: () -> Void
    }

    struct EntryCreator {
        let initialDraft: EntryDraftPayload
        let allowsPasswordEditing: Bool
        let onSave: @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome
        let onCancel: () -> Void
    }

    struct NoEnabledDatabasesState {
        let onDismiss: () -> Void
    }

    struct PasskeyCreator {
        let context: CredentialProviderPasskeyCreatorContext
        let onSave: @Sendable (String) async -> CredentialProviderEntrySaveOutcome
        let onCancel: () -> Void
    }

    struct PasskeyRegistrationFailure {
        let message: String
        let onAcknowledge: () -> Void
    }

    var unlockPrompt: UnlockPrompt?
    var unlockError: UnlockError?
    var readOnlyNotice: ReadOnlyNotice?
    var searchView: SearchView?
    var entryCreator: EntryCreator?
    var noEnabledDatabasesState: NoEnabledDatabasesState?
    var passkeyCreator: PasskeyCreator?
    var passkeyRegistrationFailure: PasskeyRegistrationFailure?

    var completedCredential: ASPasswordCredential?
    var completedAssertion: ASPasskeyAssertionCredential?
    var completedRegistration: ASPasskeyRegistrationCredential?
    var completedOneTimeCode: String?
    var didCompleteSavePassword = false
    var completedGeneratedPasswords: [String]?
    /// The most recent `cancelRequest(withError:)` call, matching the
    /// original `PresenterSpy` semantics used throughout
    /// CredentialProviderCoordinatorTests.swift (last write wins; every test
    /// there triggers at most one cancellation before asserting).
    var cancelledError: ASExtensionError?
    /// Every `cancelRequest(withError:)` call's code, in order. Matches the
    /// original `SavePresenterSpy` semantics used by
    /// CredentialProviderSaveTests.swift's save-prepare tests, which only
    /// assert `cancelledErrorCodes.isEmpty`.
    private(set) var cancelledErrorCodes: [ASExtensionError.Code] = []

    var onUnlockErrorPresented: (() -> Void)?
    var onUnlockPromptPresented: (() -> Void)?
    var onCompleteRequest: ((ASPasswordCredential) -> Void)?
    /// Fired after every `presentSearchView` recording, mirroring
    /// `onUnlockErrorPresented` — lets async flows (a real unlock task)
    /// await the re-presented search with an expectation.
    var onSearchViewPresented: (() -> Void)?
    var onPasskeyCreatorPresented: (() -> Void)?
    var onEntryCreatorPresented: (() -> Void)?
    /// Fired before `completedRegistration` is recorded so ordering-sensitive
    /// tests can log the completion against other observed events.
    var onCompleteRegistrationRequest: ((ASPasskeyRegistrationCredential) -> Void)?

    func presentSearchView(
        entries: [KPEntry],
        searchEntries: [KPEntry],
        possibleEntries: [KPEntry],
        initialSearchText: String,
        databaseSwitcher: CredentialProviderDatabaseSwitcherContext?,
        onCreateEntry: (() -> Void)?,
        onSelect: @escaping (KPEntry) -> Void,
        onSelectPossible: @escaping (KPEntry) -> Void,
        onAddURLToPossible: @escaping (KPEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        searchView = SearchView(
            entries: entries,
            searchEntries: searchEntries,
            possibleEntries: possibleEntries,
            initialSearchText: initialSearchText,
            databaseSwitcher: databaseSwitcher,
            onCreateEntry: onCreateEntry,
            onSelect: onSelect,
            onSelectPossible: onSelectPossible,
            onAddURLToPossible: onAddURLToPossible,
            onCancel: onCancel
        )
        onSearchViewPresented?()
    }

    func presentNoEnabledDatabasesState(onDismiss: @escaping () -> Void) {
        noEnabledDatabasesState = NoEnabledDatabasesState(onDismiss: onDismiss)
    }

    func presentEntryCreator(
        initialDraft: EntryDraftPayload,
        allowsPasswordEditing: Bool,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    ) {
        entryCreator = EntryCreator(
            initialDraft: initialDraft,
            allowsPasswordEditing: allowsPasswordEditing,
            onSave: onSave,
            onCancel: onCancel
        )
        onEntryCreatorPresented?()
    }

    func presentPasskeyCreator(
        context: CredentialProviderPasskeyCreatorContext,
        onSave: @escaping @Sendable (String) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    ) {
        passkeyCreator = PasskeyCreator(context: context, onSave: onSave, onCancel: onCancel)
        onPasskeyCreatorPresented?()
    }

    func presentPasskeyRegistrationFailure(
        message: String,
        onAcknowledge: @escaping () -> Void
    ) {
        passkeyRegistrationFailure = PasskeyRegistrationFailure(message: message, onAcknowledge: onAcknowledge)
    }

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
        onUnlockPromptPresented?()
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

    func completeRegistrationRequest(using credential: ASPasskeyRegistrationCredential) {
        onCompleteRegistrationRequest?(credential)
        completedRegistration = credential
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
        cancelledErrorCodes.append(error.code)
    }
}
