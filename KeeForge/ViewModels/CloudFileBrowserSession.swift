import AuthenticationServices
import Foundation

enum CloudFileBrowserAuthenticationResult {
    case authenticated(CloudAccount)
    case cancelled
    case failed(Error)
}

enum CloudFileBrowserSelectionResult {
    case selected([CloudDatabaseSelection])
    case cancelled
    case failed(Error)
}

@MainActor
@Observable
final class CloudFileBrowserSession {
    let providerID: String
    private let providerResolver: (String) -> CloudProvider?

    var accounts: [CloudAccount] = []
    var selectedAccountID: String? {
        didSet {
            if selectedAccountID != oldValue { invalidateOperation() }
        }
    }
    private(set) var selectedFiles: [CloudDatabaseSelection] = []
    private var operationID: UUID?
    private var operationProvider: (any CloudProvider)?
    private var selectionProvider: (any CloudProvider)?
    private var isActive = true
    private(set) var isAuthenticating = false

    init(
        providerID: String,
        providerResolver: @escaping (String) -> CloudProvider? = CloudProviderRegistry.provider(for:)
    ) {
        self.providerID = providerID
        self.providerResolver = providerResolver
    }

    var provider: CloudProvider? {
        providerResolver(providerID)
    }

    var selectedAccount: CloudAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    func selectionAccount(matching accountID: String) -> CloudAccount? {
        guard isActive, selectedAccountID == accountID,
              provider?.isAuthenticated(accountId: accountID) == true,
              CloudAccountStore.isConnected(provider: providerID, accountId: accountID) else { return nil }
        return selectedAccount
    }

    /// True when this provider is connected through an in-app server/username/
    /// password form (WebDAV, FTP) rather than a hosted OAuth flow.
    var usesManualConnectionForm: Bool {
        CloudProviderKind(rawValue: providerID)?.usesManualConnectionForm ?? false
    }

    var usesNativeFileSelection: Bool { provider is any CloudFileSelecting }

    func refreshAccounts() {
        guard isActive else { return }
        accounts = CloudAccountStore.accounts(for: providerID)
        if selectedAccountID == nil {
            selectedAccountID = accounts.first?.id
        } else if accounts.contains(where: { $0.id == selectedAccountID }) == false {
            selectedAccountID = accounts.first?.id
        }
    }

    func authenticate(
        presentationAnchor: @escaping @MainActor () -> ASPresentationAnchor
    ) async -> CloudFileBrowserAuthenticationResult {
        guard isActive, let provider else {
            return .failed(CloudProviderError.invalidConfiguration)
        }

        let id = beginOperation(provider: provider)
        defer { finishOperation(id) }

        do {
            let account = try await provider.authenticate(from: presentationAnchor())
            guard accepts(id), self.provider === provider, !Task.isCancelled else { return .cancelled }
            guard account.provider == providerID, provider.isAuthenticated(accountId: account.id),
                  CloudAccountStore.isConnected(provider: providerID, accountId: account.id) else { return .failed(CloudProviderError.permissionDenied) }
            finishOperation(id)
            refreshAccounts()
            selectedAccountID = account.id
            return .authenticated(account)
        } catch let cloudError as CloudProviderError where cloudError == .authenticationCancelled {
            guard accepts(id) else { return .cancelled }
            refreshAccounts()
            return .cancelled
        } catch {
            guard accepts(id), !Task.isCancelled, !(error is CancellationError) else { return .cancelled }
            refreshAccounts()
            return .failed(error)
        }
    }

    func selectFiles(
        expectedAccountID: String?,
        presentationAnchor: @escaping @MainActor () -> ASPresentationAnchor
    ) async -> CloudFileBrowserSelectionResult {
        guard isActive, let selector = provider as? any CloudFileSelecting else {
            return .failed(CloudProviderError.invalidConfiguration)
        }
        let owner = selectedAccountID
        let id = beginOperation(provider: selector)
        defer { finishOperation(id) }
        do {
            let selections = try await selector.selectFiles(from: presentationAnchor(), expectedAccountID: expectedAccountID)
            guard accepts(id), self.provider === selector, selectedAccountID == owner, !Task.isCancelled else { return .cancelled }
            guard let account = selections.first?.account else { return .cancelled }
            guard selector.isAuthenticated(accountId: account.id), account.provider == providerID,
                  expectedAccountID == nil || account.id == expectedAccountID,
                  selections.allSatisfy({ $0.provider == providerID && $0.account == account && !$0.file.isFolder }),
                  Set(selections.map(\.file.id)).count == selections.count else {
                return .failed(CloudProviderError.permissionDenied)
            }
            finishOperation(id)
            refreshAccounts()
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index] = account
            } else {
                accounts.append(account)
            }
            selectedAccountID = account.id
            selectedFiles = selections
            selectionProvider = selector
            return .selected(selections)
        } catch {
            guard accepts(id), !Task.isCancelled, !(error is CancellationError) else { return .cancelled }
            if (error as? CloudProviderError) == .authenticationCancelled { return .cancelled }
            return .failed(error)
        }
    }

    func consumeSelection(_ file: CloudFile, accountID: String) -> CloudDatabaseSelection? {
        guard let account = selectionAccount(matching: accountID) else { return nil }
        let selection = CloudDatabaseSelection(provider: providerID, account: account, file: file)
        guard !usesNativeFileSelection || (provider === selectionProvider && selectedFiles.contains(selection)) else { return nil }
        disappear()
        return selection
    }

    func disappear() {
        isActive = false
        cancelPendingAuthentication()
    }

    private func beginOperation(provider: any CloudProvider) -> UUID {
        invalidateOperation()
        let id = UUID()
        operationID = id
        operationProvider = provider
        isAuthenticating = true
        return id
    }

    private func accepts(_ id: UUID) -> Bool { isActive && operationID == id }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operationProvider = nil
        isAuthenticating = false
    }

    private func invalidateOperation() {
        if operationID != nil { operationProvider?.cancelPendingAuthentication() }
        operationID = nil
        operationProvider = nil
        selectionProvider = nil
        selectedFiles = []
        isAuthenticating = false
    }

    /// Adopts an account produced by a manual connect form. Mirrors the
    /// state mutations of a successful `authenticate()`: refresh the account list
    /// and select the newly connected account.
    func adoptManualAccount(_ account: CloudAccount) {
        guard isActive, account.provider == providerID,
              provider?.isAuthenticated(accountId: account.id) == true,
              CloudAccountStore.isConnected(provider: providerID, accountId: account.id) else { return }
        refreshAccounts()
        selectedAccountID = account.id
    }

    func cancelPendingAuthentication() {
        invalidateOperation()
    }
}
