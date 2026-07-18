import AuthenticationServices

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

    private static func matchedEntries(
        from entries: [KPEntry],
        for identifiers: [ASCredentialServiceIdentifier],
        strict: Bool
    ) -> [KPEntry] {
        guard !identifiers.isEmpty else { return [] }

        let searchTerms = Set(identifiers.compactMap(searchTerm(for:)).map { $0.lowercased() })

        return entries.filter { entry in
            guard !entry.isExpired() else { return false }
            let allURLs = [entry.url] + entry.additionalURLs

            return searchTerms.contains { term in
                for urlString in allURLs {
                    let host = hostFromURLString(urlString)?.lowercased()
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
            return identifier.identifier
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

        guard var result = host else { return nil }
        if result.lowercased().hasPrefix("www.") {
            result = String(result.dropFirst(4))
        }
        return result
    }
}
