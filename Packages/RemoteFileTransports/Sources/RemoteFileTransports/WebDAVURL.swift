import Foundation

/// Errors surfaced while normalizing a user-provided WebDAV base URL.
public enum WebDAVURLError: Error, Equatable, Sendable {
    case empty
    case malformed
    case insecureScheme
    case missingHost
}

public enum WebDAVURL {
    /// Normalizes a user-entered base URL for a WebDAV collection.
    ///
    /// Rules (v1): require `https` unless the caller explicitly opts into
    /// unencrypted HTTP, lowercase scheme + host, drop the scheme's default
    /// port, and guarantee exactly one trailing slash. The path is otherwise
    /// untouched (case and percent-encoding preserved) so server-relative
    /// `fileId`s round-trip predictably.
    public static func normalizedBaseURL(
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

    /// Human-readable label for the connected account: `user@host/path`.
    public static func displayName(normalizedBaseURL: URL, username: String) -> String {
        let host = normalizedBaseURL.host ?? ""
        var path = normalizedBaseURL.path
        if path == "/" {
            path = ""
        }
        return "\(username)@\(host)\(path)"
    }
}
