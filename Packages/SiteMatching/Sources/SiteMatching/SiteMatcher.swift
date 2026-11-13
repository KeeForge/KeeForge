import Foundation

/// A stored credential as matching sees it: an identifier and its URL fields.
public struct SiteCandidate: Hashable, Sendable {
    public let id: UUID
    /// Every URL field, in order. Fields holding a raw App ID are ignored.
    public let urls: [String]

    public init(id: UUID, urls: [String]) {
        self.id = id
        self.urls = urls
    }
}

/// Decides which candidates a request matches. Results are candidate IDs.
public enum SiteMatcher {
    public struct InteractiveMatches: Equatable, Sendable {
        /// Candidates storing the first requested web host itself.
        public let exact: [UUID]
        /// Only when `exact` is empty: strict matches for any requested host,
        /// then other subdomains of a requested registrable domain, nearest
        /// requested host first.
        public let possible: [UUID]
    }

    /// The sections a picker offers. Empty when the request names no website.
    public static func interactiveMatches(_ candidates: [SiteCandidate], for requests: [SiteRequest]) -> InteractiveMatches {
        guard let host = firstWebHost(for: requests) else {
            return InteractiveMatches(exact: [], possible: [])
        }
        let exact = candidates.filter { hosts(of: $0).contains(host) }
        guard exact.isEmpty else { return InteractiveMatches(exact: exact.map(\.id), possible: []) }

        var seenIDs = Set<UUID>()
        let possible = (strictCandidates(candidates, for: requests) + possibleCandidates(candidates, for: requests))
            .filter { seenIDs.insert($0.id).inserted }
        return InteractiveMatches(exact: [], possible: prioritizing(possible, for: requests).map(\.id))
    }

    /// Matches safe to fill without the user choosing: a stored host equals a
    /// requested host or is a dotted subdomain of it on the same registrable
    /// domain (`login.paypal.com` matches `paypal.com`; `mybank.com` does not
    /// match `bank.com`, and nothing but itself matches `co.uk` or an IP).
    public static func strictMatches(_ candidates: [SiteCandidate], for requests: [SiteRequest]) -> [UUID] {
        strictCandidates(candidates, for: requests).map(\.id)
    }

    /// The first request that names a web host.
    public static func firstWebHost(for requests: [SiteRequest]) -> SiteHost? {
        requests.lazy.compactMap(\.host).first
    }

    /// `TEAMID.bundle.id` with no scheme or path, as saves from app requests
    /// once stored in a URL field. Requiring the uppercase ten-character Team
    /// ID keeps ordinary lowercase hosts out.
    public static func isStoredAppIdentifier(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: /[A-Z0-9]{10}(\.[A-Za-z0-9-]+)+/) != nil
    }

    // MARK: - Tiers

    static func strictCandidates(_ candidates: [SiteCandidate], for requests: [SiteRequest]) -> [SiteCandidate] {
        let requested = requestHosts(requests)
        return candidates.filter { candidate in
            hosts(of: candidate).contains { stored in
                requested.contains { stored == $0 || stored.isSubdomain(of: $0) }
            }
        }
    }

    /// Stored hosts on a requested registrable domain. Never filled without
    /// the user choosing.
    static func possibleCandidates(_ candidates: [SiteCandidate], for requests: [SiteRequest]) -> [SiteCandidate] {
        let requestedDomains = Set(requestHosts(requests).compactMap(\.registrableDomain))
        guard !requestedDomains.isEmpty else { return [] }

        return candidates.filter { candidate in
            hosts(of: candidate).contains { $0.registrableDomain.map(requestedDomains.contains) ?? false }
        }
    }

    /// Stable sort: a stored host equal to a requested host first, then a
    /// subdomain of it, in request order.
    static func prioritizing(_ candidates: [SiteCandidate], for requests: [SiteRequest]) -> [SiteCandidate] {
        let requested = requestHosts(requests)
        func priority(_ candidate: SiteCandidate) -> Int {
            let stored = hosts(of: candidate)
            for (index, host) in requested.enumerated() {
                if stored.contains(host) { return index * 2 }
                if stored.contains(where: { $0.isSubdomain(of: host) }) { return index * 2 + 1 }
            }
            return Int.max
        }
        return candidates.enumerated().sorted {
            let left = priority($0.element), right = priority($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    // MARK: - Hosts

    static func hosts(of candidate: SiteCandidate) -> [SiteHost] {
        candidate.urls.filter { !isStoredAppIdentifier($0) }.compactMap { SiteHost($0) }
    }

    static func requestHosts(_ requests: [SiteRequest]) -> [SiteHost] {
        requests.compactMap(\.host)
    }
}
