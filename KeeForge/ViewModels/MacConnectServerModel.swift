#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class MacConnectServerModel {
    static let serverTypes: [CloudProviderKind] = [.webDAV, .ftp]
    var serverType: CloudProviderKind
    let webDAV: WebDAVConnectViewModel
    let ftp: FTPConnectViewModel
    private var ended = false

    init(serverType: CloudProviderKind = .webDAV,
         webDAV: WebDAVConnectViewModel = WebDAVConnectViewModel(connector: WebDAVCloudProvider.shared),
         ftp: FTPConnectViewModel = FTPConnectViewModel(connector: FTPCloudProvider.shared),
         prefill: Bool = true) {
        self.serverType = Self.serverTypes.contains(serverType) ? serverType : .webDAV
        self.webDAV = webDAV
        self.ftp = ftp
        if prefill { prefillAccounts() }
    }

    convenience init(form: MacServerCredentialForm) {
        switch form {
        case .webDAV(let form): self.init(webDAV: form, prefill: false)
        case .ftp(let form): self.init(serverType: .ftp, ftp: form, prefill: false)
        }
    }

    var isConnecting: Bool { webDAV.isConnecting || ftp.isConnecting }
    var showsFTPWarnings: Bool { ftp.allowsUnencryptedFTP }
    var errorMessage: String? { serverType == .webDAV ? webDAV.errorMessage : ftp.errorMessage }

    func connect() async -> CloudAccount? {
        guard !ended, !isConnecting else { return nil }
        let account = serverType == .webDAV ? await webDAV.connect() : await ftp.connect()
        guard !ended, !Task.isCancelled else { clearSecrets(); return nil }
        if let account {
            SharedVaultStore.cloudAccountDefaults.set(account.id, forKey: Self.recentAccountKey(account.provider))
        }
        return account
    }

    func clearSecrets() {
        ended = true
        webDAV.cancelPendingConnection()
        ftp.cancelPendingConnection()
    }

    private static func recentAccountKey(_ provider: String) -> String { "KeeForge.macRecentServer." + provider }

    private func recentAccount(_ kind: CloudProviderKind) -> CloudAccount? {
        let accounts = CloudAccountStore.accounts.filter { $0.provider == kind.rawValue }
        let recent = SharedVaultStore.cloudAccountDefaults.string(forKey: Self.recentAccountKey(kind.rawValue))
        return accounts.first { $0.id == recent } ?? accounts.last
    }

    private func prefillAccounts() {
        if let account = recentAccount(.webDAV),
           let data = CloudTokenStore.tokenData(provider: account.provider, accountId: account.id),
           let credential = try? JSONDecoder().decode(WebDAVCredential.self, from: data) {
            webDAV.serverURL = credential.serverURL
            webDAV.username = credential.username
            webDAV.allowsUnencryptedHTTP = credential.serverURL.lowercased().hasPrefix("http://")
        }
        if let account = recentAccount(.ftp),
           let data = CloudTokenStore.tokenData(provider: account.provider, accountId: account.id),
           let credential = try? JSONDecoder().decode(FTPCredential.self, from: data) {
            ftp.serverURL = credential.serverURL
            ftp.username = credential.username
            ftp.allowsUnencryptedFTP = credential.serverURL.lowercased().hasPrefix("ftp://")
        }
    }
}
#endif
