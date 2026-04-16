import AuthenticationServices

enum CredentialMatcher {
    static func matchedEntries(from entries: [KPEntry], for identifiers: [ASCredentialServiceIdentifier]) -> [KPEntry] {
        guard !identifiers.isEmpty else { return [] }

        let searchTerms = Set(identifiers.compactMap(searchTerm(for:)).map { $0.lowercased() })

        return entries.filter { entry in
            let allURLs = [entry.url] + entry.additionalURLs

            return searchTerms.contains { term in
                for urlString in allURLs {
                    let host = hostFromURLString(urlString)?.lowercased()
                    if let host, host == term || host.hasSuffix(".\(term)") {
                        return true
                    }
                    if urlString.lowercased().contains(term) {
                        return true
                    }
                }
                return entry.title.lowercased().contains(term)
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
