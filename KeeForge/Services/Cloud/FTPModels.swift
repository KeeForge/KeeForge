import CryptoKit
import Foundation
import RemoteFileTransports

/// Raw form input captured from the FTP connect UI before it is normalized
/// into a persisted `FTPCredential`.
struct FTPConnectionConfiguration: Hashable, Sendable {
    var serverURL: String
    var username: String
    var password: String
    var allowsUnencryptedFTP: Bool

    init(
        serverURL: String,
        username: String,
        password: String,
        allowsUnencryptedFTP: Bool = false
    ) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.allowsUnencryptedFTP = allowsUnencryptedFTP
    }
}

/// Persisted credential payload stored as JSON in `CloudTokenStore` under the
/// `ftp` provider namespace. `serverURL` is always the normalized base URL.
struct FTPCredential: Codable, Hashable, Sendable {
    let serverURL: String
    let username: String
    let password: String
}

extension FTPURL {
    /// Stable, secret-free account identifier:
    /// `"ftp-" + SHA256hex(base + "\n" + username).prefix(32)`.
    static func accountId(normalizedBaseURL: URL, username: String) -> String {
        let material = normalizedBaseURL.absoluteString + "\n" + username
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ftp-" + hex.prefix(32)
    }
}

/// The in-app connection seam used by the FTP connect form, kept separate from
/// `CloudProvider` like `WebDAVConnecting`.
protocol FTPConnecting: Sendable {
    func connect(_ configuration: FTPConnectionConfiguration) async throws -> CloudAccount
}
