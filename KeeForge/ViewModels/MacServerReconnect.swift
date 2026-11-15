#if os(macOS)
import Foundation
import Observation

/// The Connect to Server form Reconnect shows for one WebDAV or FTP reference.
enum MacServerCredentialForm {
    case webDAV(WebDAVConnectViewModel)
    case ftp(FTPConnectViewModel)
}

/// Reconnect for a WebDAV or FTP reference. Neither server has a hosted
/// sign-in, so `authenticate(from:)` cannot help: the user enters the password
/// again in the connect form, prefilled with the reference's server and
/// username, and `connect(_:)` replaces the stored credential of that same
/// account.
@MainActor
struct MacServerReconnect {
    let providerKind: CloudProviderKind
    let accountID: String
    private let provider: any CloudProvider

    init?(
        reference: DatabaseReference,
        provider resolve: (String) -> (any CloudProvider)? = CloudProviderRegistry.provider(for:)
    ) {
        guard let metadata = reference.cloudSyncMetadata,
              let kind = CloudProviderKind(rawValue: metadata.provider),
              let provider = resolve(metadata.provider),
              provider is any WebDAVConnecting || provider is any FTPConnecting else { return nil }
        providerKind = kind
        accountID = metadata.accountId
        self.provider = provider
    }

    /// A fresh form: server and username from the stored credential when there is one, never its password.
    func makeForm() -> MacServerCredentialForm? {
        let stored = CloudTokenStore.tokenData(provider: provider.id, accountId: accountID)
        if let connector = provider as? any WebDAVConnecting {
            let form = WebDAVConnectViewModel(connector: connector, expectedAccountID: accountID)
            if let stored, let credential = try? JSONDecoder().decode(WebDAVCredential.self, from: stored) {
                form.serverURL = credential.serverURL
                form.username = credential.username
                form.allowsUnencryptedHTTP = credential.serverURL.lowercased().hasPrefix("http://")
            }
            return .webDAV(form)
        }
        if let connector = provider as? any FTPConnecting {
            let form = FTPConnectViewModel(connector: connector, expectedAccountID: accountID)
            if let stored, let credential = try? JSONDecoder().decode(FTPCredential.self, from: stored) {
                form.serverURL = credential.serverURL
                form.username = credential.username
                form.allowsUnencryptedFTP = credential.serverURL.lowercased().hasPrefix("ftp://")
            }
            return .ftp(form)
        }
        return nil
    }

    /// Presents the form and returns once it connected; closing it throws `authenticationCancelled`.
    func run(present: @MainActor (MacServerCredentialForm) async -> Bool) async throws {
        guard let form = makeForm() else { throw CloudProviderError.invalidConfiguration }
        guard await present(form) else { throw CloudProviderError.authenticationCancelled }
    }
}

/// One database window's Reconnect sheet. The window's root view presents
/// `request`; the form's Connect or Cancel answers `present`.
@MainActor @Observable
final class MacServerCredentialPrompt {
    struct Request: Identifiable {
        let id = UUID()
        let form: MacServerCredentialForm
    }

    private(set) var request: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    func present(_ form: MacServerCredentialForm) async -> Bool {
        finish(connected: false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            request = Request(form: form)
        }
    }

    /// Also run on lock and close, so no credential form outlives the session it was for.
    func finish(connected: Bool) {
        switch request?.form {
        case .webDAV(let form): form.cancelPendingConnection()
        case .ftp(let form): form.cancelPendingConnection()
        case nil: break
        }
        request = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: connected)
    }
}
#endif
