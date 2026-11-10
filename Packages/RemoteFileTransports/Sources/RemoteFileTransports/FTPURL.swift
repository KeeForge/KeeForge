import Foundation

public enum FTPURLError: Error, Equatable, Sendable {
    case empty
    case malformed
    case unsupportedScheme
    case unencryptedNotAllowed
    case missingHost
}

/// Where an account's files live: the control-connection endpoint plus the
/// base folder, relative to the directory the FTP login starts in.
public struct FTPServerLocation: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    /// Decoded folder path with no leading or trailing slash; empty means the
    /// login directory. RFC 1738 spells an absolute path as `%2F`, which
    /// decodes to a leading slash that is kept.
    public let basePath: String
}

public enum FTPURL {
    public static let defaultPort: UInt16 = 21

    /// Normalizes a user-entered FTP address. A bare `host/path` gets the
    /// `ftp://` scheme; any other scheme is rejected because this client only
    /// speaks plain FTP, which must be explicitly allowed. Scheme and host are
    /// lowercased, the default port is dropped, and the path keeps exactly
    /// one trailing slash.
    public static func normalizedBaseURL(
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

    public static func location(fromNormalizedBaseURL url: URL) -> FTPServerLocation? {
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

    /// Human-readable label for the connected account: `user@host[:port]/path`.
    public static func displayName(normalizedBaseURL: URL, username: String) -> String {
        let host = normalizedBaseURL.host ?? ""
        let port = normalizedBaseURL.port.map { ":\($0)" } ?? ""
        var path = normalizedBaseURL.path
        if path == "/" {
            path = ""
        }
        return "\(username)@\(host)\(port)\(path)"
    }
}
