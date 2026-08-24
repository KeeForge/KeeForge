import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication

// Must stay free of UIKit and AppKit: presentation and extension-context calls
// go through the `CredentialProviderPresenting` seam so both the iOS and macOS
// shells can host this coordinator unchanged.

/// Outcome of a save attempt started from the in-extension entry creator.
/// Mirrors `AutoFillEntryCreatorActionResult` without referencing the view layer.
enum CredentialProviderEntrySaveOutcome: Sendable {
    case completed
    case showWarningAndCancel(String)
    case showError(String)
}

/// The in-search database switcher offered by `AutoFillSearchView`: the
/// AutoFill-enabled databases to list, which one is currently open (marked
/// with a checkmark), and the coordinator callback that performs the switch.
/// `onSwitch` receives the tapped database plus the search text the user had
/// typed at that moment, so the re-presented search can keep it. The
/// coordinator builds the context (nil when fewer than two databases are
/// enabled — nothing to switch to); the shells wrap `onSwitch` in their
/// dismissal handling, exactly like `onSelect`/`onCancel`, and pass the
/// context through to the view otherwise untouched.
struct CredentialProviderDatabaseSwitcherContext {
    let databases: [DatabaseReference]
    let currentDatabaseID: UUID?
    let onSwitch: (DatabaseReference, String) -> Void
}

/// What the passkey-registration confirmation sheet shows: the relying party
/// and user name from the request, the database the passkey will be saved
/// into, and the editable entry title's initial value. The sheet's save
/// callback returns only the edited title; everything else about the new
/// entry is derived from the request by the coordinator.
struct CredentialProviderPasskeyCreatorContext {
    let relyingPartyIdentifier: String
    let userName: String
    let databaseName: String
    let initialTitle: String
}

/// The narrow seam between the coordinator and a platform presentation shell.
///
/// The shell needs no knowledge of matching or vault logic; the surface is
/// limited to "present this view", "ask this question", and "complete with
/// this credential/error". The coordinator always tears down vault state via
/// `cleanup()` before asking the shell to complete or cancel the request.
@MainActor
protocol CredentialProviderPresenting: AnyObject {
    /// Whether the shell's view hierarchy is currently on screen and can
    /// safely present interactive UI.
    var isPresentationActive: Bool { get }

    /// Whether the shell is currently showing modal content. Used to avoid
    /// double-presenting the unlock prompt (mirrors `presentedViewController != nil`).
    var isDisplayingContent: Bool { get }

    /// Whether the shell's most recent presentation actually attached — UIKit
    /// can refuse a modal with only a console warning. Defaults to true for
    /// shells that host content directly instead of presenting it.
    var didAttachPresentedContent: Bool { get }

    // MARK: "Present this view"

    /// `databaseSwitcher` is non-nil only when the search UI should offer the
    /// in-search database switcher (two or more AutoFill-enabled databases).
    /// Shells wrap its `onSwitch` in their dismissal handling, exactly like
    /// `onSelect`/`onCancel`.
    ///
    /// `onCreateEntry` is non-nil only when the picker should offer creating a
    /// new credential (iOS password requests against a writable database).
    /// Presenting the creator replaces the picker, so shells wrap it in the
    /// same dismissal handling as `onSelect`/`onCancel`.
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
    )

    /// `allowsPasswordEditing` is false for save-password requests, whose
    /// password the site already received, and true for the picker-initiated
    /// flow, where the user still has to pick one.
    func presentEntryCreator(
        initialDraft: EntryDraftPayload,
        allowsPasswordEditing: Bool,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    )

    /// Confirmation sheet for a passkey registration. `onSave` receives the
    /// user-edited entry title; `onCancel` covers both the Cancel action and
    /// sheet dismissal.
    func presentPasskeyCreator(
        context: CredentialProviderPasskeyCreatorContext,
        onSave: @escaping @Sendable (String) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    )

    /// Empty state for the zero-enabled-databases case: tells the user to
    /// turn on AutoFill for a database in KeeForge's settings. Dismissal is
    /// the only action; the coordinator cancels the request from `onDismiss`.
    func presentNoEnabledDatabasesState(onDismiss: @escaping () -> Void)

    // MARK: "Ask this question"

    /// Prompt for the master password (with an optional biometric action).
    /// `onSubmitPassword` receives the raw text field contents; the coordinator
    /// decides what to do with empty input.
    func presentUnlockPrompt(
        biometricOptionTitle: String?,
        onSubmitPassword: @escaping (String?) -> Void,
        onChooseBiometrics: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )

    func presentUnlockError(
        message: String,
        onRetry: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )

    func presentReadOnlyNotice(
        message: String,
        onAcknowledge: @escaping () -> Void
    )

    /// Single-button notice for a passkey-registration request the extension
    /// cannot serve (e.g. no ES256 among the supported algorithms). The
    /// coordinator cancels the request from `onAcknowledge`.
    func presentPasskeyRegistrationFailure(
        message: String,
        onAcknowledge: @escaping () -> Void
    )

    func presentGeneratedPassword(
        _ password: String,
        onUse: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )

    // MARK: "Complete with this credential/error"

    func completeRequest(withSelectedCredential credential: ASPasswordCredential)
    func completeAssertionRequest(using credential: ASPasskeyAssertionCredential)
    func completeRegistrationRequest(using credential: ASPasskeyRegistrationCredential)
    /// Only reachable on iOS 18+ (one-time-code requests); the shell wraps the
    /// code in `ASOneTimeCodeCredential` under its own availability check.
    func completeOneTimeCodeRequest(code: String)
    /// Only reachable on iOS 26.2+ (save-password requests).
    func completeSavePasswordRequest()
    /// Only reachable on iOS 26.2+ (generate-password requests); the shell wraps
    /// the values in `ASGeneratedPassword` under its own availability check.
    func completeGeneratePasswordRequest(passwords: [String])
    func cancelRequest(withError error: ASExtensionError)
}

extension CredentialProviderPresenting {
    var didAttachPresentedContent: Bool { true }
}

/// Owns the AutoFill extension's request handling, unlock orchestration,
/// credential matching, passkey assertion, and vault-teardown lifecycle.
///
/// `cleanup()` is the extension's only "lock": every completion path (success,
/// user cancel, error-alert dismissal, silent-request failure, extension
/// configuration) funnels through a completion helper that clears the session
/// key and all parsed vault state before the shell touches the extension context.
///
/// State and matching helpers are `internal` (not `private`) so unit tests in
/// the app module can seed an unlocked vault and assert teardown.
@MainActor
final class CredentialProviderCoordinator {
    weak var presenter: (any CredentialProviderPresenting)?

    // MARK: - Vault / request state (internal for unit tests)

    var serviceIdentifiers: [ASCredentialServiceIdentifier] = []
    var parsedEntries: [KPEntry] = []
    var parsedRootGroup: KPGroup?
    var parsedMeta: KPMeta?
    var parsedFormatVersion: KDBXParser.FileVersion?
    var sessionKey: SymmetricKey?
    var compositeKey: SymmetricKey?
    var openTimeSHA512: Data?
    var activeDatabaseReference: DatabaseReference?
    var targetRecordIdentifier: String?
    var pendingPasskeyRequest: ASPasskeyCredentialRequest?
    var pendingPasskeyRequestParameters: ASPasskeyCredentialRequestParameters?
    var pendingPasskeyRegistrationRequest: ASPasskeyCredentialRequest?
    /// Deferred user-visible failure for a registration request the extension
    /// cannot serve, presented once the shell is on screen and then cancelled
    /// with `.failed` (mirrors `pendingReadOnlyCancellationMessage`).
    var pendingPasskeyRegistrationFailureMessage: String?
    var hasPendingOTCRequest = false
    var hasPendingOTCListRequest = false
    var pendingGeneratePasswordPresentation = false
    /// Deferred presentation of the zero-enabled-databases empty state, used
    /// by request entry points that run before the shell is on screen (the
    /// save-password prepare path). Interactive unlock flows present the
    /// empty state directly from `presentUnlockPromptIfNeeded` instead.
    var pendingNoEnabledDatabasesPresentation = false
    var pendingReadOnlyCancellationMessage: String?
    var pendingSavePasswordRequestStorage: Any?
    var pendingGeneratePasswordsRequestStorage: Any?
    var pendingUnlock = false
    /// Non-nil while a database switch started from the search view's switcher
    /// waits for the new database's unlock. Holds the previously open database
    /// so a cancelled switch can fall back to it. The previous vault state
    /// itself (parsed entries/groups, session key, composite key, open-time
    /// hash) is deliberately retained during the switch — only a successful
    /// `loadEntries` for the new database overwrites it, and
    /// `recordSuccessfulUnlock` commits the switch by clearing this field.
    var pendingSwitchPreviousDatabaseReference: DatabaseReference?
    /// The search text the user had typed when starting a database switch.
    /// Consumed by the next search presentation so the re-presented search —
    /// the new database's on success, the previous one's on cancel — keeps it.
    var pendingSwitchSearchText: String?
    /// Presentation that arrived while the shell was off screen (e.g. an
    /// unlock finishing behind the system biometric sheet), where UIKit would
    /// silently drop it. Replayed by `presentationDidBecomeActive()`.
    private var pendingPresentation: (() -> Void)?

    private var isUnlockInProgress = false
    private var didAttemptAutoBiometricUnlock = false
    private var didFinishRequest = false
    private var requestGeneration = 0
    private var unlockTask: Task<Void, Never>?

    private struct RequestNoLongerActive: Error {}

    #if DEBUG
    /// Suspends unlock in coordinator tests so cancellation can be verified
    /// without invoking a real biometric prompt or parsing a fixture.
    var unlockWorkOverride: (@MainActor () async throws -> Void)?

    /// Stands in for the process's remaining memory so tests can drive the
    /// pre-flight in `loadEntries` without a device under real pressure.
    var memoryBudgetOverride: UInt64?
    #endif

    #if os(iOS)
    /// Clipboard write used by the opt-in "copy verification code on AutoFill"
    /// behavior. Injectable so unit tests can observe the copy without touching
    /// the real `UIPasteboard`. Defaults to `ClipboardService.copy`, which
    /// stamps the write with the Clipboard Clear Timeout as a system-enforced
    /// expiration date — the copy therefore expires even though the extension
    /// process is gone by then.
    var copyToClipboard: @MainActor (String) -> Void = { ClipboardService.copy($0) }
    #endif

    /// Save environment for the passkey-registration flow; injectable so unit
    /// tests can record the save and drive the conflict/error paths.
    var passkeySaveEnvironment: AutoFillSaveCoordinator.Environment = .live

    /// Reads a registration request's excluded credential IDs. Injectable
    /// because `ASPasskeyCredentialRequest.excludedCredentials` is read-only
    /// with no initializer that sets it, so tests cannot construct exclusions.
    var excludedCredentialIDs: (ASPasskeyCredentialRequest) -> [Data] = { request in
        #if os(macOS)
        guard #available(macOS 15.0, *) else { return [] }
        #endif
        return request.excludedCredentials?.map(\.credentialID) ?? []
    }

    // Save-password and generate-password requests are iOS-only: the underlying
    // AuthenticationServices types are `API_UNAVAILABLE(macos)` (verified against
    // the macOS 26.5 SDK headers), so the whole surface is `#if os(iOS)`.
    #if os(iOS)
    @available(iOS 26.2, *)
    private var pendingSavePasswordRequest: ASSavePasswordRequest? {
        get { pendingSavePasswordRequestStorage as? ASSavePasswordRequest }
        set { pendingSavePasswordRequestStorage = newValue }
    }

    @available(iOS 26.2, *)
    private var pendingGeneratePasswordsRequest: ASGeneratePasswordsRequest? {
        get { pendingGeneratePasswordsRequestStorage as? ASGeneratePasswordsRequest }
        set { pendingGeneratePasswordsRequestStorage = newValue }
    }
    #endif

    init(presenter: (any CredentialProviderPresenting)? = nil) {
        self.presenter = presenter
    }

    // MARK: - Request entry points (forwarded by the shell)

    private func beginRequest() {
        requestGeneration &+= 1
        unlockTask?.cancel()
        unlockTask = nil
        isUnlockInProgress = false
        didFinishRequest = false
        pendingPresentation = nil
    }

    private func isRequestActive(_ generation: Int) -> Bool {
        !didFinishRequest && requestGeneration == generation
    }

    func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        beginRequest()
        AutoFillDiagnostics.log("prepareCredentialList ids=\(serviceIdentifiers.count) active=\(presenter?.isPresentationActive == true)")
        self.serviceIdentifiers = serviceIdentifiers
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        hasPendingOTCListRequest = false
        clearPendingCreationRequests()
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = true
        activatePresentationIfPossible()
    }

    // MARK: One-time-code credential list (iOS 18+ / macOS 15+)

    /// Interactive list request for a one-time-code field: the user tapped an
    /// OTP field and chose this provider from the AutoFill UI, so there is no
    /// pre-matched credential identity. Unlock, then present matching TOTP
    /// entries (or the full TOTP list) for manual selection.
    func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        beginRequest()
        AutoFillDiagnostics.log("prepareOneTimeCodeCredentialList ids=\(serviceIdentifiers.count)")
        self.serviceIdentifiers = serviceIdentifiers
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        hasPendingOTCListRequest = true
        clearPendingCreationRequests()
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = true
        activatePresentationIfPossible()
    }

    func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        beginRequest()
        AutoFillDiagnostics.log("prepareInterfaceToProvideCredential(password identity)")
        serviceIdentifiers = [credentialIdentity.serviceIdentifier]
        targetRecordIdentifier = CredentialIdentityStoreManager.recordIdentifier(of: credentialIdentity)
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        clearPendingCreationRequests()
        didAttemptAutoBiometricUnlock = false
        // Delay unlock until the shell is fully presented,
        // otherwise biometric auth fails with "not interactive".
        pendingUnlock = true
        activatePresentationIfPossible()
    }

    // MARK: Passkey credential request (iOS 17+)

    func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
        beginRequest()
        AutoFillDiagnostics.log("prepareCredentialList(passkey parameters) ids=\(serviceIdentifiers.count)")
        self.serviceIdentifiers = serviceIdentifiers
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = requestParameters
        clearPendingCreationRequests()
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = true
        activatePresentationIfPossible()
    }

    func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        beginRequest()
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            pendingPasskeyRequest = passkeyRequest
            pendingPasskeyRequestParameters = nil
            targetRecordIdentifier = CredentialIdentityStoreManager.recordIdentifier(of: passkeyRequest.credentialIdentity)
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = true
            activatePresentationIfPossible()
        } else if let passwordIdentity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            prepareInterfaceToProvideCredential(for: passwordIdentity)
        } else if #available(iOS 18.0, macOS 15.0, *), credentialRequest is ASOneTimeCodeCredentialRequest {
            serviceIdentifiers = [credentialRequest.credentialIdentity.serviceIdentifier]
            hasPendingOTCRequest = true
            hasPendingOTCListRequest = false
            targetRecordIdentifier = CredentialIdentityStoreManager.recordIdentifier(of: credentialRequest.credentialIdentity)
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = true
            activatePresentationIfPossible()
        } else {
            cancelRequest(code: .failed)
        }
    }

    // MARK: Passkey registration

    func prepareInterface(forPasskeyRegistration credentialRequest: ASCredentialRequest) {
        beginRequest()
        guard let registrationRequest = credentialRequest as? ASPasskeyCredentialRequest,
              let identity = registrationRequest.credentialIdentity as? ASPasskeyCredentialIdentity,
              // PasskeyCredential requires both; saving without them would
              // register a credential that can never assert.
              !identity.userName.isEmpty,
              !identity.userHandle.isEmpty else {
            cancelRequest(code: .failed)
            return
        }

        serviceIdentifiers = [identity.serviceIdentifier]
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        hasPendingOTCListRequest = false
        clearPendingCreationRequests()
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = false

        guard registrationRequest.supportedAlgorithms.contains(.ES256) else {
            pendingPasskeyRegistrationFailureMessage = String(localized: "This passkey request isn't supported.")
            activatePresentationIfPossible()
            return
        }

        // Registration targets the default database, exactly like the
        // save-password flow: with no enabled database the deferred empty
        // state explains how to enable one instead of failing.
        guard let databaseReference = DatabaseListStore.defaultAutoFillDatabase else {
            pendingNoEnabledDatabasesPresentation = true
            activatePresentationIfPossible()
            return
        }

        guard databaseReference.isReadOnly == false else {
            pendingReadOnlyCancellationMessage = String(localized: "This database is read-only. Open KeeForge to enable editing.")
            activatePresentationIfPossible()
            return
        }

        pendingPasskeyRegistrationRequest = registrationRequest
        // Pin the save target now so the unlock flow and the passkey save
        // both operate on the same reference.
        activeDatabaseReference = databaseReference
        pendingUnlock = true
        activatePresentationIfPossible()
    }

    func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        beginRequest()
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            providePasskeyWithoutUserInteraction(for: passkeyRequest)
        } else if let passwordIdentity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            provideCredentialWithoutUserInteraction(for: passwordIdentity)
        } else if #available(iOS 18.0, macOS 15.0, *), credentialRequest is ASOneTimeCodeCredentialRequest {
            provideOTCWithoutUserInteraction(for: credentialRequest)
        } else {
            cancelRequest(code: .failed)
        }
    }

    /// Called by the shell once its view hierarchy is on screen.
    func presentationDidBecomeActive() {
        AutoFillDiagnostics.log("presentationDidBecomeActive finished=\(didFinishRequest) pendingUnlock=\(pendingUnlock) pendingPresentation=\(pendingPresentation != nil)")
        guard !didFinishRequest else { return }
        if let pendingPresentation {
            self.pendingPresentation = nil
            presentWhenActive(pendingPresentation)
        } else if pendingUnlock {
            pendingUnlock = false
            presentUnlockPromptIfNeeded()
        } else if pendingNoEnabledDatabasesPresentation {
            pendingNoEnabledDatabasesPresentation = false
            presentNoEnabledDatabasesState()
        } else if let pendingReadOnlyCancellationMessage {
            self.pendingReadOnlyCancellationMessage = nil
            presentReadOnlyAlertAndCancel(message: pendingReadOnlyCancellationMessage)
        } else if let pendingPasskeyRegistrationFailureMessage {
            self.pendingPasskeyRegistrationFailureMessage = nil
            presentPasskeyRegistrationFailureAndCancel(message: pendingPasskeyRegistrationFailureMessage)
        } else if pendingGeneratePasswordPresentation {
            pendingGeneratePasswordPresentation = false
            #if os(iOS)
            if #available(iOS 26.2, *),
               let pendingGeneratePasswordsRequest {
                presentGeneratePasswordPrompt(for: pendingGeneratePasswordsRequest)
            }
            #endif
        }
    }

    /// Presents now if the shell is on screen, otherwise defers to the next
    /// `presentationDidBecomeActive()`. Every presentation that can follow an
    /// async gap (unlock, save) must route through this so it is never dropped:
    /// a present UIKit refused despite the shell looking active is re-queued.
    private func presentWhenActive(_ present: @escaping () -> Void) {
        guard let presenter, presenter.isPresentationActive else {
            AutoFillDiagnostics.log("present deferred: shell off screen")
            pendingPresentation = present
            return
        }
        present()
        if !presenter.didAttachPresentedContent {
            AutoFillDiagnostics.log("present dropped by UIKit despite active shell; re-queued")
            pendingPresentation = present
        }
    }

    /// Cheap re-entry point the shell calls on layout passes, for the case
    /// where the view returns to a window without appearance callbacks. The
    /// hop mirrors `activatePresentationIfPossible`: never present from
    /// inside a layout pass.
    func retryPendingPresentationIfPossible() {
        guard !didFinishRequest, pendingPresentation != nil,
              presenter?.isPresentationActive == true else { return }
        let generation = requestGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.isRequestActive(generation),
                  let pending = self.pendingPresentation,
                  presenter?.isPresentationActive == true
            else { return }
            AutoFillDiagnostics.log("replaying deferred presentation from layout hook")
            self.pendingPresentation = nil
            presentWhenActive(pending)
        }
    }

    private func activatePresentationIfPossible() {
        guard presenter?.isPresentationActive == true else { return }
        let generation = requestGeneration

        // Defer until the request callback has returned before asking UIKit or
        // AppKit to present another controller or alert.
        Task { @MainActor [weak self] in
            guard let self,
                  self.isRequestActive(generation),
                  presenter?.isPresentationActive == true
            else { return }
            presentationDidBecomeActive()
        }
    }

    func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        beginRequest()
        AutoFillDiagnostics.log("provideCredentialWithoutUserInteraction(password identity)")
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let recordIdentifier = CredentialIdentityStoreManager.recordIdentifier(of: credentialIdentity)
        guard let databaseReference = resolveSilentRequestDatabase(forRecordIdentifier: recordIdentifier) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics(for: databaseReference) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let generation = requestGeneration
        isUnlockInProgress = true
        unlockTask = Task { [weak self] in
            defer {
                if self?.requestGeneration == generation {
                    self?.isUnlockInProgress = false
                    self?.unlockTask = nil
                }
            }
            do {
                guard let self, self.isRequestActive(generation) else { return }
                let context = try await BiometricService.authenticate(reason: String(localized: "AutoFill with KeeForge"))
                let compositeKey = try self.retrieveCompositeKey(for: databaseReference, context: context)
                try await self.loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference,
                    generation: generation
                )
                guard self.isRequestActive(generation) else { return }
                self.persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                self.recordSuccessfulUnlock(for: databaseReference)
                let passwordEntries = self.parsedEntries.filter { $0.hasPassword && !$0.isExpired() }

                if let recordIdentifier,
                   let entry = self.entryMatching(recordIdentifier: recordIdentifier, in: passwordEntries) {
                    guard !self.mustEscalateToInteractiveFill(for: entry) else {
                        self.cancelRequest(code: .userInteractionRequired)
                        return
                    }
                    self.completeRequest(with: entry)
                } else {
                    self.removeStaleIdentityIfEntryMissing(recordIdentifier: recordIdentifier)
                    let matches = CredentialMatcher.strictMatchedEntries(
                        from: passwordEntries,
                        for: [credentialIdentity.serviceIdentifier]
                    )
                    if matches.count == 1, let entry = matches.first {
                        guard !self.mustEscalateToInteractiveFill(for: entry) else {
                            self.cancelRequest(code: .userInteractionRequired)
                            return
                        }
                        self.completeRequest(with: entry)
                    } else if matches.isEmpty {
                        self.cancelRequest(code: .credentialIdentityNotFound)
                    } else {
                        self.cancelRequest(code: .userInteractionRequired)
                    }
                }
            } catch {
                guard let self, self.isRequestActive(generation) else { return }
                self.cancelRequest(code: .userInteractionRequired)
            }
        }
    }

    /// Whether the silent (no-UI) QuickType fill must bounce back to the system
    /// as `.userInteractionRequired` instead of completing here.
    ///
    /// True only when the user opted into copying the verification code on
    /// AutoFill and this entry has one: a credential extension running without
    /// a presented interface cannot reliably write the pasteboard, so a silent
    /// copy would be dropped without any signal to the user. Escalating makes
    /// the system re-run the request with our UI on screen, where the copy
    /// works. The extra interaction is the accepted cost of opting in; users
    /// who leave the setting off keep the fully silent path. (Strongbox does
    /// the same on its QuickType path.) Always false on macOS — the behavior
    /// is iOS-only.
    private func mustEscalateToInteractiveFill(for entry: KPEntry) -> Bool {
        #if os(iOS)
        return shouldCopyTOTPCode(for: entry)
        #else
        return false
        #endif
    }

    func prepareInterfaceForExtensionConfiguration() {
        beginRequest()
        cancelRequest(code: .failed)
    }

    // Save-password / generate-password requests are iOS-only (see note above).
    #if os(iOS)
    @available(iOS 26.2, *)
    func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
        beginRequest()
        cancelRequest(code: .userInteractionRequired)
    }

    @available(iOS 26.2, *)
    func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
        beginRequest()
        // Save targets the default database: the active pointer when enabled,
        // else the most recently opened enabled database. With no enabled
        // database, saving is unavailable rather than failing — the deferred
        // empty state explains how to enable one.
        guard let databaseReference = DatabaseListStore.defaultAutoFillDatabase else {
            serviceIdentifiers = [savePasswordRequest.serviceIdentifier]
            targetRecordIdentifier = nil
            pendingPasskeyRequest = nil
            pendingPasskeyRequestParameters = nil
            hasPendingOTCRequest = false
            hasPendingOTCListRequest = false
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = false
            pendingNoEnabledDatabasesPresentation = true
            activatePresentationIfPossible()
            return
        }

        guard databaseReference.isReadOnly == false else {
            serviceIdentifiers = [savePasswordRequest.serviceIdentifier]
            targetRecordIdentifier = nil
            pendingPasskeyRequest = nil
            pendingPasskeyRequestParameters = nil
            hasPendingOTCRequest = false
            hasPendingOTCListRequest = false
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = false
            pendingGeneratePasswordPresentation = false
            pendingReadOnlyCancellationMessage = String(localized: "This database is read-only. Open KeeForge to enable editing.")
            activatePresentationIfPossible()
            return
        }

        serviceIdentifiers = [savePasswordRequest.serviceIdentifier]
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        hasPendingOTCListRequest = false
        pendingGeneratePasswordsRequest = nil
        pendingSavePasswordRequest = savePasswordRequest
        didAttemptAutoBiometricUnlock = false
        pendingGeneratePasswordPresentation = false
        // Pin the save target now so the unlock flow and `saveNewEntry` both
        // operate on the same reference.
        activeDatabaseReference = databaseReference
        pendingUnlock = true
        activatePresentationIfPossible()
    }

    @available(iOS 26.2, *)
    func performWithoutUserInteraction(generatePasswordsRequest: ASGeneratePasswordsRequest) {
        beginRequest()
        let password = PasswordGenerator.generate(options: SettingsService.passwordGeneratorOptions)
        finishRequest { presenter in
            presenter.completeGeneratePasswordRequest(passwords: [password])
        }
    }

    @available(iOS 26.2, *)
    func prepareInterface(for generatePasswordsRequest: ASGeneratePasswordsRequest) {
        beginRequest()
        serviceIdentifiers = [generatePasswordsRequest.serviceIdentifier]
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        hasPendingOTCListRequest = false
        pendingSavePasswordRequest = nil
        pendingGeneratePasswordsRequest = generatePasswordsRequest
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = false
        pendingNoEnabledDatabasesPresentation = false
        pendingGeneratePasswordPresentation = true
        activatePresentationIfPossible()
    }
    #endif

    // MARK: - Passkey silent auth

    private func providePasskeyWithoutUserInteraction(for request: ASPasskeyCredentialRequest) {
        beginRequest()
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let recordIdentifier = CredentialIdentityStoreManager.recordIdentifier(of: request.credentialIdentity)
        guard let databaseReference = resolveSilentRequestDatabase(forRecordIdentifier: recordIdentifier) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics(for: databaseReference) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let generation = requestGeneration
        isUnlockInProgress = true
        unlockTask = Task { [weak self] in
            defer {
                if self?.requestGeneration == generation {
                    self?.isUnlockInProgress = false
                    self?.unlockTask = nil
                }
            }
            do {
                guard let self, self.isRequestActive(generation) else { return }
                let context = try await BiometricService.authenticate(reason: String(localized: "Passkey sign-in with KeeForge"))
                let compositeKey = try self.retrieveCompositeKey(for: databaseReference, context: context)
                try await self.loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference,
                    generation: generation
                )
                guard self.isRequestActive(generation) else { return }
                self.persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                self.recordSuccessfulUnlock(for: databaseReference)
                try self.completePasskeyRequest(request)
            } catch {
                guard let self, self.isRequestActive(generation) else { return }
                self.cancelRequest(code: .userInteractionRequired)
            }
        }
    }

    // MARK: - Unlock flow

    func presentUnlockPromptIfNeeded() {
        AutoFillDiagnostics.log("presentUnlockPromptIfNeeded displayingContent=\(presenter?.isDisplayingContent == true) unlockInProgress=\(isUnlockInProgress)")
        guard presenter?.isDisplayingContent != true, !isUnlockInProgress else { return }

        // Pin the request to its target database before any unlock UI: the
        // owning database for identifier-carrying requests (QuickType tap,
        // passkey/OTC by identity), the default database otherwise. With
        // nothing eligible to unlock — no enabled databases, or a stale
        // identifier with no fallback — show the explanatory empty state
        // instead of an unlock prompt that could never succeed.
        guard let databaseReference = resolveInteractiveRequestDatabase() else {
            presentNoEnabledDatabasesState()
            return
        }

        if shouldAutoUnlockWithBiometrics(for: databaseReference) {
            AutoFillDiagnostics.log("auto biometric unlock starting")
            didAttemptAutoBiometricUnlock = true
            unlockWithBiometrics()
            return
        }
        AutoFillDiagnostics.log("presenting unlock prompt biometricOption=\(canUseBiometrics(for: databaseReference))")

        presenter?.presentUnlockPrompt(
            biometricOptionTitle: canUseBiometrics(for: databaseReference) ? biometricActionTitle : nil,
            onSubmitPassword: { [weak self] password in
                guard let self, let password, !password.isEmpty else {
                    self?.presentUnlockPromptIfNeeded()
                    return
                }
                self.unlockWithPassword(password)
            },
            onChooseBiometrics: { [weak self] in
                self?.unlockWithBiometrics()
            },
            onCancel: { [weak self] in
                self?.cancelRequestOrRestoreSwitchedDatabase()
            }
        )
    }

    private func shouldAutoUnlockWithBiometrics(for databaseReference: DatabaseReference) -> Bool {
        guard !didAttemptAutoBiometricUnlock else { return false }
        guard SettingsService.autoUnlockWithFaceID else { return false }
        return canUseBiometrics(for: databaseReference)
    }

    /// Whether biometric unlock is possible for the given database — checked
    /// against that database's own keychain composite key, never the active
    /// database's (a QuickType tap may target any enabled database).
    private func canUseBiometrics(for databaseReference: DatabaseReference) -> Bool {
        guard BiometricService.isAvailable else { return false }
        return KeychainService.hasStoredKey(
            for: databaseReference.id,
            legacyFilename: databaseReference.legacyKeychainFilename
        )
    }

    // MARK: - Request-to-database resolution

    /// How a request maps onto a database once its record identifier (if any)
    /// has been considered.
    private enum RequestDatabaseResolution {
        /// Unlock this database.
        case database(DatabaseReference)
        /// The identifier was stale — unparseable, or its database is unknown
        /// or has AutoFill disabled. Cleanup of the offending identities has
        /// been scheduled; continue interactively on `fallback` when present.
        case stale(fallback: DatabaseReference?)
        /// No identifier and no enabled database to default to.
        case unavailable
    }

    /// Resolves the database a request should unlock. A database with
    /// AutoFill disabled is treated as nonexistent throughout.
    ///
    /// - `.current` identifiers resolve to their owning database, provided it
    ///   is still registered and AutoFill-enabled; otherwise that database's
    ///   remaining identities are removed (targeted, works while locked) and
    ///   the request degrades to the default database.
    /// - `.legacy` identifiers carry no attribution and mean "the default
    ///   database" (pre-feature suggestions keep filling until a refresh
    ///   replaces them).
    /// - `.unrecognized` identifiers are unattributable, so the whole store
    ///   is cleared (it rebuilds lazily on the next unlock of each enabled
    ///   database) and the request degrades to the default database.
    /// - No identifier (manual search, OTC list, passkey parameters) → the
    ///   default database.
    private func resolveRequestDatabase(forRecordIdentifier recordIdentifier: String?) -> RequestDatabaseResolution {
        guard let recordIdentifier else {
            guard let fallback = DatabaseListStore.defaultAutoFillDatabase else { return .unavailable }
            return .database(fallback)
        }

        switch CredentialRecordIdentifier.parse(recordIdentifier) {
        case .current(let identifier):
            if let reference = DatabaseListStore.databases.first(where: { $0.id == identifier.databaseID }),
               reference.autoFillEnabled {
                return .database(reference)
            }
            CredentialIdentityStoreManager.removeIdentities(forDatabase: identifier.databaseID)
            return .stale(fallback: DatabaseListStore.defaultAutoFillDatabase)
        case .legacy:
            guard let fallback = DatabaseListStore.defaultAutoFillDatabase else { return .unavailable }
            return .database(fallback)
        case .unrecognized:
            CredentialIdentityStoreManager.clearStore()
            return .stale(fallback: DatabaseListStore.defaultAutoFillDatabase)
        }
    }

    /// Interactive-flow resolution: pins `activeDatabaseReference` so the
    /// unlock prompt, biometric availability, composite-key retrieval, and
    /// data load all target the same reference (also across error-retry
    /// loops). Returns nil when the zero-enabled-databases empty state should
    /// be shown instead of an unlock prompt.
    private func resolveInteractiveRequestDatabase() -> DatabaseReference? {
        if let activeDatabaseReference { return activeDatabaseReference }

        switch resolveRequestDatabase(forRecordIdentifier: targetRecordIdentifier) {
        case .database(let reference):
            activeDatabaseReference = reference
            return reference
        case .stale(let fallback):
            // The tapped suggestion cannot be honored and its cleanup is
            // already scheduled. Drop the per-entry target so the post-unlock
            // lookup does not dead-end, then continue interactively on the
            // fallback database — never a dead tap.
            targetRecordIdentifier = nil
            guard let fallback else { return nil }
            activeDatabaseReference = fallback
            return fallback
        case .unavailable:
            return nil
        }
    }

    private func resolveSilentRequestDatabase(forRecordIdentifier recordIdentifier: String?) -> DatabaseReference? {
        switch resolveRequestDatabase(forRecordIdentifier: recordIdentifier) {
        case .database(let reference):
            activeDatabaseReference = reference
            return reference
        case .stale, .unavailable:
            return nil
        }
    }

    /// After a successful unlock, a record identifier that matches no parsed
    /// entry is a stale suggestion (the entry was deleted or recycled since
    /// publication). Remove exactly that identity — legacy and unrecognized
    /// identifiers carry no attribution, so those clear the whole store —
    /// before the caller falls back to its interactive/matching path. Entries
    /// that exist but are currently filtered (e.g. expired) are left alone;
    /// the owning database's next refresh reconciles them.
    private func removeStaleIdentityIfEntryMissing(recordIdentifier: String?) {
        guard let recordIdentifier else { return }
        guard findEntry(byRecordIdentifier: recordIdentifier) == nil else { return }

        switch CredentialRecordIdentifier.parse(recordIdentifier) {
        case .current:
            CredentialIdentityStoreManager.removeIdentity(withRecordIdentifier: recordIdentifier)
        case .legacy, .unrecognized:
            CredentialIdentityStoreManager.clearStore()
        }
    }

    // MARK: - Database switching

    /// Entry point for the search view's database switcher. Runs the standard
    /// unlock flow for `reference` (auto/biometric unlock with that database's
    /// own composite key, or the password prompt) and, once unlocked,
    /// `afterUnlock()` re-presents the pending flow's UI with the new
    /// database's entries against the unchanged request context
    /// (`serviceIdentifiers`, `pendingPasskeyRequestParameters`,
    /// `hasPendingOTCListRequest`, `targetRecordIdentifier` — none of them are
    /// touched by switching).
    ///
    /// Swap-on-success semantics: the previous database's vault state is
    /// deliberately retained while the new unlock is pending — a successful
    /// `loadEntries` overwrites it wholesale and `recordSuccessfulUnlock`
    /// commits the switch (active pointer + `lastOpenedAt`, making the chosen
    /// database the session's save/passkey target and the default for the
    /// next launch). Cancelling the unlock instead restores the previous
    /// database by re-pinning it and re-presenting from the retained state,
    /// so a cancelled switch never strands the user without their still-open
    /// database.
    func switchDatabase(to reference: DatabaseReference, currentSearchText: String = "") {
        guard !isUnlockInProgress,
              sessionKey != nil,
              let currentReference = activeDatabaseReference,
              reference.id != currentReference.id else { return }

        // Preserve the typed search text for whichever search is presented
        // next (the new database's on success, the previous one's on cancel).
        pendingSwitchSearchText = currentSearchText

        // Re-validate against the registry: the switcher list was built when
        // the search appeared, and the main app may have disabled or removed
        // the database since (cross-process). A stale target re-presents the
        // current database's UI — the shell already dismissed the search view
        // before invoking the switch, so plain returning would dead-end.
        guard let target = DatabaseListStore.databases.first(where: { $0.id == reference.id }),
              target.autoFillEnabled else {
            afterUnlock()
            return
        }

        pendingSwitchPreviousDatabaseReference = currentReference
        activeDatabaseReference = target
        // The new database gets its own auto-biometric attempt, exactly like
        // a fresh interactive request against it.
        didAttemptAutoBiometricUnlock = false
        presentUnlockPromptIfNeeded()
    }

    /// Builds the search view's database switcher context: all AutoFill-enabled
    /// databases, or nil when fewer than two are enabled (the picker is shown
    /// only when there is something to switch to). Databases with AutoFill
    /// disabled are never listed — the extension treats them as nonexistent.
    private func makeDatabaseSwitcherContext() -> CredentialProviderDatabaseSwitcherContext? {
        let enabledDatabases = DatabaseListStore.autoFillEnabledDatabases
        guard enabledDatabases.count >= 2 else { return nil }
        return CredentialProviderDatabaseSwitcherContext(
            databases: enabledDatabases,
            currentDatabaseID: activeDatabaseReference?.id,
            onSwitch: { [weak self] reference, currentSearchText in
                self?.switchDatabase(to: reference, currentSearchText: currentSearchText)
            }
        )
    }

    /// Shared cancel handler for the unlock prompt and the unlock-error alert:
    /// during a pending database switch, cancelling falls back to the previous
    /// database instead of cancelling the whole request.
    private func cancelRequestOrRestoreSwitchedDatabase() {
        if restorePreviousDatabaseAfterCancelledSwitch() { return }
        cancelRequest(code: .userCanceled)
    }

    /// Cancelling a switch's unlock falls back to the previous database: its
    /// vault state was never torn down, so re-pinning it and re-presenting
    /// the pending flow's UI from the retained state is enough. Returns false
    /// when no switch is pending (the caller then cancels the request as
    /// before).
    private func restorePreviousDatabaseAfterCancelledSwitch() -> Bool {
        guard let previousReference = pendingSwitchPreviousDatabaseReference else { return false }
        pendingSwitchPreviousDatabaseReference = nil
        activeDatabaseReference = previousReference
        afterUnlock()
        return true
    }

    /// Zero-enabled-databases empty state: every interactive flow lands here
    /// when there is nothing the extension may unlock or save into.
    /// Dismissal cancels with `.userCanceled`, mirroring the search view's
    /// cancel path.
    func presentNoEnabledDatabasesState() {
        presenter?.presentNoEnabledDatabasesState { [weak self] in
            self?.cancelRequest(code: .userCanceled)
        }
    }

    private var biometricActionTitle: String {
        switch BiometricService.availableType {
        case .faceID: String(localized: "Use Face ID")
        case .touchID: String(localized: "Use Touch ID")
        case .none: String(localized: "Use Biometrics")
        }
    }

    private func runUnlockWork(_ work: @escaping @MainActor () async throws -> Void) async throws {
        #if DEBUG
        if let unlockWorkOverride {
            try await unlockWorkOverride()
            return
        }
        #endif
        try await work()
    }

    private func unlockWithPassword(_ password: String) {
        isUnlockInProgress = true
        let generation = requestGeneration
        unlockTask = Task { [weak self] in
            defer {
                if self?.requestGeneration == generation {
                    self?.isUnlockInProgress = false
                    self?.unlockTask = nil
                }
            }
            do {
                guard let self, self.isRequestActive(generation) else { return }
                let databaseReference = try currentDatabaseReference()

                try await runUnlockWork {
                    try await self.unlockPasswordWork(
                        password: password,
                        databaseReference: databaseReference,
                        generation: generation
                    )
                }
            } catch {
                guard let self, self.isRequestActive(generation) else { return }
                self.showErrorAndRetry(error)
            }
        }
    }

    private func unlockWithBiometrics() {
        isUnlockInProgress = true
        let generation = requestGeneration
        unlockTask = Task { [weak self] in
            defer {
                if self?.requestGeneration == generation {
                    self?.isUnlockInProgress = false
                    self?.unlockTask = nil
                }
            }
            do {
                guard let self, self.isRequestActive(generation) else { return }
                let databaseReference = try currentDatabaseReference()

                try await runUnlockWork {
                    try await self.unlockBiometricWork(
                        databaseReference: databaseReference,
                        generation: generation
                    )
                }
            } catch {
                guard let self, self.isRequestActive(generation) else { return }
                self.showErrorAndRetry(error)
            }
        }
    }

    private func unlockPasswordWork(
        password: String,
        databaseReference: DatabaseReference,
        generation: Int
    ) async throws {
        let keyFileData = try loadAssociatedKeyFileData(for: databaseReference)
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        try await loadEntries(
            compositeKey: compositeKey,
            databaseReference: databaseReference,
            generation: generation
        )
        guard isRequestActive(generation) else { return }
        persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
        recordSuccessfulUnlock(for: databaseReference)
        afterUnlock()
    }

    private func unlockBiometricWork(
        databaseReference: DatabaseReference,
        generation: Int
    ) async throws {
        let context = try await BiometricService.authenticate(reason: String(localized: "Unlock KeeForge for AutoFill"))
        AutoFillDiagnostics.log("biometric auth ok")
        let compositeKey = try retrieveCompositeKey(for: databaseReference, context: context)
        AutoFillDiagnostics.log("composite key retrieved")
        try await loadEntries(
            compositeKey: compositeKey,
            databaseReference: databaseReference,
            generation: generation
        )
        guard isRequestActive(generation) else { return }
        AutoFillDiagnostics.log("unlock ok entries=\(parsedEntries.count)")
        persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
        recordSuccessfulUnlock(for: databaseReference)
        afterUnlock()
    }

    private func afterUnlock() {
        guard !didFinishRequest else { return }
        if handlePendingPasskeyRegistrationIfNeeded() {
            // Handled by the shared passkey-registration flow.
        } else if let request = pendingPasskeyRequest {
            pendingPasskeyRequest = nil
            completeInteractivePasskeyRequest(request)
        } else if handlePendingSaveRequestIfNeeded() {
            // Handled by the iOS-only save-password flow.
        } else if let requestParameters = pendingPasskeyRequestParameters {
            presentPasskeyMatchesOrFinish(using: requestParameters)
        } else if hasPendingOTCRequest {
            if #available(iOS 18.0, macOS 15.0, *) {
                completeOTCRequestFromPending()
            }
        } else if hasPendingOTCListRequest {
            if #available(iOS 18.0, macOS 15.0, *) {
                presentOTCMatchesOrFinish()
            } else {
                cancelRequest(code: .failed)
            }
        } else {
            presentPasswordMatchesOrFinish()
        }
    }

    /// Handles a pending save-password request after unlock. Save-password is
    /// iOS-only (`ASSavePasswordRequest` is `API_UNAVAILABLE(macos)`); on macOS
    /// this is always a no-op that returns `false` so the unlock flow falls
    /// through to the next branch.
    private func handlePendingSaveRequestIfNeeded() -> Bool {
        #if os(iOS)
        guard #available(iOS 26.2, *), let savePasswordRequest = pendingSavePasswordRequest else {
            return false
        }
        pendingSavePasswordRequest = nil
        if parsedFormatVersion?.requiresReadOnlyMode == true {
            presentReadOnlyAlertAndCancel(
                message: String(localized: "Legacy KDBX 3.1 databases can be opened, but KeeForge only allows them in read-only mode.")
            )
            return true
        }
        presentEntryCreator(for: savePasswordRequest)
        return true
        #else
        return false
        #endif
    }

    /// Handles a pending passkey-registration request after unlock. Internal
    /// (not private) so unit tests can drive the post-unlock path directly.
    func handlePendingPasskeyRegistrationIfNeeded() -> Bool {
        guard let request = pendingPasskeyRegistrationRequest else { return false }
        pendingPasskeyRegistrationRequest = nil
        if parsedFormatVersion?.requiresReadOnlyMode == true {
            presentReadOnlyAlertAndCancel(
                message: String(localized: "Legacy KDBX 3.1 databases can be opened, but KeeForge only allows them in read-only mode.")
            )
            return true
        }
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            cancelRequest(code: .failed)
            return true
        }
        if hasExcludedCredentialMatch(for: request, identity: identity) {
            #if os(macOS)
            if #available(macOS 15.0, *) {
                cancelRequest(code: .matchedExcludedCredential)
            } else {
                cancelRequest(code: .failed)
            }
            #else
            cancelRequest(code: .matchedExcludedCredential)
            #endif
            return true
        }
        presentPasskeyCreator(for: request, identity: identity)
        return true
    }

    /// The database this request is pinned to. Resolution normally pins it
    /// before unlock (interactive flows via `resolveInteractiveRequestDatabase`,
    /// silent flows via `resolveSilentRequestDatabase`, save via its prepare
    /// path); the default-database fallback here only covers unlock calls
    /// that skipped resolution (e.g. tests driving the unlock helpers
    /// directly).
    private func currentDatabaseReference() throws -> DatabaseReference {
        if let activeDatabaseReference {
            return activeDatabaseReference
        }

        guard let databaseReference = DatabaseListStore.defaultAutoFillDatabase else {
            throw ASExtensionError(.failed)
        }

        activeDatabaseReference = databaseReference
        return databaseReference
    }

    private func recordSuccessfulUnlock(for databaseReference: DatabaseReference) {
        // A successful unlock commits any pending database switch: the
        // previous database's state has just been overwritten by the new
        // load, so there is nothing to fall back to anymore.
        pendingSwitchPreviousDatabaseReference = nil
        activeDatabaseReference = databaseReference
        DatabaseListStore.markDatabaseOpened(id: databaseReference.id)
    }

    private func persistCompositeKeyIfPossible(_ compositeKey: SymmetricKey, for databaseReference: DatabaseReference) {
        guard BiometricService.isAvailable else { return }

        do {
            try KeychainService.storeCompositeKey(compositeKey, for: databaseReference.id)
            if let legacyFilename = databaseReference.legacyKeychainFilename {
                KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
                DatabaseListStore.clearLegacyKeychainFilename(for: databaseReference.id)
                // Re-read the pinned reference by id so the in-session copy
                // drops the just-deleted legacy keychain filename. The active
                // pointer may legitimately be a different database now that
                // requests resolve their owning database, so it must not be
                // consulted here.
                activeDatabaseReference = DatabaseListStore.databases.first { $0.id == databaseReference.id }
                    ?? databaseReference
            }
        } catch {
            return
        }
    }

    private func retrieveCompositeKey(for databaseReference: DatabaseReference, context: LAContext) throws -> SymmetricKey {
        do {
            return try KeychainService.retrieveCompositeKey(for: databaseReference.id, context: context)
        } catch {
            guard KeychainService.isItemNotFound(error),
                  let legacyFilename = databaseReference.legacyKeychainFilename else {
                throw error
            }

            return try KeychainService.retrieveLegacyCompositeKey(forFilename: legacyFilename, context: context)
        }
    }

    private func loadAssociatedKeyFileData(for databaseReference: DatabaseReference) throws -> Data? {
        guard let url = DatabaseListStore.resolveKeyFileURL(for: databaseReference) else { return nil }
        return try readSecurityScoped(url: url)
    }

    private func clearPendingCreationRequests() {
        pendingGeneratePasswordPresentation = false
        // Only the save-prepare path sets this; reset it wherever creation
        // pendings are reset (every request entry point plus cleanup()).
        pendingNoEnabledDatabasesPresentation = false
        pendingPasskeyRegistrationRequest = nil
        pendingPasskeyRegistrationFailureMessage = nil
        #if os(iOS)
        if #available(iOS 26.2, *) {
            pendingSavePasswordRequest = nil
            pendingGeneratePasswordsRequest = nil
        }
        #endif
    }

    private func loadEntries(
        compositeKey: SymmetricKey,
        databaseReference: DatabaseReference,
        generation: Int
    ) async throws {
        let data = try loadDatabaseData(for: databaseReference)
        try AutoFillMemoryLimit.check(
            summary: KDBXFileSummary.inspect(data: data),
            remainingBytes: remainingMemoryBytes
        )
        let key = SymmetricKey(size: .bits256)

        let parsed = try await Task.detached {
            try KDBXParser.parseWithMetaAndHeader(
                data: data,
                compositeKey: compositeKey,
                sessionKey: key,
                kdfPolicy: .autoFillExtension
            )
        }.value

        guard isRequestActive(generation) else {
            throw RequestNoLongerActive()
        }

        self.sessionKey = key
        self.compositeKey = compositeKey
        self.openTimeSHA512 = KDBXCrypto.sha512(data)
        self.parsedRootGroup = parsed.rootGroup
        self.parsedMeta = parsed.meta
        self.parsedFormatVersion = parsed.header.formatVersion

        let offerableEntries = parsed.rootGroup.autoFillEntries(
            excludingGroupID: parsed.rootGroup.recycleBinUUID
        )
        parsedEntries = offerableEntries.filter { $0.hasPassword || $0.hasPasskey || $0.hasTOTP }
    }

    private var remainingMemoryBytes: UInt64 {
        #if DEBUG
        if let memoryBudgetOverride {
            return memoryBudgetOverride
        }
        #endif
        return AutoFillMemoryLimit.remainingBytes()
    }

    private func loadDatabaseData(for databaseReference: DatabaseReference) throws -> Data {
        if let cachedURL = DatabaseListStore.cachedDatabaseURL(for: databaseReference) {
            return try CoordinatedFileReader.readData(from: cachedURL)
        }

        guard let bookmarkedURL = DatabaseListStore.resolveDatabaseURL(for: databaseReference) else {
            throw NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue)
        }

        return try readSecurityScoped(url: bookmarkedURL)
    }

    private func readSecurityScoped(url: URL) throws -> Data {
        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try CoordinatedFileReader.readData(from: url)
    }

    // MARK: - Matching / interactive presentation

    func presentPasswordMatchesOrFinish() {
        let allPasswordEntries = parsedEntries.filter(\.hasPassword)
        let passwordEntries = allPasswordEntries.filter { !$0.isExpired() }

        if let recordIdentifier = targetRecordIdentifier {
            if let entry = entryMatching(recordIdentifier: recordIdentifier, in: passwordEntries) {
                completeRequest(with: entry)
                return
            }
            // The suggestion's entry is gone from its (successfully unlocked)
            // database: drop the stale identity, then fall through to the
            // interactive matching/search below.
            removeStaleIdentityIfEntryMissing(recordIdentifier: recordIdentifier)
        }

        let strictMatches = CredentialMatcher.strictMatchedEntries(from: passwordEntries, for: serviceIdentifiers)
        let matches = CredentialMatcher.matchedEntries(from: passwordEntries, for: serviceIdentifiers)
        let possibleMatches: [KPEntry]
        if strictMatches.isEmpty {
            let siblingMatches = CredentialMatcher.possibleMatchedEntries(from: passwordEntries, for: serviceIdentifiers)
            var seenIDs = Set<UUID>()
            possibleMatches = (matches + siblingMatches).filter { seenIDs.insert($0.id).inserted }
        } else {
            possibleMatches = []
        }

        AutoFillDiagnostics.log("passwordMatches all=\(allPasswordEntries.count) strict=\(strictMatches.count) matches=\(matches.count) possible=\(possibleMatches.count)")

        // Auto-complete without a picker only when the single candidate matched
        // on host, not on a weaker URL/title substring signal.
        if matches.count == 1, strictMatches.count == 1, let entry = strictMatches.first {
            completeRequest(with: entry)
            return
        }

        let searchDomain = serviceIdentifiers.first.flatMap { CredentialMatcher.searchTerm(for: $0) } ?? ""

        if !strictMatches.isEmpty {
            // Only strict host matches belong in the exact interactive section.
            presentSearchView(
                entries: strictMatches,
                searchEntries: allPasswordEntries,
                possibleEntries: [],
                initialSearchText: "",
                includesDatabaseSwitcher: true,
                includesEntryCreation: true
            ) { [weak self] entry in
                self?.completeRequest(with: entry)
            }
        } else {
            // With suggestions, keep the initial list limited to the separate
            // possible-match section. The full password list remains the
            // editable search corpus.
            presentSearchView(
                entries: possibleMatches.isEmpty ? allPasswordEntries : [],
                searchEntries: allPasswordEntries,
                possibleEntries: possibleMatches,
                initialSearchText: possibleMatches.isEmpty ? searchDomain : "",
                includesDatabaseSwitcher: true,
                includesEntryCreation: true
            ) { [weak self] entry in
                self?.completeRequest(with: entry)
            } onSelectPossible: { [weak self] entry in
                self?.completeRequest(with: entry)
            } onAddURLToPossible: { [weak self] entry in
                self?.addOriginalRequestURL(to: entry)
            }
        }
    }

    private func addOriginalRequestURL(to entry: KPEntry) {
        guard let rootGroup = parsedRootGroup,
              let meta = parsedMeta,
              let sessionKey,
              let compositeKey,
              let openTimeSHA512,
              let reference = activeDatabaseReference,
              let requestURL = serviceIdentifiers.first?.identifier else {
            cancelRequest(code: .failed)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let draft: EntryDraftPayload?
            do {
                draft = try await Task.detached(priority: .userInitiated) {
                    try Self.makeURLAdditionDraft(for: entry, requestURL: requestURL, sessionKey: sessionKey)
                }.value
            } catch {
                cancelRequest(code: .failed)
                return
            }
            guard let draft else {
                // The request URL's host is already stored on the entry.
                completeRequest(with: entry)
                return
            }
            do {
                let result = try await AutoFillSaveCoordinator.saveNewEntry(
                    draftPayload: draft,
                    reference: reference,
                    rootGroup: rootGroup,
                    meta: meta,
                    sessionKey: sessionKey,
                    compositeKey: compositeKey,
                    openTimeSHA512: openTimeSHA512,
                    edit: .updateEntry(entryID: entry.id, draft: draft)
                )
                guard case .saved(let outcome) = result else {
                    cancelRequest(code: .failed)
                    return
                }
                parsedRootGroup = outcome.savedRootGroup
                parsedEntries = outcome.savedRootGroup.autoFillEntries(excludingGroupID: outcome.savedRootGroup.recycleBinUUID)
                completeRequest(with: parsedEntries.first { $0.id == entry.id } ?? entry)
            } catch {
                cancelRequest(code: .failed)
            }
        }
    }

    /// Builds the update draft that appends `requestURL` as the next free
    /// `KP2A_URL_<n>` field, carrying every other field (including TOTP)
    /// forward unchanged. Returns nil when the URL's host is already stored.
    /// Kept off the main actor: it decrypts the entry's secrets.
    private nonisolated static func makeURLAdditionDraft(
        for entry: KPEntry,
        requestURL: String,
        sessionKey: SymmetricKey
    ) throws -> EntryDraftPayload? {
        let requestHost = CredentialMatcher.hostFromURLString(requestURL)
        let alreadyStored = requestHost.map { requestHost in
            ([entry.url] + entry.additionalURLs).contains { storedURL in
                guard let storedHost = CredentialMatcher.hostFromURLString(storedURL) else { return false }
                return storedHost == requestHost
            }
        } ?? false
        guard !alreadyStored else { return nil }

        var customFields = entry.customFields
        var index = 1
        while customFields["KP2A_URL_\(index)"] != nil { index += 1 }
        customFields["KP2A_URL_\(index)"] = requestURL

        let totpConfig = try entry.totpConfig.map { config in
            EntryDraftPayload.TOTPConfiguration(
                secret: try config.secret.decrypt(using: sessionKey),
                decodedSecret: try config.decodedSecret?.decryptData(using: sessionKey),
                keeOTPSource: config.keeOTPSource,
                period: config.period,
                digits: config.digits,
                algorithm: config.algorithm
            )
        }

        return EntryDraftPayload(
            title: entry.title,
            username: entry.username,
            password: try entry.password.decrypt(using: sessionKey),
            url: entry.url,
            notes: entry.notes,
            customFields: customFields,
            tags: entry.tags,
            totpConfig: totpConfig
        )
    }

    /// Matches a record identifier against entries of the request's resolved
    /// (and unlocked) database. Which database that is was decided earlier by
    /// `resolveRequestDatabase(forRecordIdentifier:)`; here both the current
    /// database-tagged format and the legacy bare-entry-UUID format match on
    /// the entry UUID alone. Unrecognized (stale) identifiers resolve to nil
    /// so every caller falls back to its not-found / interactive path.
    private func entryMatching(recordIdentifier: String, in entries: [KPEntry]) -> KPEntry? {
        guard let entryID = CredentialRecordIdentifier.parse(recordIdentifier).entryID else { return nil }
        return entries.first { $0.id == entryID }
    }

    private func findEntry(byRecordIdentifier recordIdentifier: String) -> KPEntry? {
        entryMatching(recordIdentifier: recordIdentifier, in: parsedEntries)
    }

    private func passkeyEntry(
        for identity: ASPasskeyCredentialIdentity,
        includeExpired: Bool = false
    ) -> KPEntry? {
        let normalizedRelyingParty = CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(identity.relyingPartyIdentifier)

        let matchesIdentity: (KPEntry) -> Bool = { entry in
            guard includeExpired || !entry.isExpired() else { return false }
            guard let passkey = entry.passkeyCredential,
                  let credentialIDData = passkey.credentialIDData
            else {
                return false
            }

            return CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(passkey.relyingParty) == normalizedRelyingParty &&
                credentialIDData == identity.credentialID
        }

        if let recordIdentifier = CredentialIdentityStoreManager.recordIdentifier(of: identity),
           let entry = findEntry(byRecordIdentifier: recordIdentifier),
           matchesIdentity(entry) {
            return entry
        }

        return parsedEntries.first(where: matchesIdentity)
    }

    private func matchingPasskeyEntries(
        for requestParameters: ASPasskeyCredentialRequestParameters,
        includeExpired: Bool = false
    ) -> [KPEntry] {
        let normalizedRelyingParty = CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(
            requestParameters.relyingPartyIdentifier
        )
        let allowedCredentialIDs = Set(requestParameters.allowedCredentials)

        return parsedEntries.filter { entry in
            guard includeExpired || !entry.isExpired() else { return false }
            guard let passkey = entry.passkeyCredential,
                  let credentialIDData = passkey.credentialIDData
            else {
                return false
            }

            guard CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(passkey.relyingParty) == normalizedRelyingParty else {
                return false
            }

            return allowedCredentialIDs.isEmpty || allowedCredentialIDs.contains(credentialIDData)
        }
    }

    private func presentPasskeyMatchesOrFinish(using requestParameters: ASPasskeyCredentialRequestParameters) {
        let expiredMatches = matchingPasskeyEntries(
            for: requestParameters,
            includeExpired: true
        ).filter { $0.isExpired() }
        presentPasskeyList(
            matches: matchingPasskeyEntries(for: requestParameters),
            expiredMatches: expiredMatches
        ) { [weak self] entry in
            self?.completePasskeyRequest(with: entry, requestParameters: requestParameters)
        }
    }

    /// List decision for a parameters-driven passkey request. Internal (not
    /// private) so unit tests can drive it: `ASPasskeyCredentialRequestParameters`
    /// is not constructible in tests, so the parameters stay in the thin
    /// wrapper above.
    func presentPasskeyList(
        matches: [KPEntry],
        expiredMatches: [KPEntry],
        onSelect complete: @escaping (KPEntry) -> Void
    ) {
        if matches.count == 1, let entry = matches.first {
            complete(entry)
            return
        }

        if !matches.isEmpty {
            presentSearchView(entries: matches, includesDatabaseSwitcher: true) { entry in
                complete(entry)
            }
            return
        }

        guard !expiredMatches.isEmpty else {
            // This request lists credentials of both kinds for the site, so a
            // vault with no matching passkey must fall back to the password
            // flow — cancelling here ends the request with no UI at all right
            // after a successful unlock.
            AutoFillDiagnostics.log("no passkey matches; falling back to password flow")
            presentPasswordMatchesOrFinish()
            return
        }

        presentSearchView(entries: expiredMatches, includesDatabaseSwitcher: true) { entry in
            complete(entry)
        }
    }

    /// Shared search-view presentation. `includesDatabaseSwitcher` is true for
    /// the genuine list/search flows (password, passkey-parameters, and OTC
    /// list pickers) whose pending request context survives a database switch;
    /// the by-identity expired-entry confirmations keep it false — they show a
    /// single specific credential of a specific database, and their pending
    /// request was already consumed, so a switch could not re-serve them.
    /// A search text stashed by a pending switch overrides the computed
    /// initial text so the re-presented search keeps what the user had typed.
    private func presentSearchView(
        entries: [KPEntry],
        searchEntries: [KPEntry]? = nil,
        possibleEntries: [KPEntry] = [],
        initialSearchText: String = "",
        includesDatabaseSwitcher: Bool = false,
        includesEntryCreation: Bool = false,
        onSelect: @escaping (KPEntry) -> Void,
        onSelectPossible: @escaping (KPEntry) -> Void = { _ in },
        onAddURLToPossible: @escaping (KPEntry) -> Void = { _ in }
    ) {
        let restoredSearchText = pendingSwitchSearchText
        pendingSwitchSearchText = nil
        presentWhenActive { [weak self] in
            guard let self else { return }
            presenter?.presentSearchView(
                entries: entries,
                searchEntries: searchEntries ?? entries,
                possibleEntries: possibleEntries,
                initialSearchText: restoredSearchText ?? initialSearchText,
                databaseSwitcher: includesDatabaseSwitcher ? makeDatabaseSwitcherContext() : nil,
                onCreateEntry: includesEntryCreation ? makeEntryCreationAction() : nil,
                onSelect: onSelect,
                onSelectPossible: onSelectPossible,
                onAddURLToPossible: onAddURLToPossible,
                onCancel: { [weak self] in
                    self?.cancelRequest(code: .userCanceled)
                }
            )
        }
    }

    /// The picker's "create a new credential" action, or nil when this request
    /// cannot produce one: creation writes to the database, so it needs iOS, a
    /// writable database, a KDBX 4 file, and a service identifier to derive the
    /// entry's name and URL from.
    private func makeEntryCreationAction() -> (() -> Void)? {
        #if os(iOS)
        guard let reference = activeDatabaseReference,
              reference.isReadOnly == false,
              parsedFormatVersion?.requiresReadOnlyMode != true,
              let serviceIdentifier = serviceIdentifiers.first else {
            return nil
        }
        return { [weak self] in
            self?.presentEntryCreator(for: serviceIdentifier)
        }
        #else
        return nil
        #endif
    }

    // Save-password / generate-password presentation is iOS-only (see note above).
    #if os(iOS)
    /// Picker-initiated creation. Unlike the save-password path this starts
    /// from an empty username and a freshly generated password — the account
    /// does not exist yet — and finishes by filling the form it was opened
    /// from, so the request completes with a credential rather than with
    /// `completeSavePasswordRequest`.
    private func presentEntryCreator(for serviceIdentifier: ASCredentialServiceIdentifier) {
        let initialDraft = AutoFillSaveCoordinator.initialDraft(
            for: serviceIdentifier,
            username: nil
        )

        presentWhenActive { [weak self] in
            guard let self else { return }
            presenter?.presentEntryCreator(
                initialDraft: initialDraft,
                allowsPasswordEditing: true,
                onSave: { [weak self] draftPayload in
                    guard let self else {
                        return .showError(String(localized: "The request is no longer available."))
                    }
                    return await self.saveNewEntryAndFill(draftPayload: draftPayload)
                },
                onCancel: { [weak self] in
                    self?.cancelRequest(code: .userCanceled)
                }
            )
        }
    }

    /// Saves the entry, then fills the form with it. The credential is built
    /// from the draft the user just confirmed rather than by locating the
    /// saved entry: the plaintext is already in hand, and a brand-new entry
    /// has no TOTP config for `completeRequest(with:)` to copy.
    private func saveNewEntryAndFill(
        draftPayload: EntryDraftPayload
    ) async -> CredentialProviderEntrySaveOutcome {
        let user = draftPayload.username.isEmpty ? draftPayload.title : draftPayload.username
        guard !user.isEmpty else {
            return .showError(String(localized: "Enter a title or username for this credential."))
        }

        // The field is editable here, so the generated password can be cleared.
        // Saving that would persist an entry `hasPassword` rejects — invisible
        // to AutoFill afterwards — and fill the form with an empty credential.
        guard !draftPayload.password.isEmpty else {
            return .showError(String(localized: "Enter a password for this credential."))
        }

        guard let reference = activeDatabaseReference,
              let parsedRootGroup,
              let parsedMeta,
              let sessionKey,
              let compositeKey,
              let openTimeSHA512 else {
            return .showError(SaveError.saveContextUnavailable.localizedDescription)
        }

        do {
            let result = try await AutoFillSaveCoordinator.saveNewEntry(
                draftPayload: draftPayload,
                reference: reference,
                rootGroup: parsedRootGroup,
                meta: parsedMeta,
                sessionKey: sessionKey,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512
            )

            switch result {
            case .saved(let outcome):
                self.parsedRootGroup = outcome.savedRootGroup
                self.openTimeSHA512 = outcome.newSHA512
                let credential = ASPasswordCredential(user: user, password: draftPayload.password)
                finishRequest { presenter in
                    presenter.completeRequest(withSelectedCredential: credential)
                }
                return .completed
            case .conflict:
                return .showWarningAndCancel(String(localized: "Database changed — open KeeForge to save"))
            }
        } catch {
            return .showError(error.localizedDescription)
        }
    }

    @available(iOS 26.2, *)
    private func presentEntryCreator(for savePasswordRequest: ASSavePasswordRequest) {
        let initialDraft = AutoFillSaveCoordinator.initialDraft(
            for: savePasswordRequest.serviceIdentifier,
            username: savePasswordRequest.credential.user,
            password: savePasswordRequest.credential.password
        )

        presentWhenActive { [weak self] in
            guard let self else { return }
            presenter?.presentEntryCreator(
                initialDraft: initialDraft,
                allowsPasswordEditing: false,
                onSave: { [weak self] draftPayload in
                    guard let self else {
                        return .showError(String(localized: "The request is no longer available."))
                    }
                    return await self.saveNewEntry(
                        draftPayload: draftPayload,
                        for: savePasswordRequest
                    )
                },
                onCancel: { [weak self] in
                    self?.cancelRequest(code: .userCanceled)
                }
            )
        }
    }

    @available(iOS 26.2, *)
    private func saveNewEntry(
        draftPayload: EntryDraftPayload,
        for _: ASSavePasswordRequest
    ) async -> CredentialProviderEntrySaveOutcome {
        guard let reference = activeDatabaseReference,
              let parsedRootGroup,
              let parsedMeta,
              let sessionKey,
              let compositeKey,
              let openTimeSHA512 else {
            return .showError(SaveError.saveContextUnavailable.localizedDescription)
        }

        do {
            let result = try await AutoFillSaveCoordinator.saveNewEntry(
                draftPayload: draftPayload,
                reference: reference,
                rootGroup: parsedRootGroup,
                meta: parsedMeta,
                sessionKey: sessionKey,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512
            )

            switch result {
            case .saved(let outcome):
                self.parsedRootGroup = outcome.savedRootGroup
                self.openTimeSHA512 = outcome.newSHA512
                finishRequest { presenter in
                    presenter.completeSavePasswordRequest()
                }
                return .completed
            case .conflict:
                return .showWarningAndCancel(String(localized: "Database changed — open KeeForge to save"))
            }
        } catch {
            return .showError(error.localizedDescription)
        }
    }
    #endif

    /// Whether any parsed entry already stores a passkey for the request's
    /// relying party whose credential ID appears in `excludedCredentials`
    /// (WebAuthn's "don't re-register on this authenticator" signal).
    private func hasExcludedCredentialMatch(
        for request: ASPasskeyCredentialRequest,
        identity: ASPasskeyCredentialIdentity
    ) -> Bool {
        let excluded = Set(excludedCredentialIDs(request))
        guard !excluded.isEmpty else { return false }
        let normalizedRelyingParty = CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(
            identity.relyingPartyIdentifier
        )
        return parsedEntries.contains { entry in
            guard let passkey = entry.passkeyCredential,
                  let credentialIDData = passkey.credentialIDData else { return false }
            return CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(passkey.relyingParty) == normalizedRelyingParty
                && excluded.contains(credentialIDData)
        }
    }

    private func presentPasskeyCreator(
        for request: ASPasskeyCredentialRequest,
        identity: ASPasskeyCredentialIdentity
    ) {
        let relyingPartyID = identity.relyingPartyIdentifier
        let userName = identity.userName
        let userHandle = identity.userHandle
        let clientDataHash = request.clientDataHash

        presentWhenActive { [weak self] in
            guard let self else { return }
            presenter?.presentPasskeyCreator(
                context: CredentialProviderPasskeyCreatorContext(
                    relyingPartyIdentifier: relyingPartyID,
                    userName: userName,
                    databaseName: activeDatabaseReference?.displayName ?? "",
                    initialTitle: relyingPartyID
                ),
                onSave: { [weak self] title in
                    guard let self else {
                        return .showError(String(localized: "The request is no longer available."))
                    }
                    return await self.savePasskeyEntry(
                        title: title,
                        relyingPartyID: relyingPartyID,
                        userName: userName,
                        userHandle: userHandle,
                        clientDataHash: clientDataHash
                    )
                },
                onCancel: { [weak self] in
                    self?.cancelRequest(code: .userCanceled)
                }
            )
        }
    }

    /// Everything the registration completion needs from the crypto step,
    /// generated off the main actor in one hop.
    private struct PasskeyRegistrationMaterial: Sendable {
        let credentialID: Data
        let privateKeyPEM: String
        let attestationObject: Data
    }

    /// Saves the new passkey entry FIRST and only then hands the registration
    /// credential to the system — the relying party must never receive a
    /// credential the database did not persist.
    private func savePasskeyEntry(
        title: String,
        relyingPartyID: String,
        userName: String,
        userHandle: Data,
        clientDataHash: Data
    ) async -> CredentialProviderEntrySaveOutcome {
        guard let reference = activeDatabaseReference,
              let parsedRootGroup,
              let parsedMeta,
              let sessionKey,
              let compositeKey,
              let openTimeSHA512 else {
            return .showError(SaveError.saveContextUnavailable.localizedDescription)
        }

        let material: PasskeyRegistrationMaterial
        do {
            material = try await Task.detached(priority: .userInitiated) {
                let credentialID = try PasskeyCrypto.generateCredentialID()
                let privateKey = PasskeyCrypto.generatePrivateKey()
                return PasskeyRegistrationMaterial(
                    credentialID: credentialID,
                    privateKeyPEM: privateKey.pemRepresentation,
                    attestationObject: PasskeyCrypto.buildAttestationObject(
                        relyingPartyID: relyingPartyID,
                        credentialID: credentialID,
                        privateKey: privateKey
                    )
                )
            }.value
        } catch {
            return .showError(error.localizedDescription)
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftPayload = EntryDraftPayload(
            title: trimmedTitle.isEmpty ? relyingPartyID : trimmedTitle,
            username: userName,
            url: "https://\(relyingPartyID)",
            customFields: [
                PasskeyCredential.credentialIDKey: base64URLEncode(material.credentialID),
                PasskeyCredential.privateKeyPEMKey: material.privateKeyPEM,
                PasskeyCredential.relyingPartyKey: relyingPartyID,
                PasskeyCredential.usernameKey: userName,
                PasskeyCredential.userHandleKey: base64URLEncode(userHandle),
            ],
            protectedCustomFieldKeys: [
                PasskeyCredential.credentialIDKey,
                PasskeyCredential.privateKeyPEMKey,
                PasskeyCredential.userHandleKey,
            ]
        )

        do {
            let result = try await AutoFillSaveCoordinator.saveNewEntry(
                draftPayload: draftPayload,
                reference: reference,
                rootGroup: parsedRootGroup,
                meta: parsedMeta,
                sessionKey: sessionKey,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512,
                environment: passkeySaveEnvironment
            )

            switch result {
            case .saved(let outcome):
                self.parsedRootGroup = outcome.savedRootGroup
                self.openTimeSHA512 = outcome.newSHA512
                let credential = ASPasskeyRegistrationCredential(
                    relyingParty: relyingPartyID,
                    clientDataHash: clientDataHash,
                    credentialID: material.credentialID,
                    attestationObject: material.attestationObject
                )
                finishRequest { presenter in
                    presenter.completeRegistrationRequest(using: credential)
                }
                return .completed
            case .conflict:
                return .showWarningAndCancel(String(localized: "Database changed — open KeeForge to save"))
            }
        } catch {
            return .showError(error.localizedDescription)
        }
    }

    #if os(iOS)
    @available(iOS 26.2, *)
    private func presentGeneratePasswordPrompt(
        for request: ASGeneratePasswordsRequest,
        password: String = PasswordGenerator.generate(options: SettingsService.passwordGeneratorOptions)
    ) {
        presenter?.presentGeneratedPassword(
            password,
            onUse: { [weak self] in
                self?.completeGeneratedPasswordRequest(password)
            },
            onRegenerate: { [weak self] in
                self?.presentGeneratePasswordPrompt(
                    for: request,
                    password: PasswordGenerator.generate(
                        options: SettingsService.passwordGeneratorOptions
                    )
                )
            },
            onCancel: { [weak self] in
                self?.cancelRequest(code: .userCanceled)
            }
        )
    }

    @available(iOS 26.2, *)
    private func completeGeneratedPasswordRequest(_ password: String) {
        finishRequest { presenter in
            presenter.completeGeneratePasswordRequest(passwords: [password])
        }
    }
    #endif

    func presentReadOnlyAlertAndCancel(message: String) {
        presentWhenActive { [weak self] in
            guard let self else { return }
            presenter?.presentReadOnlyNotice(message: message) { [weak self] in
                self?.cancelRequest(code: .userCanceled)
            }
        }
    }

    func presentPasskeyRegistrationFailureAndCancel(message: String) {
        presentWhenActive { [weak self] in
            guard let self else { return }
            presenter?.presentPasskeyRegistrationFailure(message: message) { [weak self] in
                self?.cancelRequest(code: .failed)
            }
        }
    }

    // MARK: - One-time code (TOTP) support

    private func provideOTCWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        beginRequest()
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let recordIdentifier = CredentialIdentityStoreManager.recordIdentifier(of: credentialRequest.credentialIdentity)
        guard let databaseReference = resolveSilentRequestDatabase(forRecordIdentifier: recordIdentifier) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics(for: databaseReference) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let generation = requestGeneration
        isUnlockInProgress = true
        unlockTask = Task { [weak self] in
            defer {
                if self?.requestGeneration == generation {
                    self?.isUnlockInProgress = false
                    self?.unlockTask = nil
                }
            }
            do {
                guard let self, self.isRequestActive(generation) else { return }
                let context = try await BiometricService.authenticate(reason: String(localized: "AutoFill with KeeForge"))
                let compositeKey = try self.retrieveCompositeKey(for: databaseReference, context: context)
                try await self.loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference,
                    generation: generation
                )
                guard self.isRequestActive(generation) else { return }
                self.persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                self.recordSuccessfulUnlock(for: databaseReference)

                if #available(iOS 18.0, macOS 15.0, *) {
                    let totpEntries = self.parsedEntries.filter { $0.hasTOTP && !$0.isExpired() }
                    if let recordIdentifier,
                       let entry = self.entryMatching(recordIdentifier: recordIdentifier, in: totpEntries) {
                        self.completeOTCRequest(with: entry)
                    } else {
                        self.removeStaleIdentityIfEntryMissing(recordIdentifier: recordIdentifier)
                        self.cancelRequest(code: .credentialIdentityNotFound)
                    }
                } else {
                    self.cancelRequest(code: .failed)
                }
            } catch {
                guard let self, self.isRequestActive(generation) else { return }
                self.cancelRequest(code: .userInteractionRequired)
            }
        }
    }

    // Internal (not private) so unit tests can drive the pending-OTC
    // resolution and stale-identity fallback without the system harness.
    @available(iOS 18.0, macOS 15.0, *)
    func completeOTCRequestFromPending() {
        hasPendingOTCRequest = false

        let totpEntries = parsedEntries.filter(\.hasTOTP)
        if let recordIdentifier = targetRecordIdentifier,
           let entry = entryMatching(recordIdentifier: recordIdentifier, in: totpEntries) {
            if entry.isExpired() {
                presentSearchView(entries: [entry]) { [weak self] selectedEntry in
                    self?.completeOTCRequest(with: selectedEntry)
                }
            } else {
                completeOTCRequest(with: entry)
            }
        } else {
            // The identity's record identifier is missing or stale (e.g. the
            // entry changed since the identity store was last populated).
            // Drop the stale identity, then fall back to the interactive
            // picker instead of failing. Re-arm the list flag so the request
            // now behaves like an OTC list request — a database switch from
            // the fallback picker re-runs the OTC picker after unlock.
            removeStaleIdentityIfEntryMissing(recordIdentifier: targetRecordIdentifier)
            hasPendingOTCListRequest = true
            presentOTCMatchesOrFinish()
        }
    }

    /// Interactive one-time-code selection: complete immediately on a single
    /// service match, otherwise present the picker (matches, or all TOTP
    /// entries with the domain pre-filled). Mirrors `presentPasswordMatchesOrFinish`.
    ///
    /// `hasPendingOTCListRequest` is deliberately NOT consumed here: it stays
    /// set until a completion path runs `cleanup()`, so `afterUnlock()` after
    /// a database switch (or an unlock retry) re-runs this OTC picker instead
    /// of falling through to the password list.
    @available(iOS 18.0, macOS 15.0, *)
    func presentOTCMatchesOrFinish() {
        let allTOTPEntries = parsedEntries.filter(\.hasTOTP)
        let totpEntries = allTOTPEntries.filter { !$0.isExpired() }

        guard !allTOTPEntries.isEmpty else {
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }

        let matches = CredentialMatcher.matchedEntries(from: totpEntries, for: serviceIdentifiers)
        let strictMatches = CredentialMatcher.orderedStrictMatchedEntries(from: totpEntries, for: serviceIdentifiers)

        // Auto-complete without a picker only when the most specific requested
        // service identifier resolves to exactly one host match. The picker
        // still offers the broader set, including weaker URL/title substring
        // signals, which are never safe to fill without an explicit choice.
        if strictMatches.count == 1, let entry = strictMatches.first {
            completeOTCRequest(with: entry)
            return
        }

        let searchDomain = serviceIdentifiers.first.flatMap { CredentialMatcher.searchTerm(for: $0) } ?? ""

        if !matches.isEmpty {
            // Narrowed to matches, but the whole TOTP corpus stays the search
            // and "Show All Credentials" set — as on the password path.
            presentSearchView(
                entries: matches,
                searchEntries: allTOTPEntries,
                initialSearchText: "",
                includesDatabaseSwitcher: true
            ) { [weak self] entry in
                self?.completeOTCRequest(with: entry)
            }
        } else {
            presentSearchView(entries: allTOTPEntries, initialSearchText: searchDomain, includesDatabaseSwitcher: true) { [weak self] entry in
                self?.completeOTCRequest(with: entry)
            }
        }
    }

    @available(iOS 18.0, macOS 15.0, *)
    func completeOTCRequest(with entry: KPEntry) {
        guard let totpConfig = entry.totpConfig,
              let sessionKey = sessionKey else {
            cancelRequest(code: .failed)
            return
        }

        let code = TOTPGenerator.generateCode(config: totpConfig, sessionKey: sessionKey)
        guard code != "------" else {
            cancelRequest(code: .failed)
            return
        }

        finishRequest { presenter in
            presenter.completeOneTimeCodeRequest(code: code)
        }
    }

    // MARK: - Cleanup lifecycle

    /// The extension's only "lock": clears the session key and all parsed vault
    /// state. Every completion helper below calls this before handing a
    /// credential or error to the shell.
    func cleanup() {
        parsedEntries = []
        parsedRootGroup = nil
        parsedMeta = nil
        parsedFormatVersion = nil
        sessionKey = nil
        compositeKey = nil
        openTimeSHA512 = nil
        activeDatabaseReference = nil
        targetRecordIdentifier = nil
        pendingReadOnlyCancellationMessage = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        hasPendingOTCListRequest = false
        pendingSwitchPreviousDatabaseReference = nil
        pendingSwitchSearchText = nil
        pendingPresentation = nil
        clearPendingCreationRequests()
    }

    // MARK: - Complete password request

    func completeRequest(with entry: KPEntry) {
        guard let decryptionKey = sessionKey else {
            cancelRequest(code: .failed)
            return
        }
        // Resolves against the whole tree, not `parsedEntries`: a `{REF:…}`
        // may point at a password-less entry or one in a non-searchable group.
        let resolver = FieldReferenceResolver(entries: parsedRootGroup?.allEntries ?? [], sessionKey: decryptionKey)
        let user = resolver.resolve(entry.username.isEmpty ? entry.title : entry.username)
        guard !user.isEmpty else {
            cancelRequest(code: .failed)
            return
        }

        let decryptedPassword = resolver.resolve((try? entry.password.decrypt(using: decryptionKey)) ?? "")

        #if os(iOS)
        // Opt-in convenience: many sites put the one-time code in a field iOS
        // does not recognize as an OTP field, so there is no second AutoFill
        // prompt to fill it from. Copying the current code alongside the
        // password fill lets the user just paste it. Must run before
        // `cleanup()`, which drops the session key the TOTP secret needs.
        copyTOTPCodeIfEnabled(for: entry, sessionKey: decryptionKey)
        #endif

        AutoFillDiagnostics.log("completing password fill")
        let credential = ASPasswordCredential(user: user, password: decryptedPassword)
        finishRequest { presenter in
            presenter.completeRequest(withSelectedCredential: credential)
        }
    }

    #if os(iOS)
    /// Whether filling `entry` should also put its verification code on the
    /// clipboard. Also the escalation test on the silent QuickType path: a
    /// no-UI credential extension cannot reliably write the pasteboard, so
    /// that path bounces to an interactive retry instead of copying.
    func shouldCopyTOTPCode(for entry: KPEntry) -> Bool {
        SettingsService.autoFillCopyTOTP && entry.hasTOTP
    }

    /// Best-effort: a code that cannot be generated is simply not copied — the
    /// password fill itself must never fail because of this convenience.
    private func copyTOTPCodeIfEnabled(for entry: KPEntry, sessionKey: SymmetricKey) {
        guard shouldCopyTOTPCode(for: entry), let totpConfig = entry.totpConfig else { return }

        let code = TOTPGenerator.generateCode(config: totpConfig, sessionKey: sessionKey)
        guard code != "------" else { return }

        copyToClipboard(code)
    }
    #endif

    // MARK: - Complete passkey request

    private func completePasskeyRequest(_ request: ASPasskeyCredentialRequest) throws {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
              let entry = passkeyEntry(for: identity) else {
            // The database unlocked but its passkey is gone: remove the stale
            // identity so the suggestion disappears instead of dead-tapping.
            removeStaleIdentityIfEntryMissing(
                recordIdentifier: CredentialIdentityStoreManager.recordIdentifier(of: request.credentialIdentity)
            )
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }

        try completePasskeyRequest(
            with: entry,
            relyingPartyID: identity.relyingPartyIdentifier,
            clientDataHash: request.clientDataHash
        )
    }

    // Internal (not private) so unit tests can drive the post-unlock passkey
    // path, including the stale-identity removal on a missing entry.
    func completeInteractivePasskeyRequest(_ request: ASPasskeyCredentialRequest) {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
              let entry = passkeyEntry(for: identity, includeExpired: true) else {
            // The database unlocked but its passkey is gone: remove the stale
            // identity so the suggestion disappears instead of dead-tapping.
            removeStaleIdentityIfEntryMissing(
                recordIdentifier: CredentialIdentityStoreManager.recordIdentifier(of: request.credentialIdentity)
            )
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }

        if entry.isExpired() {
            presentSearchView(entries: [entry]) { [weak self] selectedEntry in
                guard let self else { return }
                do {
                    try self.completePasskeyRequest(
                        with: selectedEntry,
                        relyingPartyID: identity.relyingPartyIdentifier,
                        clientDataHash: request.clientDataHash
                    )
                } catch {
                    self.showErrorAndRetry(error)
                }
            }
            return
        }

        do {
            try completePasskeyRequest(
                with: entry,
                relyingPartyID: identity.relyingPartyIdentifier,
                clientDataHash: request.clientDataHash
            )
        } catch {
            showErrorAndRetry(error)
        }
    }

    private func completePasskeyRequest(with entry: KPEntry, requestParameters: ASPasskeyCredentialRequestParameters) {
        do {
            try completePasskeyRequest(
                with: entry,
                relyingPartyID: requestParameters.relyingPartyIdentifier,
                clientDataHash: requestParameters.clientDataHash
            )
        } catch {
            showErrorAndRetry(error)
        }
    }

    func completePasskeyRequest(with entry: KPEntry, relyingPartyID: String, clientDataHash: Data) throws {
        guard let passkey = entry.passkeyCredential,
              let credentialIDData = passkey.credentialIDData,
              let userHandleData = passkey.userHandleData,
              let sessionKey
        else {
            cancelRequest(code: .failed)
            return
        }

        // Decrypt the PEM just-in-time for signing; the plaintext string is
        // not retained beyond constructing the CryptoKit key.
        let privateKey = try PasskeyCrypto.privateKey(
            fromPEM: passkey.privateKeyPEM(using: sessionKey)
        )

        let (authenticatorData, signature) = try PasskeyCrypto.signAssertion(
            relyingPartyID: relyingPartyID,
            clientDataHash: clientDataHash,
            privateKey: privateKey
        )

        let credential = ASPasskeyAssertionCredential(
            userHandle: userHandleData,
            relyingParty: relyingPartyID,
            signature: signature,
            clientDataHash: clientDataHash,
            authenticatorData: authenticatorData,
            credentialID: credentialIDData
        )

        finishRequest { presenter in
            presenter.completeAssertionRequest(using: credential)
        }
    }

    // MARK: - Error handling

    func cancelRequest(code: ASExtensionError.Code) {
        AutoFillDiagnostics.log("cancelRequest code=\(code.rawValue) finished=\(didFinishRequest)")
        finishRequest { presenter in
            presenter.cancelRequest(withError: ASExtensionError(code))
        }
    }

    /// Gates the terminal handoff exactly once and captures the presenter for
    /// the completion action before cleanup clears coordinator state.
    /// The shell may disappear while an async unlock or dismissal is settling;
    /// this prevents duplicate context calls and avoids optional chaining on a
    /// completion path that must be observable.
    private func finishRequest(_ action: (any CredentialProviderPresenting) -> Void) {
        guard !didFinishRequest else { return }
        didFinishRequest = true
        requestGeneration &+= 1
        unlockTask?.cancel()
        unlockTask = nil
        isUnlockInProgress = false
        let presenter = presenter
        cleanup()
        guard let presenter else { return }
        action(presenter)
    }

    private func showErrorAndRetry(_ error: Error) {
        let nsError = error as NSError
        AutoFillDiagnostics.log("unlock error \(nsError.domain)#\(nsError.code)")
        let message = error.localizedDescription
        presentWhenActive { [weak self] in
            guard let self else { return }
            presenter?.presentUnlockError(
                message: message,
                onRetry: { [weak self] in
                    self?.presentUnlockPromptIfNeeded()
                },
                onCancel: { [weak self] in
                    // During a pending database switch (e.g. wrong password or a
                    // cancelled biometric prompt for the switched-to database),
                    // cancelling falls back to the previous database.
                    self?.cancelRequestOrRestoreSwitchedDatabase()
                }
            )
        }
    }
}
