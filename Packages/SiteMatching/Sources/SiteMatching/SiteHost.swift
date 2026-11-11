import Foundation
import PublicSuffixList

/// A website host in the form sites are compared in: lowercased, without
/// trailing dots, and without a leading `www.` label when what remains still
/// has a registrable domain (`www.example.co.uk` is `example.co.uk`, but on
/// `www.co.uk` the `www` is the registrable label and stays).
public struct SiteHost: Hashable, Sendable, CustomStringConvertible {
    public let name: String

    /// The host of a URL, or of a bare host with an optional port and path.
    /// Nil when nothing parses to a non-empty host. Any scheme is accepted.
    public init?(_ urlOrHost: String) {
        guard let name = Self.parse(urlOrHost), !name.isEmpty else { return nil }
        self.name = name
    }

    /// The host of an `http` or `https` URL, or of a bare host, when it is
    /// publishable. Other schemes carry no web host and are dropped rather
    /// than coerced into one: an `otpauth://totp/…` authority is not a domain.
    public init?(publishableWebURL value: String) {
        guard let url = Self.url(value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host
        else { return nil }

        let name = Self.normalize(host)
        guard Self.registrableDomain(of: name) != nil else { return nil }
        self.name = name
    }

    public var description: String { name }

    /// Whether the host may stand for a site outside the vault: it has a
    /// registrable domain, so it is not an IP address, `localhost`, a single
    /// label, or a bare public suffix.
    public var isPublishable: Bool {
        registrableDomain != nil
    }

    /// Whether `other` is under this host's registrable domain or, when this
    /// host has none, is this host.
    public func sharesRegistrableDomain(with other: SiteHost) -> Bool {
        guard let registrableDomain else { return other == self }
        return other.registrableDomain == registrableDomain
    }

    /// The form two passkey relying-party identifiers are compared in: the
    /// host rule of `SiteHost`, or for input that parses to no host, the
    /// input normalized as given.
    public static func relyingPartyKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return parse(trimmed) ?? normalize(trimmed)
    }

    // MARK: - Internal rules

    /// The registrable domain (eTLD+1), or nil for IP addresses, single
    /// labels, and bare public suffixes.
    var registrableDomain: String? {
        Self.registrableDomain(of: name)
    }

    /// Whether this host is a dotted subdomain of `parent` on the same
    /// registrable domain. A parent without one has no subdomains, so neither
    /// `co.uk` nor an IP address stands for the hosts beneath it.
    func isSubdomain(of parent: SiteHost) -> Bool {
        guard let domain = parent.registrableDomain else { return false }
        return name.hasSuffix(".\(parent.name)") && registrableDomain == domain
    }

    /// URL-or-host parsing. Unlike `init?(_:)` it can return an empty host
    /// (`https://.`).
    static func parse(_ value: String) -> String? {
        url(value)?.host.map(normalize)
    }

    /// The URL a stored value names. A value with no host is retried as
    /// `https://<value>`: `example.com:8080` parses with `example.com` as its
    /// scheme and no host at all.
    static func url(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host != nil { return url }
        return URL(string: "https://\(trimmed)").flatMap { $0.host == nil ? nil : $0 }
    }

    /// Applied exactly once to every host, stored or requested.
    static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        if result.hasPrefix("www."), registrableDomain(of: String(result.dropFirst(4))) != nil {
            result.removeFirst(4)
        }
        return result
    }

    /// The registrable domain (eTLD+1) of a normalized host, or nil for IP
    /// addresses, single labels, and bare public suffixes.
    static func registrableDomain(of host: String) -> String? {
        guard !isIPAddress(host), host.split(separator: ".").count >= 2 else { return nil }
        return PublicSuffixList.effectiveTLDPlusOne(host)
    }

    /// IPv6 (Foundation drops the brackets) or a host whose last label is a
    /// number, which the WHATWG URL Standard parses as IPv4 or rejects: its
    /// "ends in a number" check, so `foo.1.2.3.4` and `foo.0x4` count too.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        guard let last = host.split(separator: ".").last else { return false }
        if last.allSatisfy(\.isASCIIDigit) { return true }
        guard last.hasPrefix("0x") else { return false }
        return last.dropFirst(2).allSatisfy(\.isASCIIHexDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIIHexDigit: Bool { isASCII && isHexDigit }
}
