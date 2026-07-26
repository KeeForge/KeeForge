// Shared `CredentialProviderPresenting` recording spy for
// CredentialProviderCoordinatorTests.swift and CredentialProviderSaveTests.swift.
//
// Both suites previously hand-rolled their own conformance: the coordinator
// suite's `PresenterSpy` recorded every presentation/completion call, while
// the save suite's `SavePresenterSpy` was a no-op stub that only tracked
// `cancelRequest` calls (as `cancelledErrorCodes`, additively, since
// `prepareInterface(for:)` never presents anything itself). This type merges
// both: it records everything `PresenterSpy` did, using the exact same
// property names/shapes the coordinator suite already asserts against, and
// additionally accumulates every cancellation into `cancelledErrorCodes` for
// the save suite's assertions. Recording is purely additive — a caller that
// never inspects the recorded state (as the save-prepare tests don't) sees no
// behavioral difference from the old no-op stub.
import AuthenticationServices
import Foundation
@testable import KeeForge

@MainActor
final class CredentialProviderPresentingSpy: CredentialProviderPresenting {
    var isPresentationActive = false
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
        let databaseSwitcher: CredentialProviderDatabaseSwitcherContext?
        let onSelect: (KPEntry) -> Void
        let onCancel: () -> Void
    }

    struct NoEnabledDatabasesState {
        let onDismiss: () -> Void
    }

    var unlockPrompt: UnlockPrompt?
    var unlockError: UnlockError?
    var readOnlyNotice: ReadOnlyNotice?
    var searchView: SearchView?
    var noEnabledDatabasesState: NoEnabledDatabasesState?

    var completedCredential: ASPasswordCredential?
    var completedAssertion: ASPasskeyAssertionCredential?
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

    func presentSearchView(
        entries: [KPEntry],
        initialSearchText: String,
        databaseSwitcher: CredentialProviderDatabaseSwitcherContext?,
        onSelect: @escaping (KPEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        searchView = SearchView(
            entries: entries,
            initialSearchText: initialSearchText,
            databaseSwitcher: databaseSwitcher,
            onSelect: onSelect,
            onCancel: onCancel
        )
        onSearchViewPresented?()
    }

    func presentNoEnabledDatabasesState(onDismiss: @escaping () -> Void) {
        noEnabledDatabasesState = NoEnabledDatabasesState(onDismiss: onDismiss)
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
