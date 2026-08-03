#if os(macOS)
import AppKit
import AuthenticationServices
import SwiftUI

/// Abstraction over the extension-context completion calls the macOS shell
/// makes. The real implementation forwards to `ASCredentialProviderExtensionContext`;
/// unit tests inject a spy so the shell's cleanup routing can be exercised
/// without the system AutoFill harness (there is no hosted `extensionContext`
/// off the harness, so touching it directly would trap).
@MainActor
protocol CredentialProviderRequestCompleting: AnyObject {
    func completeRequest(withSelectedCredential credential: ASPasswordCredential)
    func completeAssertionRequest(using credential: ASPasskeyAssertionCredential)
    func completeOneTimeCode(code: String)
    func cancelRequest(withError error: ASExtensionError)
}

/// Native macOS presentation shell for the AutoFill extension.
///
/// On macOS `ASCredentialProviderViewController` subclasses `NSViewController`.
/// This class owns the same platform-neutral `CredentialProviderCoordinator`
/// the iOS shell uses; all request handling, unlock orchestration, matching,
/// passkey assertion, and the `cleanup()` teardown live there. The shell only:
///  - forwards system requests to the coordinator,
///  - hosts the shared SwiftUI picker (`AutoFillSearchView`) in an
///    `NSHostingController`,
///  - shows `NSAlert` prompts for unlock / error / read-only,
///  - and routes **every** completion, cancel, alert dismissal, and window
///    close back through the coordinator so `cleanup()` always runs.
///
/// Save-password and generate-password requests are iOS-only
/// (`API_UNAVAILABLE(macos)`), so those presenter methods are unreachable stubs
/// here. One-time codes require macOS 15; the shell guards them accordingly.
@MainActor
final class CredentialProviderViewController: ASCredentialProviderViewController {
    // MARK: - Test seams

    /// Injected by tests to observe completion/cancel routing. When `nil`, the
    /// shell lazily builds a completer backed by the real `extensionContext`.
    var requestCompleter: CredentialProviderRequestCompleting?

    /// Injected by tests to bypass `NSAlert.runModal()` (which requires a run
    /// loop and window). Defaults to the real modal presentation.
    var runModalAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    private lazy var extensionContextCompleter: CredentialProviderRequestCompleting =
        ExtensionContextCompleter(context: extensionContext)

    private var completer: CredentialProviderRequestCompleting {
        requestCompleter ?? extensionContextCompleter
    }

    // MARK: - State

    lazy var coordinator = CredentialProviderCoordinator(presenter: self)

    private var hostingController: NSHostingController<AnyView>?
    private var isShowingHostedContent = false
    private var hasAppeared = false
    /// Guards `cancelActiveRequestIfNeeded()` so a normal completion is never
    /// double-cancelled on window close / view disappearance.
    private var didFinishRequest = false

    private static let preferredSize = NSSize(width: 480, height: 560)

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.preferredSize))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = Self.preferredSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hasAppeared = true
        coordinator.presentationDidBecomeActive()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        hasAppeared = false
        // Window close / dismissal has no iOS analogue; make sure a still-pending
        // request tears the vault down instead of leaking an unlocked session.
        cancelActiveRequestIfNeeded()
    }

    /// Cancels the active request (running `cleanup()`) if nothing has completed
    /// it yet. Exposed for the shell lifecycle tests.
    func cancelActiveRequestIfNeeded() {
        guard !didFinishRequest else { return }
        coordinator.cancelRequest(code: .userCanceled)
    }

    // MARK: - Request forwarding (macOS 14 available surface)

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        coordinator.prepareCredentialList(for: serviceIdentifiers)
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        coordinator.prepareInterfaceToProvideCredential(for: credentialIdentity)
    }

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        coordinator.prepareCredentialList(for: serviceIdentifiers, requestParameters: requestParameters)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        coordinator.prepareInterfaceToProvideCredential(for: credentialRequest)
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        // Passkey registration has no macOS creator UI (the Mac targets are
        // on hold); answer the request instead of leaving the system waiting.
        cancelRequest(withError: ASExtensionError(.userCanceled))
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
}

// MARK: - CredentialProviderPresenting

extension CredentialProviderViewController: CredentialProviderPresenting {
    var isPresentationActive: Bool {
        hasAppeared
    }

    var isDisplayingContent: Bool {
        isShowingHostedContent
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
        // A database switch shows the unlock alert next, so the hosted search
        // view is dismissed first — same routing as `onSelect`/`onCancel`.
        let wrappedSwitcher = databaseSwitcher.map { switcher in
            CredentialProviderDatabaseSwitcherContext(
                databases: switcher.databases,
                currentDatabaseID: switcher.currentDatabaseID,
                onSwitch: { [weak self] reference, currentSearchText in
                    self?.dismissHostedContent()
                    switcher.onSwitch(reference, currentSearchText)
                }
            )
        }
        let searchView = AutoFillSearchView(
            entries: entries,
            searchEntries: searchEntries,
            possibleEntries: possibleEntries,
            initialSearchText: initialSearchText,
            databaseSwitcher: wrappedSwitcher,
            // Always nil here: entry creation writes to the database, which the
            // coordinator only offers on iOS.
            onCreateEntry: onCreateEntry,
            onSelect: { [weak self] entry in
                self?.dismissHostedContent()
                onSelect(entry)
            },
            onSelectPossible: { [weak self] entry in
                self?.dismissHostedContent()
                onSelectPossible(entry)
            },
            onAddURLToPossible: onAddURLToPossible,
            onCancel: { [weak self] in
                self?.dismissHostedContent()
                onCancel()
            }
        )
        hostContent(searchView)
    }

    func presentEntryCreator(
        initialDraft: EntryDraftPayload,
        allowsPasswordEditing: Bool,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    ) {
        // Unreachable on macOS: save-password requests are iOS-only
        // (`ASSavePasswordRequest` is `API_UNAVAILABLE(macos)`) and the
        // picker's create action is gated to iOS, so the coordinator never
        // drives this path here. Cancel defensively.
        assertionFailure("presentEntryCreator is unreachable on macOS (entry creation is iOS-only)")
        onCancel()
    }

    func presentPasskeyCreator(
        context: CredentialProviderPasskeyCreatorContext,
        onSave: @escaping @Sendable (String) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    ) {
        // Unreachable on macOS: registration requests are cancelled at the
        // shell's entry point before the coordinator is involved.
        assertionFailure("presentPasskeyCreator is unreachable on macOS (registration is cancelled at the entry point)")
        onCancel()
    }

    func presentPasskeyRegistrationFailure(
        message: String,
        onAcknowledge: @escaping () -> Void
    ) {
        // Unreachable on macOS (see presentPasskeyCreator).
        assertionFailure("presentPasskeyRegistrationFailure is unreachable on macOS (registration is cancelled at the entry point)")
        onAcknowledge()
    }

    func presentNoEnabledDatabasesState(onDismiss: @escaping () -> Void) {
        let emptyStateView = AutoFillNoEnabledDatabasesView(
            onDismiss: { [weak self] in
                self?.dismissHostedContent()
                onDismiss()
            }
        )
        hostContent(emptyStateView)
    }

    // MARK: "Ask this question"

    func presentUnlockPrompt(
        biometricOptionTitle: String?,
        onSubmitPassword: @escaping (String?) -> Void,
        onChooseBiometrics: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Unlock KeeForge")
        alert.informativeText = String(localized: "Enter your master password or use biometrics.")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        passwordField.placeholderString = String(localized: "Master Password")
        alert.accessoryView = passwordField
        alert.window.initialFirstResponder = passwordField

        // Button order defines response codes: first = rightmost/default.
        alert.addButton(withTitle: String(localized: "Unlock"))            // .alertFirstButtonReturn
        if biometricOptionTitle != nil {
            alert.addButton(withTitle: biometricOptionTitle ?? String(localized: "Use Biometrics")) // .alertSecondButtonReturn
        }
        alert.addButton(withTitle: String(localized: "Cancel"))            // second or third

        let response = runModalAlert(alert)
        switch response {
        case .alertFirstButtonReturn:
            onSubmitPassword(passwordField.stringValue)
        case .alertSecondButtonReturn where biometricOptionTitle != nil:
            onChooseBiometrics()
        default:
            onCancel()
        }
    }

    func presentUnlockError(
        message: String,
        onRetry: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Unlock Failed")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Try Again"))  // .alertFirstButtonReturn
        alert.addButton(withTitle: String(localized: "Cancel"))      // .alertSecondButtonReturn

        if runModalAlert(alert) == .alertFirstButtonReturn {
            onRetry()
        } else {
            onCancel()
        }
    }

    func presentReadOnlyNotice(
        message: String,
        onAcknowledge: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Read-only Database")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        _ = runModalAlert(alert)
        onAcknowledge()
    }

    func presentGeneratedPassword(
        _ password: String,
        onUse: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        // Unreachable on macOS: generate-password requests are iOS-only
        // (`ASGeneratePasswordsRequest` is `API_UNAVAILABLE(macos)`).
        assertionFailure("presentGeneratedPassword is unreachable on macOS (generate-password is iOS-only)")
        onCancel()
    }

    // MARK: "Complete with this credential/error"

    func completeRequest(withSelectedCredential credential: ASPasswordCredential) {
        didFinishRequest = true
        completer.completeRequest(withSelectedCredential: credential)
    }

    func completeAssertionRequest(using credential: ASPasskeyAssertionCredential) {
        didFinishRequest = true
        completer.completeAssertionRequest(using: credential)
    }

    func completeRegistrationRequest(using credential: ASPasskeyRegistrationCredential) {
        // Unreachable on macOS (registration is cancelled at the entry point).
        // Fail closed.
        assertionFailure("completeRegistrationRequest is unreachable on macOS")
        didFinishRequest = true
        completer.cancelRequest(withError: ASExtensionError(.failed))
    }

    func completeOneTimeCodeRequest(code: String) {
        didFinishRequest = true
        completer.completeOneTimeCode(code: code)
    }

    func completeSavePasswordRequest() {
        // Unreachable on macOS (save-password is iOS-only). Fail closed.
        assertionFailure("completeSavePasswordRequest is unreachable on macOS")
        didFinishRequest = true
        completer.cancelRequest(withError: ASExtensionError(.failed))
    }

    func completeGeneratePasswordRequest(passwords: [String]) {
        // Unreachable on macOS (generate-password is iOS-only). Fail closed.
        assertionFailure("completeGeneratePasswordRequest is unreachable on macOS")
        didFinishRequest = true
        completer.cancelRequest(withError: ASExtensionError(.failed))
    }

    func cancelRequest(withError error: ASExtensionError) {
        didFinishRequest = true
        dismissHostedContent()
        completer.cancelRequest(withError: error)
    }

    // MARK: - Hosted SwiftUI content

    private func hostContent(_ rootView: some View) {
        dismissHostedContent()

        let host = NSHostingController(rootView: AnyView(rootView))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController = host
        isShowingHostedContent = true
    }

    private func dismissHostedContent() {
        guard let host = hostingController else { return }
        host.view.removeFromSuperview()
        host.removeFromParent()
        hostingController = nil
        isShowingHostedContent = false
    }
}

// MARK: - Real extension-context completer

/// Forwards completion calls to the hosted `ASCredentialProviderExtensionContext`.
@MainActor
private final class ExtensionContextCompleter: CredentialProviderRequestCompleting {
    private let context: ASCredentialProviderExtensionContext

    init(context: ASCredentialProviderExtensionContext) {
        self.context = context
    }

    func completeRequest(withSelectedCredential credential: ASPasswordCredential) {
        context.completeRequest(withSelectedCredential: credential, completionHandler: nil)
    }

    func completeAssertionRequest(using credential: ASPasskeyAssertionCredential) {
        context.completeAssertionRequest(using: credential)
    }

    func completeOneTimeCode(code: String) {
        guard #available(macOS 15.0, *) else {
            // One-time codes require macOS 15; unreachable below that (the
            // extension does not advertise `ProvidesOneTimeCodes` on macOS).
            context.cancelRequest(withError: ASExtensionError(.failed))
            return
        }
        context.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }

    func cancelRequest(withError error: ASExtensionError) {
        context.cancelRequest(withError: error)
    }
}

#endif
