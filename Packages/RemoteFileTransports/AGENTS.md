# RemoteFileTransports

**Scope:** the WebDAV and plain-FTP protocol clients as a standalone Swift package: requests and replies, the live `URLSession` and Network.framework transports, PROPFIND and listing parsers, and the URL rules for an account's server address. Providers, credential storage, account ids, conflict handling, and every user-facing message live in `KeeForge/Services/Cloud/`.

## Invariants

- No KeeForge types, no UI frameworks, no app policy. The package depends only on Foundation, Network, and os.
- No user-facing text. Errors are plain enums (`WebDAVError`, `WebDAVURLError`, `WebDAVPropfindParseError`, `FTPClientError`, `FTPURLError`); the app words them (`KeeForge/Services/Cloud/WebDAVError+CloudProvider.swift`, `FTPCloudProvider.mapError`). Adding a `WebDAVError` case means adding its mapping there, which the compiler enforces.
- No logging or printing: requests carry credentials and database bytes, and URLs name a user's server and folders.
- `WebDAVClient` returns every HTTP status as a `Response`; the caller maps it with `WebDAVError(statusCode:isPropfind:)`. A `URLError` is classified into `WebDAVError`; any other error a transport throws passes through unchanged. TLS and ATS failures are never `offline`, because the app shows `offline` as the calm cached-copy path.
- The live WebDAV transport stores nothing (no cache, cookies, or credential storage), caps PROPFIND bodies at 64 MiB and others at 512 MiB, follows only same-origin redirects, and re-sends only the original `Authorization`.
- `FTPSession` is deliberately not `Sendable`. It exists only inside the `FTPClient.withSession` closure, driven by one task one call at a time; it must not escape the closure. Each operation opens its own session.
- FTP arguments containing CR, LF, or NUL are refused before sending, and passive data connections always go to the control host, never the address a server advertises.
- `WebDAVURL` requires `https` unless the caller opts into HTTP; `FTPURL` refuses unless the caller opts into plaintext FTP. The opt-ins are the caller's to hold.

## Public surface

- WebDAV: `WebDAVClient` (`propfindList`, `probe`, `head`, `get`, `put`, `liveTransport`, the two size caps), `WebDAVClient.Credential`, `WebDAVClient.Response`, `WebDAVError`, `WebDAVPropfindParser.parse` with `lastComponent` and `parseRFC1123`, `WebDAVResource`, `WebDAVURL` (`normalizedBaseURL`, `displayName`), `WebDAVURLError`.
- FTP: `FTPClient` (`withSession`, a live and an injectable-connector initializer), `FTPSession` (`changeDirectory`, `listCurrentDirectory`, `listDirectory`, `stat`, `retrieve`, `store`, `rename`, `delete`), `FTPByteStream`, `FTPReply`, `FTPClientError`, `FTPListEntry` with `date(fromTimeVal:)`, `FTPPath`, `FTPURL` (`normalizedBaseURL`, `location`, `displayName`), `FTPServerLocation`, `FTPURLError`.
- Internal: the redirect delegate, the PROPFIND delegate and its path helpers, `FTPListingParser`, reply reading, passive-port parsing, and `FTPNetworkStream`. Widen only for a caller that needs it.
- Account ids stay in the app (`WebDAVModels.swift`, `FTPModels.swift`): they are persisted identifiers, and hashing them would pull CryptoKit into the package.

## Tests

- `Tests/RemoteFileTransportsTests` covers the package on its own, with `@testable import RemoteFileTransports`. Prefer known answers from the specifications and real servers over round trips; `Tests/RemoteFileTransportsTests/Fixtures/README.md` names the sources.
- The live transports run against loopback servers on 127.0.0.1 (`LoopbackServer.swift`), so redirects, the size caps, and connection lifecycle are tested, not excluded.
- `Sources/RemoteFileTransportsTestSupport/FakeFTPServer.swift` is an in-memory FTP server behind `FTPClient`'s connector seam. It is a package target but not a product: the app's test targets compile the file directly (`../../project.yml`) so it uses the host app's copy of the package.
- `scripts/coverage.sh` runs the suite and fails below its line, region, and function floors. Raise a floor when coverage rises; never lower one to land a change. The uncovered remainder is Network.framework failure callbacks that loopback cannot provoke, the port-0 guard (Network accepts port 0, and `FTPURL` never produces it), and compiler regions after `while true` loops.
- CI runs the script in the `macos-unit-tests` job (`../../.github/workflows/tests.yml`). Locally it needs no Xcode lock.
- App tests do not link the package; they import it and get its symbols from the host app, since a second copy would make thrown errors fail type matches. They cover what the app adds on top: provider behavior, the messages for each `WebDAVError` (`WebDAVErrorMessageTests`), and account ids.
