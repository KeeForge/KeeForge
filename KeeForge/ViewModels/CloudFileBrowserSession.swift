import AuthenticationServices
import Foundation

enum CloudFileBrowserAuthenticationResult {
    case authenticated(CloudAccount)
    case cancelled
    case failed(Error)
}

@MainActor
@Observable
final class CloudFileBrowserSession {
    let providerID: String
    private let providerResolver: (String) -> CloudProvider?

    var accounts: [CloudAccount] = []
    var selectedAccountID: String?
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

    /// True when this provider is connected through an in-app server/username/
    /// password form (WebDAV) rather than a hosted OAuth flow.
    var usesManualConnectionForm: Bool {
        CloudProviderKind(rawValue: providerID)?.usesManualConnectionForm ?? false
    }

    func refreshAccounts() {
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
        guard let provider else {
            return .failed(CloudProviderError.invalidConfiguration)
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let account = try await provider.authenticate(from: presentationAnchor())
            refreshAccounts()
            selectedAccountID = account.id
            return .authenticated(account)
        } catch let cloudError as CloudProviderError where cloudError == .authenticationCancelled {
            refreshAccounts()
            return .cancelled
        } catch {
            refreshAccounts()
            return .failed(error)
        }
    }

    /// Adopts an account produced by the manual WebDAV connect form. Mirrors the
    /// state mutations of a successful `authenticate()`: refresh the account list
    /// and select the newly connected account.
    func adoptManualAccount(_ account: CloudAccount) {
        refreshAccounts()
        selectedAccountID = account.id
    }

    func cancelPendingAuthentication() {
        provider?.cancelPendingAuthentication()
    }
}
