#if os(iOS)
import AuthenticationServices
import SwiftUI
import UIKit

/// Thin iOS presentation shell for the AutoFill extension.
///
/// All request handling, vault/unlock orchestration, credential matching,
/// passkey assertion, and vault teardown live in
/// `CredentialProviderCoordinator`. This class only forwards system requests
/// to the coordinator, hosts the SwiftUI views (`AutoFillSearchView`,
/// `AutoFillEntryCreatorView`) in `UIHostingController`s, shows
/// `UIAlertController` prompts, and relays completions/cancellations to the
/// extension context.
@MainActor
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private lazy var coordinator = CredentialProviderCoordinator(presenter: self)
    private var hasAppeared = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        coordinator.presentationDidBecomeActive()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Internal full-screen presentations also make the provider disappear;
        // request cancellation belongs to the coordinator's terminal paths.
        hasAppeared = false
    }

    // MARK: - Request forwarding

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        coordinator.prepareCredentialList(for: serviceIdentifiers)
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        coordinator.prepareInterfaceToProvideCredential(for: credentialIdentity)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
        coordinator.prepareCredentialList(for: serviceIdentifiers, requestParameters: requestParameters)
    }

    @available(iOS 18.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        coordinator.prepareOneTimeCodeCredentialList(for: serviceIdentifiers)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        coordinator.prepareInterfaceToProvideCredential(for: credentialRequest)
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        coordinator.prepareInterface(forPasskeyRegistration: registrationRequest)
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        coordinator.provideCredentialWithoutUserInteraction(for: credentialRequest)
    }

    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        coordinator.provideCredentialWithoutUserInteraction(for: credentialIdentity)
    }

    override func prepareInterfaceForExtensionConfiguration() {
        coordinator.prepareInterfaceForExtensionConfiguration()
    }

    @available(iOS 26.2, *)
    override func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
        coordinator.performWithoutUserInteractionIfPossible(savePasswordRequest: savePasswordRequest)
    }

    @available(iOS 26.2, *)
    override func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
        coordinator.prepareInterface(for: savePasswordRequest)
    }

    @available(iOS 26.2, *)
    override func performWithoutUserInteraction(generatePasswordsRequest: ASGeneratePasswordsRequest) {
        coordinator.performWithoutUserInteraction(generatePasswordsRequest: generatePasswordsRequest)
    }

    @available(iOS 26.2, *)
    override func prepareInterface(for generatePasswordsRequest: ASGeneratePasswordsRequest) {
        coordinator.prepareInterface(for: generatePasswordsRequest)
    }
}

// MARK: - CredentialProviderPresenting

extension CredentialProviderViewController: CredentialProviderPresenting {
    var isPresentationActive: Bool {
        hasAppeared
    }

    var isDisplayingContent: Bool {
        presentedViewController != nil
    }

    // MARK: "Present this view"

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
        // A database switch presents the unlock prompt next, so the search
        // view must be dismissed first — wrap `onSwitch` in the same
        // dismissal handling as `onSelect`/`onCancel`.
        let wrappedSwitcher = databaseSwitcher.map { switcher in
            CredentialProviderDatabaseSwitcherContext(
                databases: switcher.databases,
                currentDatabaseID: switcher.currentDatabaseID,
                onSwitch: { [weak self] reference, currentSearchText in
                    guard let self else {
                        switcher.onSwitch(reference, currentSearchText)
                        return
                    }
                    self.dismiss(animated: false) {
                        switcher.onSwitch(reference, currentSearchText)
                    }
                }
            )
        }
        // Creating an entry presents the creator next, so the picker must be
        // dismissed first — same dismissal handling as `onSelect`/`onCancel`.
        let wrappedCreateEntry: (() -> Void)? = onCreateEntry.map { createEntry in
            { [weak self] in
                guard let self else {
                    createEntry()
                    return
                }
                self.dismiss(animated: false) { createEntry() }
            }
        }
        let searchView = AutoFillSearchView(
            entries: entries,
            searchEntries: searchEntries,
            possibleEntries: possibleEntries,
            initialSearchText: initialSearchText,
            databaseSwitcher: wrappedSwitcher,
            onCreateEntry: wrappedCreateEntry,
            onSelect: { [weak self] entry in
                guard let self else {
                    onSelect(entry)
                    return
                }
                self.dismiss(animated: false) { onSelect(entry) }
            },
            onSelectPossible: { [weak self] entry in
                self?.dismiss(animated: false) { onSelectPossible(entry) }
            },
            onAddURLToPossible: onAddURLToPossible,
            onCancel: { [weak self] in
                guard let self else {
                    onCancel()
                    return
                }
                self.dismiss(animated: false) { onCancel() }
            }
        )
        let host = UIHostingController(rootView: searchView)
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    func presentEntryCreator(
        initialDraft: EntryDraftPayload,
        allowsPasswordEditing: Bool,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    ) {
        let creatorView = AutoFillEntryCreatorView(
            initialDraft: initialDraft,
            allowsPasswordEditing: allowsPasswordEditing,
            onSave: { draftPayload in
                switch await onSave(draftPayload) {
                case .completed:
                    return .completed
                case .showWarningAndCancel(let message):
                    return .showWarningAndCancel(message)
                case .showError(let message):
                    return .showError(message)
                }
            },
            onCancel: { [weak self] in
                guard let self else {
                    onCancel()
                    return
                }
                self.dismiss(animated: false) { onCancel() }
            }
        )

        let host = UIHostingController(rootView: creatorView)
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    func presentPasskeyCreator(
        context: CredentialProviderPasskeyCreatorContext,
        onSave: @escaping @Sendable (String) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    ) {
        let creatorView = AutoFillPasskeyCreatorView(
            context: context,
            onSave: onSave,
            onCancel: { [weak self] in
                guard let self else {
                    onCancel()
                    return
                }
                self.dismiss(animated: false) { onCancel() }
            }
        )

        let host = UIHostingController(rootView: creatorView)
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    func presentNoEnabledDatabasesState(onDismiss: @escaping () -> Void) {
        let emptyStateView = AutoFillNoEnabledDatabasesView(
            onDismiss: { [weak self] in
                guard let self else {
                    onDismiss()
                    return
                }
                self.dismiss(animated: false) { onDismiss() }
            }
        )
        let host = UIHostingController(rootView: emptyStateView)
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    // MARK: "Ask this question"

    func presentUnlockPrompt(
        biometricOptionTitle: String?,
        onSubmitPassword: @escaping (String?) -> Void,
        onChooseBiometrics: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: String(localized: "Unlock KeeForge"),
            message: String(localized: "Enter your master password or use biometrics."),
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = String(localized: "Master Password")
            field.isSecureTextEntry = true
            field.textContentType = .password
        }

        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
            onCancel()
        })

        alert.addAction(UIAlertAction(title: String(localized: "Unlock"), style: .default) { [weak alert] _ in
            onSubmitPassword(alert?.textFields?.first?.text)
        })

        if let biometricOptionTitle {
            alert.addAction(UIAlertAction(title: biometricOptionTitle, style: .default) { _ in
                onChooseBiometrics()
            })
        }

        present(alert, animated: true)
    }

    func presentUnlockError(
        message: String,
        onRetry: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: String(localized: "Unlock Failed"),
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .default) { _ in
            onRetry()
        })

        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
            onCancel()
        })

        present(alert, animated: true)
    }

    func presentReadOnlyNotice(
        message: String,
        onAcknowledge: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: String(localized: "Read-only Database"),
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in
            onAcknowledge()
        })

        present(alert, animated: true)
    }

    func presentPasskeyRegistrationFailure(
        message: String,
        onAcknowledge: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: String(localized: "Couldn't Save Passkey"),
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in
            onAcknowledge()
        })

        present(alert, animated: true)
    }

    func presentGeneratedPassword(
        _ password: String,
        onUse: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: String(localized: "Generate Password"),
            message: password,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: String(localized: "Regenerate"), style: .default) { _ in
            onRegenerate()
        })

        alert.addAction(UIAlertAction(title: String(localized: "Use Password"), style: .default) { _ in
            onUse()
        })

        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
            onCancel()
        })

        present(alert, animated: true)
    }

    // MARK: "Complete with this credential/error"

    func completeRequest(withSelectedCredential credential: ASPasswordCredential) {
        extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
    }

    func completeAssertionRequest(using credential: ASPasskeyAssertionCredential) {
        extensionContext.completeAssertionRequest(using: credential)
    }

    func completeRegistrationRequest(using credential: ASPasskeyRegistrationCredential) {
        extensionContext.completeRegistrationRequest(using: credential)
    }

    func completeOneTimeCodeRequest(code: String) {
        guard #available(iOS 18.0, *) else {
            // Unreachable: one-time-code requests only exist on iOS 18+.
            extensionContext.cancelRequest(withError: ASExtensionError(.failed))
            return
        }
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }

    func completeSavePasswordRequest() {
        guard #available(iOS 26.2, *) else {
            // Unreachable: save-password requests only exist on iOS 26.2+.
            extensionContext.cancelRequest(withError: ASExtensionError(.failed))
            return
        }
        extensionContext.completeSavePasswordRequest(completionHandler: nil)
    }

    func completeGeneratePasswordRequest(passwords: [String]) {
        guard #available(iOS 26.2, *) else {
            // Unreachable: generate-password requests only exist on iOS 26.2+.
            extensionContext.cancelRequest(withError: ASExtensionError(.failed))
            return
        }
        let results = passwords.map { ASGeneratedPassword(kind: .strong, value: $0) }
        extensionContext.completeGeneratePasswordRequest(
            results: results,
            completionHandler: nil
        )
    }

    func cancelRequest(withError error: ASExtensionError) {
        extensionContext.cancelRequest(withError: error)
    }
}

#endif
