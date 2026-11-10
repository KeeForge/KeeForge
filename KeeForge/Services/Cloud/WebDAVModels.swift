import CryptoKit
import Foundation
import RemoteFileTransports

/// Raw form input captured from the WebDAV connect UI before it is normalized
/// into a persisted `WebDAVCredential`. Kept intentionally lightweight and
/// value-typed so it can cross actor boundaries freely.
struct WebDAVConnectionConfiguration: Hashable, Sendable {
    var serverURL: String
    var username: String
    var password: String
    var allowsUnencryptedHTTP: Bool

    init(
        serverURL: String,
        username: String,
        password: String,
        allowsUnencryptedHTTP: Bool = false
    ) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.allowsUnencryptedHTTP = allowsUnencryptedHTTP
    }
}

/// Persisted credential payload stored as JSON in `CloudTokenStore` under the
/// `webdav` provider namespace. The `serverURL` is always the normalized base
/// URL (http or https, lowercased scheme+host, exactly one trailing slash).
///
/// Additional optional fields (e.g. an untrusted-certificate flag) can be added
/// later without a migration because JSON decoding tolerates missing keys.
struct WebDAVCredential: Codable, Hashable, Sendable {
    let serverURL: String
    let username: String
    let password: String

    init(serverURL: String, username: String, password: String) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }
}

extension WebDAVCredential {
    /// The username and password the client sends.
    var basic: WebDAVClient.Credential {
        WebDAVClient.Credential(username: username, password: password)
    }
}

extension WebDAVURL {
    /// Stable, secret-free account identifier derived from the normalized base
    /// URL and username: `"webdav-" + SHA256hex(base + "\n" + username).prefix(32)`.
    static func accountId(normalizedBaseURL: URL, username: String) -> String {
        let material = normalizedBaseURL.absoluteString + "\n" + username
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "webdav-" + hex.prefix(32)
    }
}

/// The in-app connection seam used by the WebDAV connect flow (Slice 2 UI).
/// Kept separate from `CloudProvider` so the hosted-OAuth `authenticate(from:)`
/// contract stays untouched; the manual form calls `connect(_:)` instead.
protocol WebDAVConnecting: Sendable {
    func connect(_ configuration: WebDAVConnectionConfiguration) async throws -> CloudAccount
}
