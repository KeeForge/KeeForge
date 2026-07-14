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

/// The narrow seam between the coordinator and a platform presentation shell.
///
/// The shell needs no knowledge of matching or vault logic; the surface is
/// limited to "present this view", "ask this question", and "complete with
/// this credential/error". The coordinator always tears down vault state via
/// `cleanup()` before asking the shell to complete or cancel the request.
@MainActor
protocol CredentialProviderPresenting: AnyObject {
    /// Whether the shell is currently showing modal content. Used to avoid
    /// double-presenting the unlock prompt (mirrors `presentedViewController != nil`).
    var isDisplayingContent: Bool { get }

    // MARK: "Present this view"

    func presentSearchView(
        entries: [KPEntry],
        initialSearchText: String,
        onSelect: @escaping (KPEntry) -> Void,
        onCancel: @escaping () -> Void
    )

    func presentEntryCreator(
        initialDraft: EntryDraftPayload,
        onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
        onCancel: @escaping () -> Void
    )

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
    var pendingGeneratePasswordPresentation = false
    var pendingReadOnlyCancellationMessage: String?
    var pendingSavePasswordRequestStorage: Any?
    var pendingGeneratePasswordsRequestStorage: Any?
    var pendingUnlock = false

    private var isUnlockInProgress = false
    private var didAttemptAutoBiometricUnlock = false

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
        clearPendingCreationRequests()
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = true
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
    }

    func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            pendingPasskeyRequest = passkeyRequest
            pendingPasskeyRequestParameters = nil
            targetRecordIdentifier = passkeyRequest.credentialIdentity.recordIdentifier
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = true
        } else if let passwordIdentity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            prepareInterfaceToProvideCredential(for: passwordIdentity)
        } else if #available(iOS 18.0, macOS 15.0, *), credentialRequest is ASOneTimeCodeCredentialRequest {
            hasPendingOTCRequest = true
            targetRecordIdentifier = credentialRequest.credentialIdentity.recordIdentifier
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = true
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

    /// Called by the shell once its view hierarchy is on screen (viewWillAppear).
    func presentationDidBecomeActive() {
        if pendingUnlock {
            pendingUnlock = false
            presentUnlockPromptIfNeeded()
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

    func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let recordIdentifier = credentialIdentity.recordIdentifier

        Task {
            do {
                let databaseReference = try currentDatabaseReference()

                let context = try await BiometricService.authenticate(reason: "AutoFill with KeeForge")
                let compositeKey = try retrieveCompositeKey(for: databaseReference, context: context)
                try await loadEntries(
                    compositeKey: compositeKey,
                    databaseReference: databaseReference
                )
                persistCompositeKeyIfPossible(compositeKey, for: databaseReference)
                recordSuccessfulUnlock(for: databaseReference)
                let passwordEntries = parsedEntries.filter { $0.hasPassword && !$0.isExpired() }

                if let recordIdentifier,
                   let entry = passwordEntries.first(where: { $0.id.uuidString == recordIdentifier }) {
                    completeRequest(with: entry)
                } else {
                    let matches = CredentialMatcher.matchedEntries(
                        from: passwordEntries,
                        for: [credentialIdentity.serviceIdentifier]
                    )
                    if let entry = matches.first {
                        completeRequest(with: entry)
                    } else {
                        cancelRequest(code: .credentialIdentityNotFound)
                    }
                }
            } catch {
                cancelRequest(code: .userInteractionRequired)
            }
        }
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
        guard let databaseReference = DatabaseListStore.activeAutoFillDatabase else {
            cancelRequest(code: .failed)
            return
        }

        guard databaseReference.isReadOnly == false else {
            serviceIdentifiers = [savePasswordRequest.serviceIdentifier]
            targetRecordIdentifier = nil
            pendingPasskeyRequest = nil
            pendingPasskeyRequestParameters = nil
            hasPendingOTCRequest = false
            clearPendingCreationRequests()
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = false
            pendingGeneratePasswordPresentation = false
            pendingReadOnlyCancellationMessage = "This database is read-only. Open KeeForge to enable editing."
            return
        }

        serviceIdentifiers = [savePasswordRequest.serviceIdentifier]
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        pendingGeneratePasswordsRequest = nil
        pendingSavePasswordRequest = savePasswordRequest
        didAttemptAutoBiometricUnlock = false
        pendingGeneratePasswordPresentation = false
        pendingUnlock = true
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
        pendingSavePasswordRequest = nil
        pendingGeneratePasswordsRequest = generatePasswordsRequest
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = false
        pendingGeneratePasswordPresentation = true
    }
    #endif

    // MARK: - Passkey silent auth

    private func providePasskeyWithoutUserInteraction(for request: ASPasskeyCredentialRequest) {
        guard SettingsService.quickAutoFillEnabled else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        guard canUseBiometrics else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        Task {
            do {
                let databaseReference = try currentDatabaseReference()

                let context = try await BiometricService.authenticate(reason: "Passkey sign-in with KeeForge")
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

        if shouldAutoUnlockWithBiometrics {
            didAttemptAutoBiometricUnlock = true
            unlockWithBiometrics()
            return
        }

        presenter?.presentUnlockPrompt(
            biometricOptionTitle: canUseBiometrics ? biometricActionTitle : nil,
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
                self?.cancelRequest(code: .userCanceled)
            }
        )
    }

    private var shouldAutoUnlockWithBiometrics: Bool {
        guard !didAttemptAutoBiometricUnlock else { return false }
        guard SettingsService.autoUnlockWithFaceID else { return false }
        return canUseBiometrics
    }

    private var canUseBiometrics: Bool {
        guard BiometricService.isAvailable else { return false }
        guard let databaseReference = DatabaseListStore.activeAutoFillDatabase else { return false }
        return KeychainService.hasStoredKey(
            for: databaseReference.id,
            legacyFilename: databaseReference.legacyKeychainFilename
        )
    }

    private var biometricActionTitle: String {
        switch BiometricService.availableType {
        case .faceID: "Use Face ID"
        case .touchID: "Use Touch ID"
        case .none: "Use Biometrics"
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

                let context = try await BiometricService.authenticate(reason: "Unlock KeeForge for AutoFill")
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
                message: "Legacy KDBX 3.1 databases can be opened, but KeeForge only allows them in read-only mode."
            )
            return true
        }
        presentEntryCreator(for: savePasswordRequest)
        return true
        #else
        return false
        #endif
    }

    private func currentDatabaseReference() throws -> DatabaseReference {
        if let activeDatabaseReference {
            return activeDatabaseReference
        }

        guard let databaseReference = DatabaseListStore.activeAutoFillDatabase else {
            throw ASExtensionError(.failed)
        }

        activeDatabaseReference = databaseReference
        return databaseReference
    }

    private func recordSuccessfulUnlock(for databaseReference: DatabaseReference) {
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
                activeDatabaseReference = DatabaseListStore.activeAutoFillDatabase
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

        let allEntries: [KPEntry]
        if let recycleBinID = parsed.rootGroup.recycleBinUUID {
            allEntries = parsed.rootGroup.allEntries(excludingGroupID: recycleBinID)
        } else {
            allEntries = parsed.rootGroup.allEntries
        }
        parsedEntries = allEntries.filter { $0.hasPassword || $0.hasPasskey || $0.hasTOTP }
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
        if let recordIdentifier = targetRecordIdentifier,
           let entry = passwordEntries.first(where: { $0.id.uuidString == recordIdentifier }) {
            completeRequest(with: entry)
            return
        }

        let matches = CredentialMatcher.matchedEntries(from: passwordEntries, for: serviceIdentifiers)

        if matches.count == 1, let entry = matches.first {
            completeRequest(with: entry)
            return
        }

        // Show search view — use matches if available, otherwise full list with pre-filled search
        let searchDomain = serviceIdentifiers.first.flatMap { CredentialMatcher.searchTerm(for: $0) } ?? ""

        if !matches.isEmpty {
            // Multiple matches — show them, with domain pre-filled for further filtering
            presentSearchView(entries: matches, initialSearchText: "") { [weak self] entry in
                self?.completeRequest(with: entry)
            }
        } else {
            // No matches — show full list but pre-fill search with the domain
            presentSearchView(entries: allPasswordEntries, initialSearchText: searchDomain) { [weak self] entry in
                self?.completeRequest(with: entry)
            }
        }
    }

    private func findEntry(byRecordIdentifier recordIdentifier: String) -> KPEntry? {
        guard let targetUUID = UUID(uuidString: recordIdentifier) else { return nil }
        return parsedEntries.first { $0.id == targetUUID }
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
            presentSearchView(entries: matches) { [weak self] entry in
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

        presentSearchView(entries: expiredMatches) { [weak self] entry in
            self?.completePasskeyRequest(with: entry, requestParameters: requestParameters)
        }
    }

    private func presentSearchView(entries: [KPEntry], initialSearchText: String = "", onSelect: @escaping (KPEntry) -> Void) {
        presenter?.presentSearchView(
            entries: entries,
            initialSearchText: initialSearchText,
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
                    return .showError("The request is no longer available.")
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
                return .showWarningAndCancel("Database changed — open KeeForge to save")
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

        guard canUseBiometrics else {
            cancelRequest(code: .userInteractionRequired)
            return
        }

        let recordIdentifier = credentialRequest.credentialIdentity.recordIdentifier

        Task {
            do {
                let databaseReference = try currentDatabaseReference()

                let context = try await BiometricService.authenticate(reason: "AutoFill with KeeForge")
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
                       let entry = totpEntries.first(where: { $0.id.uuidString == recordIdentifier }) {
                        completeOTCRequest(with: entry)
                    } else {
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

    @available(iOS 18.0, macOS 15.0, *)
    private func completeOTCRequestFromPending() {
        hasPendingOTCRequest = false

        guard let recordIdentifier = targetRecordIdentifier else {
            cancelRequest(code: .failed)
            return
        }

        let totpEntries = parsedEntries.filter(\.hasTOTP)
        if let entry = totpEntries.first(where: { $0.id.uuidString == recordIdentifier }) {
            if entry.isExpired() {
                presentSearchView(entries: [entry]) { [weak self] selectedEntry in
                    self?.completeOTCRequest(with: selectedEntry)
                }
            } else {
                completeOTCRequest(with: entry)
            }
        } else {
            cancelRequest(code: .credentialIdentityNotFound)
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
        cleanup()
        let credential = ASPasswordCredential(user: user, password: decryptedPassword)
        presenter?.completeRequest(withSelectedCredential: credential)
    }

    // MARK: - Complete passkey request

    private func completePasskeyRequest(_ request: ASPasskeyCredentialRequest) throws {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
              let entry = passkeyEntry(for: identity) else {
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }

        try completePasskeyRequest(
            with: entry,
            relyingPartyID: identity.relyingPartyIdentifier,
            clientDataHash: request.clientDataHash
        )
    }

    private func completeInteractivePasskeyRequest(_ request: ASPasskeyCredentialRequest) {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
              let entry = passkeyEntry(for: identity, includeExpired: true) else {
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
              let userHandleData = passkey.userHandleData
        else {
            cancelRequest(code: .failed)
            return
        }

        let privateKey = try PasskeyCrypto.privateKey(fromPEM: passkey.privateKeyPEM)

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
                self?.cancelRequest(code: .userCanceled)
            }
        )
    }
}
