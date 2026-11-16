# Browser Bridge Services

**Scope:** the macOS-only, opt-in bridge a browser extension asks for credentials through (#299): protocol and crypto for one connection, request authorization against the open database sessions, where pairings and the app's bridge key are kept, and installing the native-messaging manifest into browsers. Every file is `#if os(macOS)`, excluded from iOS in both project specs (the direct spec inherits the base), and absent from both AutoFill allow-lists. No sockets, UI or logging here. Only the request handler reads database sessions.

## Ownership

- Framing owns directional byte caps; messages own strict wire decoding; crypto owns X25519, HKDF and AES-GCM; the connection state machine owns pairing order, one handshake, counters and pending replies.
- The caller serializes calls off the main thread, supplies the app static key and client lookup, coordinates pairing admission across connections, persists `.paired`, and drives the 120-second pairing timeout and connection cancellation. The request handler owns origin validation, offers, authorization and database policy.
- `BrowserPairingStore` owns the paired-browser records (client id, public key, sanitized name, dates) in the app's own defaults through `SettingsService`, and the installation's X25519 private key in the Keychain. It is an actor; a caller that needs a synchronous lookup keeps its own snapshot.
- The main-actor request handler owns connection-local offers (50 pairs per origin, most recent 8 origins), origin validation, all-open-session reads and the session’s device-owner gate. Eligibility shares `KPGroup.autoFillEntries` with AutoFill, respects database participation, and excludes expired entries and entries with neither a password nor a verification code (the bridge fills no passkeys).
- Credentials require an offer for that exact origin and database/entry pair. Recheck session identity, unlocked/no-pending-lock state, lock cycle and interactive match after authentication; decrypt off actor, then recheck the lease and content revision before releasing. Never block the main actor on socket work.
- `BrowserHostInstaller` owns each browser's `com.keevault.browser.json` and the app-local folder bookmark that lets it write there. Settings supplies the folder-grant closure (the open panel). It asks for `NativeMessagingHosts` when that exists, else its browser parent, and creates only `NativeMessagingHosts` inside the grant; it never creates a missing browser folder. Launch repair uses stored grants and never prompts.
- Per connection: 16 requests in flight, one credential in flight, 30 credential attempts per rolling minute on an injected monotonic clock.

## Invariants

- Wrong version, unknown type, missing and mistyped fields remain distinct decode errors. Ignore unknown extra fields; validate canonical padded base64 and fixed binary lengths. Decode successful replies with the original request operation (`BrowserBridgeJSON.decodeReply`) because the wire has no reply discriminator.
- Each direction requires exactly the next counter, beginning at zero; counters never wrap. Protocol errors send a plaintext error and close, clearing ephemeral state and session keys.
- Never log origins, titles, user names or secrets.
- Pairing records never go in the App Group. The bridge key is stored with the signed app's application-identifier access group, never the default shared group the AutoFill extension reads, as `WhenUnlockedThisDeviceOnly`. A missing signing identity or a Keychain error fails; it never replaces an existing key. Removing a browser keeps the key; reset deletes the key and every record.
- Folder grants never go in the App Group. The installer opens the granted folder itself (the sandbox does not allow the directories above it), refuses a symlinked folder or manifest, never replaces a manifest with another `name`, and removes one only when its `path` is inside a `KeeForge.app`. With no Chromium extension ID configured, set-up fails instead of writing a manifest that allows nothing.
- Keep `../../../docs/browser-bridge-protocol.md` in the same commit as wire changes. Flag ambiguities for the protocol owner instead of silently changing the contract.

## Tests

- `BrowserBridgeRequestHandlerTests`: real-session offers, matching, gates, lock races, references and limits.
- `BrowserBridgeProtocolTests` in `KeeForgeMacTests`: framing, strict decoding, pairing, handshake, rejection paths, authenticated counters and deterministic vectors. The client reference lives only in that test file.
- `../../../BrowserExtension/test/vectors.json` is bundled by `UnitTestFixtures`; regeneration instructions are in the test header. The extension tests consume the same file.
- `BrowserHostInstallerTests`: fake home, isolated defaults, fake bookmarks, the real file code in a temporary directory. No panel and no real browser folder.
- `BrowserPairingStoreTests`: records, name sanitizing, last-used coalescing and key lifetime, with an injected clock and a fake Keychain. Tests never touch the real Keychain.

## See also

- `../AGENTS.md`, `../../../docs/browser-bridge-protocol.md`, `../../../KeeForgeTests/AGENTS.md`
