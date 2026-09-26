import AuthenticationServices
import PublicSuffixList

enum CredentialMatcher {
    /// Host-based matches only: a stored URL's host equals the requested
    /// domain or is a dotted subdomain of it (`login.paypal.com` matches
    /// `paypal.com`, but `mybank.com` does NOT match `bank.com`). These are
    /// the only matches safe to fill without an explicit user selection.
    static func strictMatchedEntries(from entries: [KPEntry], for identifiers: [ASCredentialServiceIdentifier]) -> [KPEntry] {
        matchedEntries(from: entries, for: identifiers, strict: true)
    }

    /// Broad matches for interactive pickers: host matches plus URL and
    /// title substring matches. Substring matches can surface wrong-origin
    /// entries (`mybank.com` for a `bank.com` request), so results must
    /// never be filled without the user explicitly choosing from a list —
    /// use `strictMatchedEntries` to decide any auto-complete path.
    static func matchedEntries(from entries: [KPEntry], for identifiers: [ASCredentialServiceIdentifier]) -> [KPEntry] {
        matchedEntries(from: entries, for: identifiers, strict: false)
    }

    /// Interactive-only suggestions on a different subdomain of the same
    /// normalized registrable domain. The registrable-domain boundary comes
    /// from the embedded Mozilla Public Suffix List.
    static func possibleMatchedEntries(from entries: [KPEntry], for identifiers: [ASCredentialServiceIdentifier]) -> [KPEntry] {
        let requestedHosts = identifiers.compactMap(searchTerm(for:)).compactMap(hostFromURLString)
        let requestedDomains = Set(requestedHosts.compactMap(registrableDomain(for:)))
        guard !requestedDomains.isEmpty else { return [] }

        return entries.filter { entry in
            guard !entry.isExpired() else { return false }
            let storedHosts = webURLs(of: entry).compactMap(hostFromURLString)
            return storedHosts.contains { storedHost in
                guard let storedDomain = registrableDomain(for: storedHost),
                      requestedDomains.contains(storedDomain) else { return false }
                return requestedHosts.contains { requestedHost in
                    storedHost != requestedHost && storedHost.contains(".") && requestedHost.contains(".")
                }
            }
        }
    }

    private static func matchedEntries(
        from entries: [KPEntry],
        for identifiers: [ASCredentialServiceIdentifier],
        strict: Bool
    ) -> [KPEntry] {
        guard !identifiers.isEmpty else { return [] }

        let searchTerms = Set(identifiers.compactMap { searchTerm(for: $0) }.map(normalizeHost))

        return entries.filter { entry in
            guard !entry.isExpired() else { return false }
            let allURLs = webURLs(of: entry)
            let matchesTitle = !strict && !hasStoredAppIDTitle(entry)

            return searchTerms.contains { term in
                for urlString in allURLs {
                    let host = hostFromURLString(urlString)
                    if let host, host == term || host.hasSuffix(".\(term)") {
                        return true
                    }
                    if !strict, urlString.lowercased().contains(term) {
                        return true
                    }
                }
                return matchesTitle && entry.title.lowercased().contains(term)
            }
        }
    }

    static func searchTerm(for identifier: ASCredentialServiceIdentifier) -> String? {
        if isAppIdentifier(identifier) {
            return nil
        }
        if identifier.type == .domain {
            return normalizeHost(identifier.identifier)
        }

        return hostFromURLString(identifier.identifier) ?? identifier.identifier
    }

    /// An App ID (`TEAMID.com.example.app`) is reverse-DNS, so parsing it as
    /// a host would match the unrelated website `example.app`.
    static func isAppIdentifier(_ identifier: ASCredentialServiceIdentifier) -> Bool {
        if #available(iOS 26.2, macOS 26.2, *) {
            return identifier.type == .app
        }
        return false
    }

    /// The entry's URL fields minus any that hold a raw App ID, which saves
    /// from `.app` requests stored before #137.
    static func webURLs(of entry: KPEntry) -> [String] {
        ([entry.url] + entry.additionalURLs).filter { !isStoredAppIdentifier($0) }
    }

    /// Those saves also titled the entry with the App ID parsed as a host.
    private static func hasStoredAppIDTitle(_ entry: KPEntry) -> Bool {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ([entry.url] + entry.additionalURLs).contains { url in
            isStoredAppIdentifier(url) && url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
        }
    }

    /// `TEAMID.bundle.id` with no scheme or path. Matching on the uppercase
    /// ten-character Team ID keeps ordinary lowercase hosts out.
    static func isStoredAppIdentifier(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: /[A-Z0-9]{10}(\.[A-Za-z0-9-]+)+/) != nil
    }

    static func hostFromURLString(_ value: String) -> String? {
        let host: String?
        if let h = URL(string: value)?.host {
            host = h
        } else {
            host = URL(string: "https://\(value)")?.host
        }

        guard let host else { return nil }
        return normalizeHost(host)
    }

    private static func normalizeHost(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        if result.hasPrefix("www.") { result.removeFirst(4) }
        return result
    }

    private static func registrableDomain(for host: String) -> String? {
        PublicSuffixList.effectiveTLDPlusOne(normalizeHost(host))
    }
}
