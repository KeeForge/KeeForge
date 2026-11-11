# SiteMatching

Decides which stored credentials a website or app request matches, the way a password manager's AutoFill needs to: by host, with registrable-domain boundaries from the [Public Suffix List](https://publicsuffix.org).

Swift 6, iOS 18+ / macOS 15+. Depends on [swift-psl](https://github.com/ameshkov/swift-psl).

## Matching

```swift
import SiteMatching

let requests: [SiteRequest] = [.url("https://login.example.com/signin")]
let candidates = entries.map { SiteCandidate(id: $0.id, urls: $0.urls) }

// Safe to fill without asking: the stored host is the requested host or a
// subdomain of it on the same registrable domain. `mybank.com` never matches
// a `bank.com` request, and an IP address or `co.uk` matches only itself.
let fillable = SiteMatcher.strictMatches(candidates, for: requests)

// For a picker: entries storing the requested host itself, or else related
// hosts on the same registrable domain, nearest first.
let sections = SiteMatcher.interactiveMatches(candidates, for: requests)
```

Results are candidate IDs in a stable order. Expired or otherwise ineligible credentials should be left out of `candidates`.

An `.app` request (an App ID such as `TEAMID.com.example.app`) never matches a website: reverse-DNS App IDs end in real top-level domains.

## Hosts

```swift
SiteHost("https://WWW.Example.co.uk:8443/login")?.name   // "example.co.uk"
SiteHost("https://www.co.uk")?.name                      // "www.co.uk": www is the registrable label
SiteHost("https://192.168.1.1")?.isPublishable           // false: an IP address
SiteHost("https://www.www.example.com")?.name            // "www.example.com": one www, once
SiteHost(publishableWebURL: "otpauth://totp/x")          // nil: not a web URL
SiteRequest.url("https://example.com/a?b").website?.url  // "https://example.com"
```

A host is publishable when it has a registrable domain: not an IP address, `localhost`, a single label, or a bare public suffix. Use it before showing a host outside the app. A host whose last label is a number counts as an IP address, as in browsers.

The full rule set, with the test that covers each rule, is in [AGENTS.md](AGENTS.md).

Hosts are parsed with Foundation's `URL`, which follows RFC 3986 rather than the WHATWG URL Standard. The two differ on IPv4 number forms, backslashes, embedded tabs, and percent-encoded hosts; the test suite lists each case.

## Tests and coverage

```bash
swift test
scripts/coverage.sh
```

`scripts/coverage.sh` reports line, region, and function coverage for `Sources/SiteMatching` and fails below its thresholds. LLVM records no branch coverage for Swift; region coverage, which counts each side of every condition, stands in for it.
