import AuthenticationServices
import SiteMatching

extension SiteRequest {
    init(_ identifier: ASCredentialServiceIdentifier) {
        if #available(iOS 26.2, macOS 26.2, *), identifier.type == .app {
            self = .app(identifier.identifier)
        } else if identifier.type == .domain {
            self = .domain(identifier.identifier)
        } else {
            self = .url(identifier.identifier)
        }
    }
}

/// The app's bridge to `SiteMatching`: requests from sites or service identifiers,
/// candidates from entries. Expired entries never become candidates.
enum CredentialMatcher {
    static func interactiveMatches(from entries: [KPEntry], for identifiers: [ASCredentialServiceIdentifier]) -> (exact: [KPEntry], possible: [KPEntry]) {
        interactiveMatches(from: entries, for: identifiers.map(SiteRequest.init))
    }

    static func interactiveMatches(from entries: [KPEntry], for requests: [SiteRequest]) -> (exact: [KPEntry], possible: [KPEntry]) {
        let eligible = eligibleEntries(entries)
        let matches = SiteMatcher.interactiveMatches(eligible.map(candidate), for: requests)
        return (orderedEntries(withIDs: matches.exact, in: eligible), orderedEntries(withIDs: matches.possible, in: eligible))
    }

    /// The only matches safe to fill without the user choosing.
    static func strictMatchedEntries(from entries: [KPEntry], for identifiers: [ASCredentialServiceIdentifier]) -> [KPEntry] {
        strictMatchedEntries(from: entries, for: identifiers.map(SiteRequest.init))
    }

    /// The only matches safe to fill without the user choosing.
    static func strictMatchedEntries(from entries: [KPEntry], for requests: [SiteRequest]) -> [KPEntry] {
        let eligible = eligibleEntries(entries)
        let ids = Set(SiteMatcher.strictMatches(eligible.map(candidate), for: requests))
        return eligible.filter { ids.contains($0.id) }
    }

    /// Whether `entry` still lists a requested host itself, expired or not:
    /// the check behind a suggestion, whose expiry the caller handles itself.
    /// A suggestion carries the host it was published for, so a subdomain the
    /// entry moved to no longer counts, unlike in `strictMatchedEntries`.
    static func listsRequestedSite(_ entry: KPEntry, for identifiers: [ASCredentialServiceIdentifier]) -> Bool {
        listsRequestedSite(entry, for: identifiers.map(SiteRequest.init))
    }

    /// Requires the requested host itself, regardless of expiry.
    static func listsRequestedSite(_ entry: KPEntry, for requests: [SiteRequest]) -> Bool {
        let stored = Set(webURLs(of: entry).compactMap { SiteHost($0) })
        return requests.compactMap(\.host).contains(where: stored.contains)
    }

    static func hasWebHost(_ identifiers: [ASCredentialServiceIdentifier]) -> Bool {
        SiteMatcher.firstWebHost(for: identifiers.map(SiteRequest.init)) != nil
    }

    /// The entry's URL fields minus any that hold a raw App ID, which saves
    /// from `.app` requests stored before #137.
    static func webURLs(of entry: KPEntry) -> [String] {
        ([entry.url] + entry.additionalURLs).filter { !SiteMatcher.isStoredAppIdentifier($0) }
    }

    static func candidate(_ entry: KPEntry) -> SiteCandidate {
        SiteCandidate(id: entry.id, urls: [entry.url] + entry.additionalURLs)
    }

    private static func eligibleEntries(_ entries: [KPEntry]) -> [KPEntry] {
        entries.filter { !$0.isExpired() }
    }

    /// Ordered as `ids`. Every entry sharing a matched ID is returned.
    private static func orderedEntries(withIDs ids: [UUID], in entries: [KPEntry]) -> [KPEntry] {
        let byID = Dictionary(grouping: entries, by: \.id)
        return ids.flatMap { byID[$0] ?? [] }
    }
}
