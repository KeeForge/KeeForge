import CryptoKit
import Foundation

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

enum FTPURLError: Error, Equatable {
    case empty
    case malformed
    case unsupportedScheme
    case unencryptedNotAllowed
    case missingHost
}

/// Where an account's files live: the control-connection endpoint plus the
/// base folder, relative to the directory the FTP login starts in.
struct FTPServerLocation: Equatable, Sendable {
    let host: String
    let port: UInt16
    /// Decoded folder path with no leading or trailing slash; empty means the
    /// login directory. RFC 1738 spells an absolute path as `%2F`, which
    /// decodes to a leading slash that is kept.
    let basePath: String
}

enum FTPURL {
    static let defaultPort: UInt16 = 21

    /// Normalizes a user-entered FTP address. A bare `host/path` gets the
    /// `ftp://` scheme; any other scheme is rejected because this client only
    /// speaks plain FTP, which must be explicitly allowed. Scheme and host are
    /// lowercased, the default port is dropped, and the path keeps exactly
    /// one trailing slash.
    static func normalizedBaseURL(
        from raw: String,
        allowsUnencryptedFTP: Bool
    ) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FTPURLError.empty }

        let withScheme = trimmed.contains("://") ? trimmed : "ftp://" + trimmed
        guard var components = URLComponents(string: withScheme, encodingInvalidCharacters: true) else {
            throw FTPURLError.malformed
        }

        guard components.scheme?.lowercased() == "ftp" else {
            throw FTPURLError.unsupportedScheme
        }
        guard allowsUnencryptedFTP else {
            throw FTPURLError.unencryptedNotAllowed
        }
        components.scheme = "ftp"
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw FTPURLError.missingHost
        }
        components.host = host

        if components.port == Int(defaultPort) {
            components.port = nil
        }
        if let port = components.port, !(1...Int(UInt16.max)).contains(port) {
            throw FTPURLError.malformed
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path + "/"

        guard let url = components.url else { throw FTPURLError.malformed }
        return url
    }

    static func location(fromNormalizedBaseURL url: URL) -> FTPServerLocation? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = components.host, !host.isEmpty else {
            return nil
        }
        // URLComponents keeps an IPv6 literal's brackets; the endpoint wants the bare address.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let port = components.port.flatMap(UInt16.init(exactly:)) ?? defaultPort

        let decoded = components.percentEncodedPath.removingPercentEncoding ?? components.path
        var basePath = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        while basePath.count > 1, basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        return FTPServerLocation(host: host, port: port, basePath: basePath)
    }

    /// Stable, secret-free account identifier:
    /// `"ftp-" + SHA256hex(base + "\n" + username).prefix(32)`.
    static func accountId(normalizedBaseURL: URL, username: String) -> String {
        let material = normalizedBaseURL.absoluteString + "\n" + username
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ftp-" + hex.prefix(32)
    }

    /// Human-readable label for the connected account: `user@host[:port]/path`.
    static func displayName(normalizedBaseURL: URL, username: String) -> String {
        let host = normalizedBaseURL.host ?? ""
        let port = normalizedBaseURL.port.map { ":\($0)" } ?? ""
        var path = normalizedBaseURL.path
        if path == "/" {
            path = ""
        }
        return "\(username)@\(host)\(port)\(path)"
    }
}

/// The in-app connection seam used by the FTP connect form, kept separate from
/// `CloudProvider` like `WebDAVConnecting`.
protocol FTPConnecting: Sendable {
    func connect(_ configuration: FTPConnectionConfiguration) async throws -> CloudAccount
}
