# SiteMatching

**Scope:** which stored credentials a credential request matches, as a standalone Swift package: host parsing and normalization, registrable domains from the Public Suffix List, the publishable-host check for suggestions shown outside the vault, the strict and interactive match tiers, and the passkey relying-party comparison key. Requests from `AuthenticationServices`, entries, expiry, and what to do with a match live in the app (`../../KeeForge/Services/AutoFill/AGENTS.md`).

## Invariants

- No KeeForge types, no `AuthenticationServices`, no UI frameworks. The package depends only on Foundation and `swift-psl` (`PublicSuffixList`). The app converts with `SiteRequest(_:)` and `CredentialMatcher.candidate(_:)` in `../../KeeForge/Services/AutoFill/CredentialMatcher.swift`, and filters expired entries before they become candidates.
- No user-facing text and no logging: inputs are entry URLs.
- The rules below are the specification. Code and tests follow it; a change to a rule is a decision recorded in an issue, never a side effect of a fix.
- A new matching report is checked against these rules first: either the code breaks a rule (a bug) or the report asks for a rule change (a decision).

## Rules

Each rule has a test whose name starts with its ID (`testH4…`); `SpecificationTests` fails when a rule here has none.

### Hosts

- **H1 Parsing.** A stored value or request is trimmed of surrounding whitespace and parsed with Foundation's `URL` (RFC 3986). Only `http` and `https` URLs name a site; a value without a scheme is read as `https://<value>`, so bare hosts, `host:port`, and `host/path` work. Any other scheme names no site: `androidapp://com.mybank.app`, as Android KeePass clients store apps, would otherwise be a subdomain of the unrelated `mybank.app`, and the same holds for `ftp://`, `ssh://`, `otpauth://`, `file://`, and `cmd://`. A backslash counts as a slash, as browsers read http and https URLs, so `https://example.com\@other.example` names `example.com`. User info, path, query, and fragment are ignored. A value that does not parse, or parses to an empty host, names no site; it is never parsed a second time.
- **H2 Schemes and ports.** Matching compares hosts only. `http` and `https` name the same site, and a port does not separate sites.
- **H3 Case, trailing dots, internationalized names.** Hosts are lowercased and lose trailing dots. Internationalized names are compared in the ASCII (punycode) form Foundation produces, which is the form browsers request.
- **H4 Leading `www`.** One leading `www.` label is dropped when the rest has a registrable domain (H5) and kept otherwise: `www.example.co.uk` is `example.co.uk`, while `www.co.uk`, `www.localhost`, and `www.1.1` stay as they are.
- **H5 Registrable domain.** The Public Suffix List's eTLD+1, from the embedded `swift-psl` list and never from string heuristics. IP addresses, single labels such as `localhost`, and bare public suffixes such as `co.uk` or `github.io` have none.
- **H6 IP addresses.** A host is an IP address when it is IPv6 or its last label is a number: decimal digits, or `0x` and hex digits. That is the URL Standard's "ends in a number" check, so `foo.1.2.3.4`, which browsers reject, counts too.
- **H7 One normalization.** Every stored and requested host is normalized by H1–H4 exactly once, so `www.www.example.com` is `www.example.com`.

### Requests

- **R1 Web requests.** A `.domain` or `.url` request names the host H1–H7 give it. A request whose value has no host matches nothing and does not hide the other requests.
- **R2 App requests.** An `.app` request (an App ID such as `TEAMID.com.example.app`) is never read as a host: reverse-DNS App IDs end in real top-level domains and would match the unrelated website `example.app`.
- **R3 Saved website.** `SiteRequest.website`, the URL an AutoFill save stores, keeps only scheme, host, and port. The scheme is `http` only when the request says so, and the host stays as requested apart from case and trailing dots (H4 is applied when it is matched).

### Stored URLs

- **S1 Every URL field.** The entry URL and every additional URL field are matched, in order. Empty and unparsable fields are skipped.
- **S2 Stored App IDs.** A field holding a raw App ID (`TEAMID.bundle.id`: an uppercase ten-character Team ID and no scheme or path), as saves from app requests once stored, is never matched and never published. Hosts that only resemble one still match.

### Tiers

- **T1 Exact.** Candidates storing the first requested web host itself. When there are any, a picker offers only them.
- **T2 Strict.** A stored host equal to a requested host, or a dotted subdomain of it on the same registrable domain: `login.paypal.com` matches `paypal.com`, `mybank.com` does not match `bank.com`, and `google.com` does not match `accounts.google.com`. Only this tier may fill without the user choosing, so it is the most conservative.
- **T3 Hosts without a registrable domain.** An IP address, a single label, or a bare public suffix matches only itself, in every tier and in the related-site check (`sharesRegistrableDomain`): `co.uk` does not match `bank.co.uk`, and `192.168.1.1` does not relate to `10.0.1.1`.
- **T4 Possible.** Only when T1 is empty: the strict matches for any requested host, then every stored host on a requested registrable domain, so parents and siblings appear. These feed pickers and are never filled without the user choosing.
- **T5 Order.** Possible matches appear once each. A host equal to the first requested host comes first, then a subdomain of it, then the same for each later requested host. Ties keep the candidates' order.

Passwords and one-time codes use the same tiers; the app decides which tier a flow may act on (`../../AutoFillExtension/AGENTS.md`).

### Passkeys

- **K1 Relying-party key.** Two relying-party identifiers compare equal when their hosts are equal under H1–H7, so `www.example.com` equals `example.com` but `www.co.uk` does not equal `co.uk`. There is no subdomain relation: a passkey for `login.example.com` is not offered to `example.com`.
- **K2 Unparsable relying parties.** An identifier that names no site is compared as given, trimmed, lowercased, without trailing dots, and with H4 applied.

### Publishing

- **P1 Publishable.** A host may stand for a site outside the vault only when it has a registrable domain (H5). The check runs on the normalized host, after H4.
- **P2 Password identities.** A password identity publishes the publishable host of each URL field that names a site (H1).
- **P3 One-time-code identities.** A one-time-code identity publishes `SiteHost(publishableWebURL:)` for each URL field: the same host P2 publishes.
- **P4 Published equals matched.** A host published to the system identity store always equals the host matching computes from the same stored value. Both come from `SiteHost` parsing; nothing else derives a host.

A rule change that alters published identities takes effect at each database's next unlock, which republishes its identities. The app owns that refresh and its test (`../../KeeForge/Services/AutoFill/AGENTS.md`).

## Accepted divergences

The known-answer suites list only these, each with its reason in the test. A vector joining or leaving a list is a rule change to review.

- **Public Suffix List** (`PublicSuffixListVectorTests`): a leading empty label (`.example.com`) is ignored rather than rejected, so the host counts as part of the domain that follows. Matching and publishing agree on it (P4).
- **WHATWG host parsing** (`WHATWGHostVectorTests`). Foundation follows RFC 3986, not the URL Standard browsers use. Every accepted difference but the last fails closed: the stored value names no host a browser requests, so it matches nothing a browser asks for.
  - Embedded tab or newline, and characters RFC 3986 forbids in a host: Foundation rejects the URL, so it names no site.
  - IPv4 number forms (hex, octal, shortened) and IPv6 serialization: kept as written instead of rewritten to the canonical address, so they match only the same spelling. Those whose last label is a number are still IP addresses under H6.
  - Percent-encoded and fullwidth host characters: not decoded, so the host is one no browser requests.
  - Brackets around a domain (`http://[google.com]`): Foundation reads the domain inside. Matching and publishing agree on it (P4).
- Closing a divergence needs a rule change here; replacing Foundation's parser is not planned.

## Public surface

- `SiteHost` (parsing, `isPublishable`, `init?(publishableWebURL:)`, `sharesRegistrableDomain(with:)`, `relyingPartyKey(_:)`), `SiteRequest` (`host`, `website`), `SiteCandidate`, and `SiteMatcher` (`interactiveMatches`, `strictMatches`, `firstWebHost`, `isStoredAppIdentifier`). Registrable-domain lookups, the possible tier, and prioritization stay internal; widen the surface only for a caller that needs it.

## Tests

- `Tests/SiteMatchingTests` covers the package on its own, with `@testable import SiteMatching`. Prefer independent known answers: `PublicSuffixListVectorTests` runs the list project's `test_psl.txt`, and `WHATWGHostVectorTests` runs the URL Standard's host cases. `Tests/SiteMatchingTests/Fixtures/README.md` names the sources.
- `SpecificationTests` checks that every rule ID above names a test.
- `scripts/coverage.sh` runs the suite and fails below its line, region, and function floors. Swift has no branch records, so region coverage is the branch measure. Raise a floor when coverage rises; never lower one to land a change. The one uncovered region is `URLComponents.string` failing after a host was parsed.
- CI runs the script in the `macos-unit-tests` job (`../../.github/workflows/tests.yml`). Locally, run it under the repo Xcode lock.
- App tests do not link the package; they import it and get its symbols from the host app, as for KDBXKit. `CredentialMatcherTests` covers the conversions and expiry filtering; the identity, coordinator, and save suites cover the call sites.
