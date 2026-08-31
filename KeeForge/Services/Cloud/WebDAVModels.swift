import CryptoKit
import Foundation

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

/// Errors surfaced while normalizing a user-provided WebDAV base URL.
enum WebDAVURLError: Error, Equatable {
    case empty
    case malformed
    case insecureScheme
    case missingHost
}

enum WebDAVURL {
    /// Normalizes a user-entered base URL for a WebDAV collection.
    ///
    /// Rules (v1): require `https` unless the caller explicitly opts into
    /// unencrypted HTTP, lowercase scheme + host, drop the scheme's default
    /// port, and guarantee exactly one trailing slash. The path is otherwise
    /// untouched (case and percent-encoding preserved) so server-relative
    /// `fileId`s round-trip predictably.
    static func normalizedBaseURL(
        from raw: String,
        allowsUnencryptedHTTP: Bool = false
    ) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebDAVURLError.empty }

        // `encodingInvalidCharacters: true` is available on both deployment floors and percent-encodes
        // spaces and non-ASCII characters instead of rejecting the string, so a
        // pasted address like a Nextcloud path with an umlaut normalizes cleanly
        // rather than failing as "malformed".
        guard var components = URLComponents(string: trimmed, encodingInvalidCharacters: true) else {
            throw WebDAVURLError.malformed
        }

        guard let scheme = components.scheme?.lowercased() else {
            throw WebDAVURLError.malformed
        }
        guard scheme == "https" || (scheme == "http" && allowsUnencryptedHTTP) else {
            throw WebDAVURLError.insecureScheme
        }
        components.scheme = scheme

        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw WebDAVURLError.missingHost
        }
        components.host = host

        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }

        // Collapse the path to exactly one trailing slash. An empty path becomes
        // "/". Interior slashes and percent-encoding are preserved verbatim.
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path + "/"

        guard let url = components.url else { throw WebDAVURLError.malformed }
        return url
    }

    /// Stable, secret-free account identifier derived from the normalized base
    /// URL and username: `"webdav-" + SHA256hex(base + "\n" + username).prefix(32)`.
    static func accountId(normalizedBaseURL: URL, username: String) -> String {
        let material = normalizedBaseURL.absoluteString + "\n" + username
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "webdav-" + hex.prefix(32)
    }

    /// Human-readable label for the connected account: `user@host/path`.
    static func displayName(normalizedBaseURL: URL, username: String) -> String {
        let host = normalizedBaseURL.host ?? ""
        var path = normalizedBaseURL.path
        if path == "/" {
            path = ""
        }
        return "\(username)@\(host)\(path)"
    }
}

/// The in-app connection seam used by the WebDAV connect flow (Slice 2 UI).
/// Kept separate from `CloudProvider` so the hosted-OAuth `authenticate(from:)`
/// contract stays untouched; the manual form calls `connect(_:)` instead.
protocol WebDAVConnecting: Sendable {
    func connect(_ configuration: WebDAVConnectionConfiguration) async throws -> CloudAccount
}
