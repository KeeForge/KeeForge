import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication

// Platform-neutral AutoFill request coordinator.
//
// This file must stay free of UIKit (and AppKit): it owns request handling,
// vault access/unlock orchestration, credential matching, passkey assertion,
// and the cleanup() lifecycle, while all presentation and extension-context
// calls go through the narrow `CredentialProviderPresenting` seam so an iOS
// (UIKit) or macOS (AppKit) shell can host it unchanged.

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

    // MARK: "Present this view"

    /// `databaseSwitcher` is non-nil only when the search UI should offer the
    /// in-search database switcher (two or more AutoFill-enabled databases).
    /// Shells wrap its `onSwitch` in their dismissal handling, exactly like
    /// `onSelect`/`onCancel`.
    func presentSearchView(
        entries: [KPEntry],
        initialSearchText: String,
        databaseSwitcher: CredentialProviderDatabaseSwitcherContext?,
        onSelect: @escaping (KPEntry) -> Void,
        onCancel: @escaping () -> Void
    )

    func presentEntryCreator(
        initialDraft: EntryDraftPayload,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
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

    func presentGeneratedPassword(
        _ password: String,
        onUse: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )

    // MARK: "Complete with this credential/error"

    func completeRequest(withSelectedCredential credential: ASPasswordCredential)
    func completeAssertionRequest(using credential: ASPasskeyAssertionCredential)
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
    var compositeKey: Data?
    var openTimeSHA512: Data?
    var activeDatabaseReference: DatabaseReference?
    var targetRecordIdentifier: String?
    var pendingPasskeyRequest: ASPasskeyCredentialRequest?
    var pendingPasskeyRequestParameters: ASPasskeyCredentialRequestParameters?
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

    private var isUnlockInProgress = false
    private var didAttemptAutoBiometricUnlock = false

    #if os(iOS)
    /// Clipboard write used by the opt-in "copy verification code on AutoFill"
    /// behavior. Injectable so unit tests can observe the copy without touching
    /// the real `UIPasteboard`. Defaults to `ClipboardService.copy`, which
    /// stamps the write with the Clipboard Clear Timeout as a system-enforced
    /// expiration date — the copy therefore expires even though the extension
    /// process is gone by then.
    var copyToClipboard: @MainActor (String) -> Void = { ClipboardService.copy($0) }
    #endif

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

    func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
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
        serviceIdentifiers = [credentialIdentity.serviceIdentifier]
        targetRecordIdentifier = credentialIdentity.recordIdentifier
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
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            pendingPasskeyRequest = passkeyRequest
            pendingPasskeyRequestParameters = nil
            targetRecordIdentifier = passkeyRequest.credentialIdentity.recordIdentifier
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
            targetRecordIdentifier = credentialRequest.credentialIdentity.recordIdentifier
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = true
            activatePresentationIfPossible()
        } else {
            cancelRequest(code: .failed)
        }
    }

    func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
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
        if pendingUnlock {
            pendingUnlock = false
            presentUnlockPromptIfNeeded()
        } else if pendingNoEnabledDatabasesPresentation {
            pendingNoEnabledDatabasesPresentation = false
            presentNoEnabledDatabasesState()
        } else if let pendingReadOnlyCancellationMessage {
            self.pendingReadOnlyCancellationMessage = nil
            presentReadOnlyAlertAndCancel(message: pendingReadOnlyCancellationMessage)
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

    private func activatePresentationIfPossible() {
        guard presenter?.isPresentationActive == true else { return }

        // Defer until the request callback has returned before asking UIKit or
        // AppKit to present another controller or alert.
        Task { @MainActor [weak self] in
            guard let self, presenter?.isPresentationActive == true else { return }
            presentationDidBecomeActive()
        }
    }

    func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let recordIdentifier = credentialIdentity.recordIdentifier

        // Resolve the owning database before evaluating biometrics: the
        // request must unlock the database that published the identity, and
        // its keychain state — not the active database's — decides whether a
        // zero-interaction unlock is possible.
        guard let databaseReference = resolveSilentRequestDatabase(forRecordIdentifier: recordIdentifier) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics(for: databaseReference) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        Task {
            do {
                let context = try await BiometricService.authenticate(reason: String(localized: "AutoFill with KeeForge"))
                let compositeKey = try retrieveCompositeKey(for: databaseReference, context: context)
                try await loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference
                )
                persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                recordSuccessfulUnlock(for: databaseReference)
                let passwordEntries = parsedEntries.filter { $0.hasPassword && !$0.isExpired() }

                if let recordIdentifier,
                   let entry = entryMatching(recordIdentifier: recordIdentifier, in: passwordEntries) {
                    guard !mustEscalateToInteractiveFill(for: entry) else {
                        cancelRequest(code: .userInteractionRequired)
                        return
                    }
                    completeRequest(with: entry)
                } else {
                    removeStaleIdentityIfEntryMissing(recordIdentifier: recordIdentifier)
                    // Zero-interaction fallback: only an unambiguous host-based
                    // match may be filled without the user picking an entry.
                    let matches = CredentialMatcher.strictMatchedEntries(
                        from: passwordEntries,
                        for: [credentialIdentity.serviceIdentifier]
                    )
                    if matches.count == 1, let entry = matches.first {
                        guard !mustEscalateToInteractiveFill(for: entry) else {
                            cancelRequest(code: .userInteractionRequired)
                            return
                        }
                        completeRequest(with: entry)
                    } else if matches.isEmpty {
                        cancelRequest(code: .credentialIdentityNotFound)
                    } else {
                        cancelRequest(code: .userInteractionRequired)
                    }
                }
            } catch {
                cancelRequest(code: .userInteractionRequired)
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
        cancelRequest(code: .failed)
    }

    // Save-password / generate-password requests are iOS-only (see note above).
    #if os(iOS)
    @available(iOS 26.2, *)
    func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
        cancelRequest(code: .userInteractionRequired)
    }

    @available(iOS 26.2, *)
    func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
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
        let password = PasswordGenerator.generate()
        cleanup()
        presenter?.completeGeneratePasswordRequest(passwords: [password])
    }

    @available(iOS 26.2, *)
    func prepareInterface(for generatePasswordsRequest: ASGeneratePasswordsRequest) {
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
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        // Passkey assertions resolve their owning database exactly like
        // password fills: by the identity's record identifier.
        guard let databaseReference = resolveSilentRequestDatabase(
            forRecordIdentifier: request.credentialIdentity.recordIdentifier
        ) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics(for: databaseReference) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        Task {
            do {
                let context = try await BiometricService.authenticate(reason: String(localized: "Passkey sign-in with KeeForge"))
                let compositeKey = try retrieveCompositeKey(for: databaseReference, context: context)
                try await loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference
                )
                persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                recordSuccessfulUnlock(for: databaseReference)

                try completePasskeyRequest(request)
            } catch {
                cancelRequest(code: .userInteractionRequired)
            }
        }
    }

    // MARK: - Unlock flow

    func presentUnlockPromptIfNeeded() {
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
            didAttemptAutoBiometricUnlock = true
            unlockWithBiometrics()
            return
        }

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

    /// Silent-flow resolution: nil means the request cannot proceed without
    /// interaction (stale identifier — cleanup already scheduled — or no
    /// enabled database). Callers cancel with `.userInteractionRequired` so
    /// the system relaunches the extension interactively, where the fallback
    /// search or empty state takes over.
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

    private func unlockWithPassword(_ password: String) {
        isUnlockInProgress = true
        Task {
            defer { isUnlockInProgress = false }
            do {
                let databaseReference = try currentDatabaseReference()
                let keyFileData = try loadAssociatedKeyFileData(for: databaseReference)
                let compositeKey = KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
                try await loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference
                )
                persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                recordSuccessfulUnlock(for: databaseReference)
                afterUnlock()
            } catch {
                showErrorAndRetry(error)
            }
        }
    }

    private func unlockWithBiometrics() {
        isUnlockInProgress = true
        Task {
            defer { isUnlockInProgress = false }
            do {
                let databaseReference = try currentDatabaseReference()

                let context = try await BiometricService.authenticate(reason: String(localized: "Unlock KeeForge for AutoFill"))
                let compositeKey = try retrieveCompositeKey(for: databaseReference, context: context)
                try await loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference
                )
                persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                recordSuccessfulUnlock(for: databaseReference)
                afterUnlock()
            } catch {
                showErrorAndRetry(error)
            }
        }
    }

    private func afterUnlock() {
        if let request = pendingPasskeyRequest {
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

    private func persistCompositeKeyIfPossible(_ compositeKey: Data, for databaseReference: DatabaseReference) {
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

    private func retrieveCompositeKey(for databaseReference: DatabaseReference, context: LAContext) throws -> Data {
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
        #if os(iOS)
        if #available(iOS 26.2, *) {
            pendingSavePasswordRequest = nil
            pendingGeneratePasswordsRequest = nil
        }
        #endif
    }

    private func loadEntries(
        compositeKey: Data,
        databaseReference: DatabaseReference
    ) async throws {
        let data = try loadDatabaseData(for: databaseReference)
        let key = SymmetricKey(size: .bits256)

        let parsed = try await Task.detached {
            try KDBXParser.parseWithMetaAndHeader(
                data: data,
                compositeKey: compositeKey,
                sessionKey: key
            )
        }.value

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

        // If we have a target recordIdentifier from QuickType, jump directly to that entry
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

        let matches = CredentialMatcher.matchedEntries(from: passwordEntries, for: serviceIdentifiers)
        let strictMatches = CredentialMatcher.strictMatchedEntries(from: passwordEntries, for: serviceIdentifiers)

        // Auto-complete without a picker only when the single candidate matched
        // on host, not on a weaker URL/title substring signal.
        if matches.count == 1, strictMatches.count == 1, let entry = strictMatches.first {
            completeRequest(with: entry)
            return
        }

        // Show search view — use matches if available, otherwise full list with pre-filled search
        let searchDomain = serviceIdentifiers.first.flatMap { CredentialMatcher.searchTerm(for: $0) } ?? ""

        if !matches.isEmpty {
            // Multiple matches — show them, with domain pre-filled for further filtering
            presentSearchView(entries: matches, initialSearchText: "", includesDatabaseSwitcher: true) { [weak self] entry in
                self?.completeRequest(with: entry)
            }
        } else {
            // No matches — show full list but pre-fill search with the domain
            presentSearchView(entries: allPasswordEntries, initialSearchText: searchDomain, includesDatabaseSwitcher: true) { [weak self] entry in
                self?.completeRequest(with: entry)
            }
        }
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

        if let recordIdentifier = identity.recordIdentifier,
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
        let matches = matchingPasskeyEntries(for: requestParameters)
        if matches.count == 1, let entry = matches.first {
            completePasskeyRequest(with: entry, requestParameters: requestParameters)
            return
        }

        if !matches.isEmpty {
            presentSearchView(entries: matches, includesDatabaseSwitcher: true) { [weak self] entry in
                self?.completePasskeyRequest(with: entry, requestParameters: requestParameters)
            }
            return
        }

        let expiredMatches = matchingPasskeyEntries(
            for: requestParameters,
            includeExpired: true
        ).filter { $0.isExpired() }
        guard !expiredMatches.isEmpty else {
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }

        presentSearchView(entries: expiredMatches, includesDatabaseSwitcher: true) { [weak self] entry in
            self?.completePasskeyRequest(with: entry, requestParameters: requestParameters)
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
        initialSearchText: String = "",
        includesDatabaseSwitcher: Bool = false,
        onSelect: @escaping (KPEntry) -> Void
    ) {
        let restoredSearchText = pendingSwitchSearchText
        pendingSwitchSearchText = nil
        presenter?.presentSearchView(
            entries: entries,
            initialSearchText: restoredSearchText ?? initialSearchText,
            databaseSwitcher: includesDatabaseSwitcher ? makeDatabaseSwitcherContext() : nil,
            onSelect: onSelect,
            onCancel: { [weak self] in
                self?.cancelRequest(code: .userCanceled)
            }
        )
    }

    // Save-password / generate-password presentation is iOS-only (see note above).
    #if os(iOS)
    @available(iOS 26.2, *)
    private func presentEntryCreator(for savePasswordRequest: ASSavePasswordRequest) {
        let initialDraft = AutoFillSaveCoordinator.initialDraft(
            for: savePasswordRequest.serviceIdentifier,
            username: savePasswordRequest.credential.user,
            password: savePasswordRequest.credential.password
        )

        presenter?.presentEntryCreator(
            initialDraft: initialDraft,
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
                cleanup()
                presenter?.completeSavePasswordRequest()
                return .completed
            case .conflict:
                return .showWarningAndCancel(String(localized: "Database changed — open KeeForge to save"))
            }
        } catch {
            return .showError(error.localizedDescription)
        }
    }

    @available(iOS 26.2, *)
    private func presentGeneratePasswordPrompt(
        for request: ASGeneratePasswordsRequest,
        password: String = PasswordGenerator.generate()
    ) {
        presenter?.presentGeneratedPassword(
            password,
            onUse: { [weak self] in
                self?.completeGeneratedPasswordRequest(password)
            },
            onRegenerate: { [weak self] in
                self?.presentGeneratePasswordPrompt(
                    for: request,
                    password: PasswordGenerator.generate()
                )
            },
            onCancel: { [weak self] in
                self?.cancelRequest(code: .userCanceled)
            }
        )
    }

    @available(iOS 26.2, *)
    private func completeGeneratedPasswordRequest(_ password: String) {
        cleanup()
        presenter?.completeGeneratePasswordRequest(passwords: [password])
    }
    #endif

    func presentReadOnlyAlertAndCancel(message: String) {
        presenter?.presentReadOnlyNotice(message: message) { [weak self] in
            self?.cancelRequest(code: .userCanceled)
        }
    }

    // MARK: - One-time code (TOTP) support

    private func provideOTCWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let recordIdentifier = credentialRequest.credentialIdentity.recordIdentifier

        // One-time-code requests resolve their owning database exactly like
        // password fills: by the identity's record identifier.
        guard let databaseReference = resolveSilentRequestDatabase(forRecordIdentifier: recordIdentifier) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics(for: databaseReference) else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        Task {
            do {
                let context = try await BiometricService.authenticate(reason: String(localized: "AutoFill with KeeForge"))
                let compositeKey = try retrieveCompositeKey(for: databaseReference, context: context)
                try await loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference
                )
                persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                recordSuccessfulUnlock(for: databaseReference)

                if #available(iOS 18.0, macOS 15.0, *) {
                    let totpEntries = parsedEntries.filter { $0.hasTOTP && !$0.isExpired() }
                    if let recordIdentifier,
                       let entry = entryMatching(recordIdentifier: recordIdentifier, in: totpEntries) {
                        completeOTCRequest(with: entry)
                    } else {
                        removeStaleIdentityIfEntryMissing(recordIdentifier: recordIdentifier)
                        cancelRequest(code: .credentialIdentityNotFound)
                    }
                } else {
                    cancelRequest(code: .failed)
                }
            } catch {
                cancelRequest(code: .userInteractionRequired)
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
        let strictMatches = CredentialMatcher.strictMatchedEntries(from: totpEntries, for: serviceIdentifiers)

        // Auto-complete without a picker only when the single candidate matched
        // on host, not on a weaker URL/title substring signal.
        if matches.count == 1, strictMatches.count == 1, let entry = strictMatches.first {
            completeOTCRequest(with: entry)
            return
        }

        let searchDomain = serviceIdentifiers.first.flatMap { CredentialMatcher.searchTerm(for: $0) } ?? ""

        if !matches.isEmpty {
            presentSearchView(entries: matches, initialSearchText: "", includesDatabaseSwitcher: true) { [weak self] entry in
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

        cleanup()
        presenter?.completeOneTimeCodeRequest(code: code)
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
        clearPendingCreationRequests()
    }

    // MARK: - Complete password request

    func completeRequest(with entry: KPEntry) {
        let user = entry.username.isEmpty ? entry.title : entry.username
        guard !user.isEmpty, let decryptionKey = sessionKey else {
            cancelRequest(code: .failed)
            return
        }

        let decryptedPassword = (try? entry.password.decrypt(using: decryptionKey)) ?? ""

        #if os(iOS)
        // Opt-in convenience: many sites put the one-time code in a field iOS
        // does not recognize as an OTP field, so there is no second AutoFill
        // prompt to fill it from. Copying the current code alongside the
        // password fill lets the user just paste it. Must run before
        // `cleanup()`, which drops the session key the TOTP secret needs.
        copyTOTPCodeIfEnabled(for: entry, sessionKey: decryptionKey)
        #endif

        cleanup()
        let credential = ASPasswordCredential(user: user, password: decryptedPassword)
        presenter?.completeRequest(withSelectedCredential: credential)
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
            removeStaleIdentityIfEntryMissing(recordIdentifier: request.credentialIdentity.recordIdentifier)
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
            removeStaleIdentityIfEntryMissing(recordIdentifier: request.credentialIdentity.recordIdentifier)
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

        cleanup()
        presenter?.completeAssertionRequest(using: credential)
    }

    // MARK: - Error handling

    func cancelRequest(code: ASExtensionError.Code) {
        cleanup()
        presenter?.cancelRequest(withError: ASExtensionError(code))
    }

    private func showErrorAndRetry(_ error: Error) {
        presenter?.presentUnlockError(
            message: error.localizedDescription,
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
