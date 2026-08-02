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

    /// Uses Apple's service-identifier order: the first identifier is the most
    /// specific one, so a match there wins over broader identifiers.
    static func orderedStrictMatchedEntries(
        from entries: [KPEntry],
        for identifiers: [ASCredentialServiceIdentifier]
    ) -> [KPEntry] {
        let candidates = entries
            .filter { !$0.isExpired() }
            .map { (entry: $0, hosts: ([$0.url] + $0.additionalURLs).compactMap(hostFromURLString)) }

        for identifier in identifiers {
            guard let term = searchTerm(for: identifier).map(normalizeHost) else { continue }

            let exactMatches = candidates.filter { $0.hosts.contains(term) }
            let exactMatchIDs = Set(exactMatches.map(\.entry.id))
            let childMatches = candidates.filter { candidate in
                guard !exactMatchIDs.contains(candidate.entry.id) else { return false }
                return candidate.hosts.contains { $0 != term && $0.hasSuffix(".\(term)") }
            }

            let matches = (exactMatches + childMatches).map(\.entry)
            if !matches.isEmpty { return matches }
        }
        return []
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
            let storedHosts = ([entry.url] + entry.additionalURLs).compactMap(hostFromURLString)
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
            let allURLs = [entry.url] + entry.additionalURLs

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
                return !strict && entry.title.lowercased().contains(term)
            }
        }
    }

    static func searchTerm(for identifier: ASCredentialServiceIdentifier) -> String? {
        if identifier.type == .domain {
            return normalizeHost(identifier.identifier)
        }

        return hostFromURLString(identifier.identifier) ?? identifier.identifier
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
