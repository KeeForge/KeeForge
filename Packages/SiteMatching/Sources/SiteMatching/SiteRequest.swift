import Foundation

/// What a credential request names: a domain, a page URL, or an app.
public enum SiteRequest: Hashable, Sendable {
    case domain(String)
    case url(String)
    /// An App ID such as `TEAMID.com.example.app`. It is never read as a
    /// host: reverse-DNS App IDs end in real TLDs and would match the
    /// unrelated website `example.app`.
    case app(String)

    /// A website reduced to what may be saved with an entry.
    public struct Website: Hashable, Sendable {
        /// The host with its port, if any, e.g. `login.example.com:8443`.
        public let host: String
        /// Scheme, host, and port only.
        public let url: String
    }

    /// The text the request is matched on: the normalized host, or for a URL
    /// with no parsable host, the URL as given. Nil for an app.
    public var searchTerm: String? {
        switch self {
        case .app: nil
        case .domain(let value): SiteHost.normalize(value)
        case .url(let value): SiteHost.parse(value) ?? value
        }
    }

    /// The requested website reduced to scheme, host, and port. The page's
    /// path and query are the website's to choose, so they never reach an
    /// entry. The scheme is `http` only when the request says so.
    public var website: Website? {
        let value: String
        let isURL: Bool
        switch self {
        case .app: return nil
        case .domain(let domain): (value, isURL) = (domain, false)
        case .url(let url): (value, isURL) = (url, true)
        }

        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = isURL ? URLComponents(string: raw) : nil
        let components = parsed?.host?.isEmpty == false ? parsed : URLComponents(string: "https://\(raw)")
        guard var host = components?.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        var website = URLComponents()
        website.scheme = components?.scheme?.lowercased() == "http" ? "http" : "https"
        website.host = host
        website.port = components?.port
        guard let url = website.string else { return nil }
        let displayHost = components?.port.map { "\(host):\($0)" } ?? host
        return Website(host: displayHost, url: url)
    }
}
