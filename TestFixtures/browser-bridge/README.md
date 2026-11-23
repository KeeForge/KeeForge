# Browser bridge conformance fixtures

Language-neutral cases for what the app answers to the browser bridge's `matches` request (`../../docs/browser-bridge-protocol.md`): which origins it accepts, which stored entries match an origin, and how the reply is filtered, ordered, capped and cut. Any implementation of the app side of the bridge (the Mac app today; a Windows app later) loads these files and must produce exactly these answers. The files record what the Mac app does, including the behaviour listed under "Known quirks".

A change in matching or origin behaviour changes these files in the same commit.

| File | Covers | Run by |
| --- | --- | --- |
| `origins.json` | which `origin` strings are accepted | `KeeForgeTests/BrowserBridgeFixtureTests` (app), `BrowserExtension/test/origin-fixtures.test.js` (extension, with listed differences) |
| `site-matching.json` | which entry URLs match an origin, exact or possible | `Packages/SiteMatching/Tests/SiteMatchingTests/BrowserBridgeSiteFixtureTests` (package), `KeeForgeTests/BrowserBridgeFixtureTests` (app) |
| `bridge-matches.json` | eligibility, databases, ordering, the 50-row cap, display-field cuts, errors | `KeeForgeTests/BrowserBridgeFixtureTests` (app) |

Every file is a JSON object `{"version": 1, "cases": [...]}`. A runner fails on an unknown version. The JSON is ASCII; other characters are `\u` escapes so control and invisible characters stay visible. Optional fields may be absent; the defaults are given below. `name` and `note` are descriptions only.

## `origins.json`

Each case is `{"origin": string, "valid": bool, "note": string}`. A `matches` or `credential` request with an origin whose `valid` is `false` is answered `bad-origin`, before anything else is checked (an invalid origin is `bad-origin` even with every database locked). A valid origin is then handled normally: with no database open, `matches` answers `locked`.

The accepted form, as the app implements it:

- Every character is printable ASCII (U+0021 to U+007E), and there is no `\` or `%`.
- The value is exactly `<scheme>://<host>` or `<scheme>://<host>:<port>`, scheme lower-case `https` or `http`; no user info (even empty), path (even `/`), query or fragment (even empty).
- The port is decimal digits only; a port that parses is 0 to 65535. A port written out is accepted even when it is the default (`:443`) or has leading zeros; `:` with no digits is refused.
- The host is non-empty. A bracketed host must be an IPv6 address (any spelling `inet_pton` accepts, no zone); an unbracketed host must not contain `:`. Hosts are not otherwise checked: upper case, a trailing dot, `_`, a leading `-`, labels over 63 characters and non-canonical IPv4 forms are accepted. Hosts longer than 2048 characters are refused.
- `http` is accepted only when the host, compared case-insensitively, is `localhost`, `127.0.0.1` or `[::1]` (that spelling exactly).

Browsers send origins in their canonical serialization, so in practice the extension never sends the forms the app is lenient about. The extension's own check (`BrowserExtension/src/protocol.js`, `origin`) requires the canonical serialization and therefore differs on these cases, which its test lists by origin:

- Stricter (the extension refuses, the app accepts): upper- or mixed-case hosts, `http://LOCALHOST`, a written-out default port (`:443`, `http://localhost:80`), a port with leading zeros, a port too large to parse, non-canonical IPv6 (`[2001:0DB8::1]`, `[::ffff:192.0.2.1]`), non-canonical IPv4 (`0x7f.0.0.1`) and hosts ending in a number that are not IPv4 (`foo.1.2.3.4`).
- Looser (the extension accepts, the app refuses): hosts longer than 2048 characters.

## `site-matching.json`

Each case is `{"origin": string, "entries": [{"id": string, "urls": [string]}], "expected": [{"entry": string, "exact": bool}]}`. Every `origin` here is valid. `id` is a label, unique within the case; map it to any entry identifier. `urls` is the entry's URL fields in order: the entry's URL first, then its additional URL fields (see `bridge-matches.json`). An entry with no URL is `"urls": []`, and `""` is an empty field.

Each entry is classified on its own against the origin (with no other entries present):

- **exact** when one of its URLs names the origin's host itself, after normalization;
- **possible** otherwise, when one of its URLs names a host on the same registrable domain as the origin's host (a subdomain, the parent, or a sibling);
- otherwise it does not match.

`expected` lists the exact entries in entry order, then the possible entries in entry order. Entries that do not match are absent.

Hosts are normalized the same way on both sides. The rules are those of the SiteMatching package (`../../Packages/SiteMatching/AGENTS.md`, rules H1 to H7, S1, S2, T1 to T4); in short:

- A stored value is trimmed. A value without `<scheme>://` is read as `https://<value>`; only `http` and `https` name a site. `\` counts as `/`. User info, port, path, query and fragment are ignored, so scheme and port never separate sites.
- Hosts are lowercased, lose trailing dots, and are compared in punycode (an entry stored as `bücher.de` names `xn--bcher-kva.de`). One leading `www.` is dropped when what remains has a registrable domain.
- The registrable domain is the Public Suffix List's eTLD+1, private section included (`github.io`, `blogspot.com`). IP addresses (IPv6, or a last label that is a number), single labels and bare public suffixes have none and match only themselves. Addresses compare as written, lowercased: `[2001:0db8::1]` does not match `[2001:db8::1]`.
- A value that is an App ID (`[A-Z0-9]{10}` then one or more `.label`s, no scheme or path) is never a host.

## `bridge-matches.json`

Each case is `{"origin": string, "databases": [Database], "expected": Expected}`.

`Database`: `{"id": string, "autofill": bool = true, "locked": bool = false, "searching": Searching, "entries": [Entry], "groups": [Group] = []}`. The object is the database's root group as well. `databases` is in the order the app lists its open databases; `id` is a label unique within the case. `locked: true` is an open database that is locked (or has a lock pending). `autofill: false` is a database whose AutoFill participation is turned off.

`Group`: `{"searching": Searching, "recycleBin": bool = false, "entries": [Entry] = [], "groups": [Group] = []}`. At most one group per database has `recycleBin: true`: it is the database's recycle bin.

`Searching`: absent (KeePass "inherit"), `"enabled"` or `"disabled"` (the group's `EnableSearching`).

`Entry`: `{"id": string, "title": string = "", "username": string = "", "url": string = "", "notes": string = "", "fields": {string: string} = {}, "protected": [string] = [], "password": bool = true, "totp": bool = false, "expiry": "past" | "future" = none}`. `fields` are custom string fields, `protected` names the ones stored protected, `password: false` is an empty password, `totp: true` gives the entry a verification-code configuration, and `expiry` turns expiry on with a time in the past or the future (absent: expiry off). An `id` may repeat across databases (the same entry in two databases) but not within one.

`Expected` is either `{"error": "locked" | "bad-origin"}` or `{"locked": int, "rows": [Row]}`. `Row`: `{"entry": string, "db": string, "exact": bool, "title": string, "username": string, "hasTotp": bool}`, where `title`, `username` and `hasTotp`, when present, must equal the reply's field exactly (compare Unicode scalars, not canonical equivalence); when absent they are not checked.

The reply is computed as follows:

1. An invalid origin (`origins.json`) is `bad-origin`.
2. If no database is unlocked, the answer is `locked`. Otherwise `locked` in the reply is the number of locked databases.
3. Databases with `autofill: false` contribute nothing (and are not an error).
4. A database's eligible entries are collected depth first: a group's own entries, then each subgroup's, in order. A group whose `searching` is `"disabled"` contributes no entries of its own, and its subgroups inherit that unless they say `"enabled"`; absent inherits, and the root's parent counts as enabled. The recycle bin and everything under it are skipped, whatever their `searching`. Entries whose expiry has passed are skipped, as are entries with neither a password nor `totp`.
5. An entry's URLs are its `url` followed by the values of its `fields` whose name starts with `KP2A_URL_` (case-sensitive, underscore included), that are non-empty and not `protected`, sorted by field name (ordinal). No other field is read: not the title, the notes, `URL`, `KP2A_URL` or `AndroidApp`.
6. Each eligible entry is classified as in `site-matching.json`. Exact rows are kept in database order then entry order, possible rows likewise; the reply lists all exact rows, then the possible rows, at most 50 rows in all (so possible rows only fill what the exact rows leave).
7. `title` and `username` are cut to their first 256 characters, a character being an extended grapheme cluster (a user-perceived character: `e` + U+0301, a flag pair or a ZWJ emoji sequence counts as one). `hasTotp` is `totp`.

Not covered here, because they are not about matching or need KeePass internals: field references in the user name (`{REF:U@I:…}` is resolved; a reference to a protected value shows as empty), the database name (`dbName`, cut to 256 characters like `title`), dropping trailing rows until the sealed reply fits the frame limit, rate limits, and the offers a reply creates. `BrowserBridgeRequestHandlerTests` covers those.

## Known quirks

These are recorded as the app behaves; a change to any of them is a decision, made in the app and in these files together.

- Possible matches are not ordered by nearness: a subdomain of the requested host does not come before a parent or sibling (`site-matching.json`, "possible matches keep entry order, not nearness"). AutoFill's picker, which classifies all entries together, does order them.
- `mailto:user@example.com` stored as a URL matches `https://example.com` exactly: a value without `://` is read as `https://<value>`.
- The app accepts non-canonical origins the browser never sends (see the stricter list above), including a port too large to parse, which it treats as no port.
- Hosts longer than 2048 characters are refused because the platform URL parser refuses them, not by a rule of the protocol.
