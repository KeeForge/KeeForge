# SiteMatching

**Scope:** which stored credentials a credential request matches, as a standalone Swift package: host parsing and normalization, registrable domains from the Public Suffix List, the publishable-host check for suggestions shown outside the vault, the strict and interactive match tiers, and the passkey relying-party comparison key. Requests from `AuthenticationServices`, entries, expiry, and what to do with a match live in the app (`../../KeeForge/Services/AutoFill/AGENTS.md`).

## Invariants

- No KeeForge types, no `AuthenticationServices`, no UI frameworks. The package depends only on Foundation and `swift-psl` (`PublicSuffixList`). The app converts with `SiteRequest(_:)` and `CredentialMatcher.candidate(_:)` in `../../KeeForge/Services/AutoFill/CredentialMatcher.swift`, and filters expired entries before they become candidates.
- No user-facing text and no logging: inputs are entry URLs.
- A wrong match fills a credential on the wrong origin. Only `strictMatches` may decide a fill without the user choosing; the interactive tiers feed pickers.
- An `.app` request is never read as a host, and a URL field holding a raw App ID (`isStoredAppIdentifier`) is never matched.
- A published identity host must equal what the matcher recomputes from the same stored URL: both come from `SiteHost` parsing.
- Registrable domains come from the Public Suffix List, never from string heuristics.

## Rules that disagree

These were two rule sets in the app before the extraction. Each is kept per call site and pinned by a test named in it; unifying any of them changes a published identity or a match result, so it is an owner decision.

- `relyingPartyKey` drops a leading `www.` unconditionally; `SiteHost` keeps it when it is the registrable label (`www.co.uk`).
- `isPublishable` rejects IP addresses; `sharesRegistrableDomain` and the possible tier use the list's domain alone, so IPv4 addresses sharing their last two octets are related.
- `init?(publishableWebURL:)` checks publishability before the `www` rule and `isPublishable` after it; they differ only on hosts such as `www.1.1`.
- The strict tier normalizes a request host twice, so `www.www.example.com` matches all of `example.com`.

## Public surface

- `SiteHost` (parsing, `isPublishable`, `init?(publishableWebURL:)`, `sharesRegistrableDomain(with:)`, `relyingPartyKey(_:)`), `SiteRequest` (`searchTerm`, `website`), `SiteCandidate`, and `SiteMatcher` (`interactiveMatches`, `strictMatches`, `firstWebHost`, `isStoredAppIdentifier`). Registrable-domain lookups, the possible tier, and prioritization stay internal; widen the surface only for a caller that needs it.

## Tests

- `Tests/SiteMatchingTests` covers the package on its own, with `@testable import SiteMatching`. Prefer independent known answers: `PublicSuffixListVectorTests` runs the list project's `test_psl.txt`, and `WHATWGHostVectorTests` runs the URL Standard's host cases. Each lists its known divergences with the reason; a vector leaving or joining that list is a behavior change to review. `Tests/SiteMatchingTests/Fixtures/README.md` names the sources.
- Hosts are parsed with Foundation's `URL` (RFC 3986), not the WHATWG parser browsers use. The divergences are listed in `WHATWGHostVectorTests`.
- `scripts/coverage.sh` runs the suite and fails below its line, region, and function floors. Swift has no branch records, so region coverage is the branch measure. Raise a floor when coverage rises; never lower one to land a change. The one uncovered region is `URLComponents.string` failing after a host was parsed.
- CI runs the script in the `macos-unit-tests` job (`../../.github/workflows/tests.yml`). Locally, run it under the repo Xcode lock.
- App tests do not link the package; they import it and get its symbols from the host app, as for KDBXKit. `CredentialMatcherTests` covers the conversions and expiry filtering; the identity, coordinator, and save suites cover the call sites.
