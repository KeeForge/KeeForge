# RemoteFileTransports

WebDAV and plain-FTP clients in Swift, for reading and writing one file on a user's server. They speak the protocols and report failures as plain enums; storing credentials and wording errors is up to you.

Swift 6, iOS 18+ / macOS 15+. Depends only on Foundation, Network, and os.

## WebDAV

```swift
import RemoteFileTransports

let base = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/remote.php/dav/files/alice")
let client = WebDAVClient(transport: WebDAVClient.liveTransport())
let credential = WebDAVClient.Credential(username: "alice", password: password)

let listing = try await client.propfindList(url: base, credential: credential)
if let error = WebDAVError(statusCode: listing.statusCode, isPropfind: true) {
    throw error
}
let resources = try WebDAVPropfindParser.parse(data: listing.data, requestURL: base)
```

Operations return any status in a `Response` (with `eTag`, `ocETag`, `lastModified`, `contentLength`); map it with `WebDAVError(statusCode:isPropfind:)`, which is nil for 2xx. `put` takes `ifMatch` and `ifNoneMatch` for conditional writes.

The live transport uses an ephemeral session that stores nothing, sends Basic authorization on every request, follows same-origin redirects only, and stops a PROPFIND body over 64 MiB or any other body over 512 MiB. Inject your own `Transport` closure to test without a network.

## FTP

```swift
let address = try FTPURL.normalizedBaseURL(from: "nas.local/Vaults", allowsUnencryptedFTP: true)
guard let location = FTPURL.location(fromNormalizedBaseURL: address) else { return }

let data = try await FTPClient().withSession(
    host: location.host, port: location.port, username: "alex", password: password
) { session in
    try await session.changeDirectory(location.basePath)
    return try await session.retrieve("personal.kdbx")
}
```

A session prefers EPSV and MLSD/MLST, falling back to PASV, LIST, and SIZE/MDTM. Passive data connections always go to the control host. `FTPSession` is not `Sendable`: use it only inside the `withSession` closure, one call at a time. Plain FTP sends the password in the clear, so `FTPURL` refuses unless you opt in.

## Errors

`WebDAVError` (HTTP status classes with their code, and classified `URLError`s with theirs), `WebDAVURLError`, `WebDAVPropfindParseError`, `FTPClientError` (the server's `FTPReply` where there is one), and `FTPURLError`. None carries user-facing text.

## Tests and coverage

```bash
swift test
scripts/coverage.sh
```

`scripts/coverage.sh` reports line, region, and function coverage for `Sources/RemoteFileTransports` and fails below its thresholds. The live transports are tested against loopback servers.
