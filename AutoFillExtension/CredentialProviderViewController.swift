import AuthenticationServices
import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var serviceIdentifiers: [ASCredentialServiceIdentifier] = []
    private var parsedEntries: [KPEntry] = []
    private var sessionKey: SymmetricKey?
    private var isUnlockInProgress = false
    private var didAttemptAutoBiometricUnlock = false
    private var targetRecordIdentifier: String?
    private var pendingPasskeyRequest: ASPasskeyCredentialRequest?
    private var pendingPasskeyRequestParameters: ASPasskeyCredentialRequestParameters?
    private var hasPendingOTCRequest = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        self.serviceIdentifiers = serviceIdentifiers
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = true
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        serviceIdentifiers = [credentialIdentity.serviceIdentifier]
        targetRecordIdentifier = credentialIdentity.recordIdentifier
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        didAttemptAutoBiometricUnlock = false
        // Delay unlock to ensure the view is fully presented,
        // otherwise biometric auth fails with "not interactive".
        pendingUnlock = true
    }

    // MARK: - Passkey credential request (iOS 17+)

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
        guard SettingsService.passkeyEnabled else {
            cancelRequest(code: .failed)
            return
        }
        self.serviceIdentifiers = serviceIdentifiers
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = requestParameters
        didAttemptAutoBiometricUnlock = false
        pendingUnlock = true
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            guard SettingsService.passkeyEnabled else {
                cancelRequest(code: .failed)
                return
            }
            pendingPasskeyRequest = passkeyRequest
            pendingPasskeyRequestParameters = nil
            targetRecordIdentifier = passkeyRequest.credentialIdentity.recordIdentifier
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = true
        } else if let passwordIdentity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            prepareInterfaceToProvideCredential(for: passwordIdentity)
        } else if #available(iOS 18.0, *), credentialRequest is ASOneTimeCodeCredentialRequest {
            hasPendingOTCRequest = true
            targetRecordIdentifier = credentialRequest.credentialIdentity.recordIdentifier
            didAttemptAutoBiometricUnlock = false
            pendingUnlock = true
        } else {
            cancelRequest(code: .failed)
        }
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            guard SettingsService.passkeyEnabled else {
                extensionContext.cancelRequest(withError: ASExtensionError(.failed))
                return
            }
            providePasskeyWithoutUserInteraction(for: passkeyRequest)
        } else if let passwordIdentity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            provideCredentialWithoutUserInteraction(for: passwordIdentity)
        } else if #available(iOS 18.0, *), credentialRequest is ASOneTimeCodeCredentialRequest {
            provideOTCWithoutUserInteraction(for: credentialRequest)
        } else {
            extensionContext.cancelRequest(withError: ASExtensionError(.failed))
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if pendingUnlock {
            pendingUnlock = false
            presentUnlockPromptIfNeeded()
        }
    }

    private var pendingUnlock = false

    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        guard SettingsService.quickAutoFillEnabled else {
            extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            return
        }

        guard canUseBiometrics else {
            extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            return
        }

        let recordIdentifier = credentialIdentity.recordIdentifier

        Task {
            do {
                guard let databasePath = SharedVaultStore.loadDatabaseKeychainPath() else {
                    throw ASExtensionError(.failed)
                }

                let context = try await BiometricService.authenticate(reason: "AutoFill with KeeForge")
                let compositeKey = try KeychainService.retrieveCompositeKey(for: databasePath, context: context)
                try await loadEntries(password: nil, compositeKey: compositeKey)
                let passwordEntries = parsedEntries.filter(\.hasPassword)

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
                extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            }
        }
    }

    override func prepareInterfaceForExtensionConfiguration() {
        let error = ASExtensionError(.failed)
        extensionContext.cancelRequest(withError: error)
    }

    // MARK: - Passkey silent auth

    private func providePasskeyWithoutUserInteraction(for request: ASPasskeyCredentialRequest) {
        guard SettingsService.quickAutoFillEnabled else {
            extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            return
        }

        guard canUseBiometrics else {
            extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            return
        }

        Task {
            do {
                guard let databasePath = SharedVaultStore.loadDatabaseKeychainPath() else {
                    throw ASExtensionError(.failed)
                }

                let context = try await BiometricService.authenticate(reason: "Passkey sign-in with KeeForge")
                let compositeKey = try KeychainService.retrieveCompositeKey(for: databasePath, context: context)
                try await loadEntries(password: nil, compositeKey: compositeKey)

                try completePasskeyRequest(request)
            } catch {
                extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            }
        }
    }

    // MARK: - Unlock flow

    private func presentUnlockPromptIfNeeded() {
        guard presentedViewController == nil, !isUnlockInProgress else { return }

        if shouldAutoUnlockWithBiometrics {
            didAttemptAutoBiometricUnlock = true
            unlockWithBiometrics()
            return
        }

        let alert = UIAlertController(
            title: "Unlock KeeForge",
            message: "Enter your master password or use biometrics.",
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "Master Password"
            field.isSecureTextEntry = true
            field.textContentType = .password
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.cancelRequest(code: .userCanceled)
        })

        alert.addAction(UIAlertAction(title: "Unlock", style: .default) { [weak self, weak alert] _ in
            guard let self, let password = alert?.textFields?.first?.text, !password.isEmpty else {
                self?.presentUnlockPromptIfNeeded()
                return
            }
            self.unlockWithPassword(password)
        })

        if canUseBiometrics {
            alert.addAction(UIAlertAction(title: biometricActionTitle, style: .default) { [weak self] _ in
                self?.unlockWithBiometrics()
            })
        }

        present(alert, animated: true)
    }

    private var shouldAutoUnlockWithBiometrics: Bool {
        guard !didAttemptAutoBiometricUnlock else { return false }
        guard SettingsService.autoUnlockWithFaceID else { return false }
        return canUseBiometrics
    }

    private var canUseBiometrics: Bool {
        guard BiometricService.isAvailable else { return false }
        guard let databasePath = SharedVaultStore.loadDatabaseKeychainPath() else { return false }
        return KeychainService.hasStoredKey(for: databasePath)
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
                try await loadEntries(password: password, compositeKey: nil)
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
                guard let databasePath = SharedVaultStore.loadDatabaseKeychainPath() else {
                    throw NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue)
                }

                let context = try await BiometricService.authenticate(reason: "Unlock KeeForge for AutoFill")
                let compositeKey = try KeychainService.retrieveCompositeKey(for: databasePath, context: context)
                try await loadEntries(password: nil, compositeKey: compositeKey)
                afterUnlock()
            } catch {
                showErrorAndRetry(error)
            }
        }
    }

    private func afterUnlock() {
        if let request = pendingPasskeyRequest {
            pendingPasskeyRequest = nil
            do {
                try completePasskeyRequest(request)
            } catch {
                showErrorAndRetry(error)
            }
        } else if let requestParameters = pendingPasskeyRequestParameters {
            presentPasskeyMatchesOrFinish(using: requestParameters)
        } else if hasPendingOTCRequest {
            if #available(iOS 18.0, *) {
                completeOTCRequestFromPending()
            }
        } else {
            presentPasswordMatchesOrFinish()
        }
    }

    private func loadEntries(password: String?, compositeKey: Data?) async throws {
        let data = try loadDatabaseData()
        let key = SymmetricKey(size: .bits256)

        let root = try await Task.detached {
            if let password {
                return try KDBXParser.parse(data: data, password: password, sessionKey: key)
            }

            guard let compositeKey else {
                throw NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue)
            }

            return try KDBXParser.parse(data: data, compositeKey: compositeKey, sessionKey: key)
        }.value

        self.sessionKey = key

        let allEntries: [KPEntry]
        if let recycleBinID = root.recycleBinUUID {
            allEntries = root.allEntries(excludingGroupID: recycleBinID)
        } else {
            allEntries = root.allEntries
        }
        parsedEntries = allEntries.filter { $0.hasPassword || $0.hasPasskey || $0.hasTOTP }
    }

    private func loadDatabaseData() throws -> Data {
        if let cachedURL = SharedVaultStore.loadCachedDatabaseURL() {
            return try CoordinatedFileReader.readData(from: cachedURL)
        }

        guard let bookmarkedURL = SharedVaultStore.loadBookmarkedURL() else {
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

    private func presentPasswordMatchesOrFinish() {
        let passwordEntries = parsedEntries.filter(\.hasPassword)

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
            presentSearchView(entries: passwordEntries, initialSearchText: searchDomain) { [weak self] entry in
                self?.completeRequest(with: entry)
            }
        }
    }

    private func findEntry(byRecordIdentifier recordIdentifier: String) -> KPEntry? {
        guard let targetUUID = UUID(uuidString: recordIdentifier) else { return nil }
        return parsedEntries.first { $0.id == targetUUID }
    }

    private func passkeyEntry(for identity: ASPasskeyCredentialIdentity) -> KPEntry? {
        let normalizedRelyingParty = CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(identity.relyingPartyIdentifier)

        let matchesIdentity: (KPEntry) -> Bool = { entry in
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

    private func matchingPasskeyEntries(for requestParameters: ASPasskeyCredentialRequestParameters) -> [KPEntry] {
        let normalizedRelyingParty = CredentialIdentityStoreManager.normalizedRelyingPartyIdentifier(
            requestParameters.relyingPartyIdentifier
        )
        let allowedCredentialIDs = Set(requestParameters.allowedCredentials)

        return parsedEntries.filter { entry in
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
        guard !matches.isEmpty else {
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }

        if matches.count == 1, let entry = matches.first {
            completePasskeyRequest(with: entry, requestParameters: requestParameters)
            return
        }

        presentSearchView(entries: matches) { [weak self] entry in
            self?.completePasskeyRequest(with: entry, requestParameters: requestParameters)
        }
    }

    private func presentSearchView(entries: [KPEntry], initialSearchText: String = "", onSelect: @escaping (KPEntry) -> Void) {
        let searchView = AutoFillSearchView(
            entries: entries,
            initialSearchText: initialSearchText,
            onSelect: { [weak self] entry in
                self?.dismiss(animated: false) {
                    onSelect(entry)
                }
            },
            onCancel: { [weak self] in
                self?.dismiss(animated: false) {
                    self?.cancelRequest(code: .userCanceled)
                }
            }
        )
        let host = UIHostingController(rootView: searchView)
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    // MARK: - One-time code (TOTP) support

    private func provideOTCWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        guard SettingsService.quickAutoFillEnabled else {
            extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            return
        }

        guard canUseBiometrics else {
            extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            return
        }

        let recordIdentifier = credentialRequest.credentialIdentity.recordIdentifier

        Task {
            do {
                guard let databasePath = SharedVaultStore.loadDatabaseKeychainPath() else {
                    throw ASExtensionError(.failed)
                }

                let context = try await BiometricService.authenticate(reason: "AutoFill with KeeForge")
                let compositeKey = try KeychainService.retrieveCompositeKey(for: databasePath, context: context)
                try await loadEntries(password: nil, compositeKey: compositeKey)

                if #available(iOS 18.0, *) {
                    let totpEntries = parsedEntries.filter(\.hasTOTP)
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
                extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
            }
        }
    }

    @available(iOS 18.0, *)
    private func completeOTCRequestFromPending() {
        hasPendingOTCRequest = false

        guard let recordIdentifier = targetRecordIdentifier else {
            cancelRequest(code: .failed)
            return
        }

        let totpEntries = parsedEntries.filter(\.hasTOTP)
        if let entry = totpEntries.first(where: { $0.id.uuidString == recordIdentifier }) {
            completeOTCRequest(with: entry)
        } else {
            cancelRequest(code: .credentialIdentityNotFound)
        }
    }

    @available(iOS 18.0, *)
    private func completeOTCRequest(with entry: KPEntry) {
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

        let credential = ASOneTimeCodeCredential(code: code)
        cleanup()
        extensionContext.completeOneTimeCodeRequest(using: credential)
    }

    private func cleanup() {
        parsedEntries = []
        sessionKey = nil
        targetRecordIdentifier = nil
        pendingPasskeyRequest = nil
        pendingPasskeyRequestParameters = nil
        hasPendingOTCRequest = false
    }

    // MARK: - Complete password request

    private func completeRequest(with entry: KPEntry) {
        let user = entry.username.isEmpty ? entry.title : entry.username
        guard !user.isEmpty, let decryptionKey = sessionKey else {
            cancelRequest(code: .failed)
            return
        }

        let decryptedPassword = (try? entry.password.decrypt(using: decryptionKey)) ?? ""
        cleanup()
        let credential = ASPasswordCredential(user: user, password: decryptedPassword)
        extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
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

    private func completePasskeyRequest(with entry: KPEntry, relyingPartyID: String, clientDataHash: Data) throws {
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
        extensionContext.completeAssertionRequest(using: credential)
    }

    // MARK: - Error handling

    private func cancelRequest(code: ASExtensionError.Code) {
        cleanup()
        extensionContext.cancelRequest(withError: ASExtensionError(code))
    }

    private func showErrorAndRetry(_ error: Error) {
        let alert = UIAlertController(
            title: "Unlock Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.presentUnlockPromptIfNeeded()
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.cancelRequest(code: .userCanceled)
        })

        present(alert, animated: true)
    }

}
