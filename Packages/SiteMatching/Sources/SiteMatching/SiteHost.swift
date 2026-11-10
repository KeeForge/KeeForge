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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Retry on a missing host, not a missing scheme: `example.com:8080`
        // parses with `example.com` as its scheme and no host at all.
        let parsed = URL(string: trimmed)
        let url = parsed?.host == nil ? URL(string: "https://\(trimmed)") : parsed
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url.host
        else { return nil }

        while host.hasSuffix(".") { host.removeLast() }
        // Checked before the `www` rule, unlike `isPublishable`.
        guard Self.registrableDomain(of: host) != nil else { return nil }
        self.init(host)
    }

    public var description: String { name }

    /// Whether the host may stand for a site outside the vault: it has a
    /// registrable domain and is not an IP address, `localhost`, a single
    /// label, or a bare public suffix.
    public var isPublishable: Bool {
        Self.registrableDomain(of: name) != nil
    }

    /// Whether `other` is under this host's registrable domain or, when this
    /// host has none, is this host.
    ///
    /// The domain here is the Public Suffix List's alone, without the IP
    /// checks of `isPublishable`: two IPv4 addresses ending in the same two
    /// octets share one.
    public func sharesRegistrableDomain(with other: SiteHost) -> Bool {
        guard let domain = Self.suffixListDomain(of: name) else { return other == self }
        return Self.suffixListDomain(of: other.name) == domain
    }

    /// The form two passkey relying-party identifiers are compared in. Unlike
    /// `SiteHost`, it drops a leading `www.` unconditionally, so `www.co.uk`
    /// and `co.uk` compare equal.
    public static func relyingPartyKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = (parse(trimmed) ?? trimmed).lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    // MARK: - Internal rules

    /// URL-or-host parsing. Unlike `init?(_:)` it can return an empty host
    /// (`https://.`), which the matcher compares as is.
    static func parse(_ value: String) -> String? {
        guard let host = URL(string: value)?.host ?? URL(string: "https://\(value)")?.host else { return nil }
        return normalize(host)
    }

    static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        if result.hasPrefix("www."), PublicSuffixList.effectiveTLDPlusOne(String(result.dropFirst(4))) != nil {
            result.removeFirst(4)
        }
        return result
    }

    /// The registrable domain (eTLD+1), or nil for IP addresses, single
    /// labels, and bare public suffixes.
    static func registrableDomain(of host: String) -> String? {
        let lowered = host.lowercased()
        if lowered.contains(":") { return nil }

        let labels = lowered.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }

        return PublicSuffixList.effectiveTLDPlusOne(lowered)
    }

    /// The Public Suffix List's eTLD+1 with no IP checks. The list's default
    /// rule gives `192.168.1.1` the domain `1.1`.
    static func suffixListDomain(of host: String) -> String? {
        PublicSuffixList.effectiveTLDPlusOne(normalize(host))
    }
}
