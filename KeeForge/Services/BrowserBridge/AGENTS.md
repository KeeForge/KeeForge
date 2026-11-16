# Browser Bridge Services

**Scope:** the macOS-only, opt-in bridge a browser extension asks for credentials through (#299): protocol and crypto for one connection, request authorization against the open database sessions, where pairings and the app's bridge key are kept, and installing the native-messaging manifest into browsers. Every file is `#if os(macOS)`, excluded from iOS in both project specs (the direct spec inherits the base), and absent from both AutoFill allow-lists. No UI or logging here. Only the request handler reads database sessions.

## Ownership

- Framing owns directional byte caps; messages own strict wire decoding; crypto owns X25519, HKDF and AES-GCM; the connection state machine owns pairing order, one handshake, counters and pending replies.
- `MacBrowserBridgeController` owns the socket and observable lifecycle. Each connection serializes session calls and writes on its own queue; requests independently await its main-actor handler, so authentication never stalls status. The main actor never waits for those queues or socket threads.
- The controller reads the bridge key, then loads a lock-protected client-key snapshot, before listening, and adds an allowed pairing to it after the store saves it and before `pair-result` is written. The injected 120-second answer timeout is cleared on answer, close or shutdown; an answer is applied only to the pending pairing's id.
- Pairing limits (`BrowserPairingGate`, owned by the controller so a restart resets nothing): one slot, taken at `pair-commit` before any `pair-key`; at most 5 admitted commits per 60 seconds; a 10-second cooldown after any pairing that ends without being allowed (declined, timed out, failed, closed, abandoned at shutdown). Everything refused is `pairing-busy`, never `pairing-declined`. These limits are what bound a relay's code guesses; never issue a `pair-key` without the slot.
- Connection deadlines on the injected clock: 10 seconds from connect to `hello` or `pair-commit`, and 10 seconds from commit to `pair-reveal` (closing frees the slot). Bridge sockets have a 5-second send timeout; switching off closes a connection whose send is waiting on the peer instead of writing `disabled`, and more than 64 blocks queued on a connection closes it.
- The session sanitizes the browser name (`BrowserPairingStore.sanitizedName`) before any pairing event leaves it; UI shows names through `displayName`, which substitutes a localized neutral label for an empty name. `matches` display fields are cut to 256 characters and trailing rows dropped until the sealed reply fits; offers cover only the rows returned. Removing a browser takes it out of the snapshot under the same lock and closes its connections. Switching off cancels every request, removes the socket file, then writes each session's `disabled` and closes it on its own queue; nothing else is written after that, including a credential that was waiting on the device-owner prompt.
- `BrowserPairingStore` owns the paired-browser records (client id, public key, sanitized name, dates) in the app's own defaults through `SettingsService`, and the installation's X25519 private key in the Keychain. It is an actor; a caller that needs a synchronous lookup keeps its own snapshot.
- The main-actor request handler owns connection-local offers (50 pairs per origin, most recent 8 origins), origin validation, all-open-session reads and the session’s device-owner gate. Eligibility shares `KPGroup.autoFillEntries` with AutoFill, respects database participation, and excludes expired entries and entries with neither a password nor a verification code (the bridge fills no passkeys).
- Credentials require an offer for that exact origin and database/entry pair. Recheck session identity, unlocked/no-pending-lock state, lock cycle and interactive match after authentication; decrypt off actor, then recheck the lease and content revision before releasing. Never block the main actor on socket work.
- `BrowserHostInstaller` owns each browser's `com.keevault.browser.json` and the app-local bookmark of that browser's `NativeMessagingHosts` folder. Settings supplies the folder-grant closure (the open panel). It asks for `NativeMessagingHosts` when that exists, else its browser parent, and creates only `NativeMessagingHosts` inside the grant; it never creates a missing browser folder. A parent grant is used once and never bookmarked; a stored bookmark that resolves anywhere but that `NativeMessagingHosts` folder is access lost. Launch repair uses stored grants, never prompts, and runs only from an Applications folder while this copy's bridge listens (`mayRepairAtLaunch`).
- Per connection: 16 requests in flight, one credential in flight, 30 credential attempts per rolling minute, and `reveal` and `unlock` together a burst of 3 then one per second, on an injected monotonic clock.

## Invariants

- Wrong version, unknown type, missing and mistyped fields remain distinct decode errors. Ignore unknown extra fields; validate canonical padded base64 and fixed binary lengths. Decode successful replies with the original request operation (`BrowserBridgeJSON.decodeReply`) because the wire has no reply discriminator.
- Each direction requires exactly the next counter, beginning at zero; counters never wrap. Protocol errors send a plaintext error and close, clearing ephemeral state and session keys.
- Never log origins, titles, user names or secrets.
- Pairing records never go in the App Group. The bridge key is stored with the signed app's application-identifier access group, never the default shared group the AutoFill extension reads, as `WhenUnlockedThisDeviceOnly`. A missing signing identity or a Keychain error fails; it never replaces an existing key. Removing a browser keeps the key; reset deletes the key and every record.
- Folder grants never go in the App Group. The installer opens the granted folder itself (the sandbox does not allow the directories above it), refuses a symlinked folder or manifest, never replaces a manifest with another `name`, and removes one only when its `path` is inside a `KeeForge.app`. With no Chromium extension ID configured, set-up fails instead of writing a manifest that allows nothing.
- Keep `../../../docs/browser-bridge-protocol.md` in the same commit as wire changes. Flag ambiguities for the protocol owner instead of silently changing the contract.

## Tests

- `MacBrowserBridgeControllerTests`: real Unix sockets, injected Keychain, manual bridge clock and device-owner gate; lifecycle, pairing slot, attempt limit, cooldown and deadlines, revocation, stalled peers and credential concurrency.
- `BrowserBridgeRequestHandlerTests`: real-session offers, matching, gates, lock races, references and limits.
- `BrowserBridgeProtocolTests` in `KeeForgeMacTests`: framing, strict decoding, pairing, handshake, rejection paths, authenticated counters and deterministic vectors. The reference client is shared test support.
- `../../../BrowserExtension/test/vectors.json` is bundled by `UnitTestFixtures`; regeneration instructions are in the test header. The extension tests consume the same file.
- `BrowserHostInstallerTests`: fake home, isolated defaults, fake bookmarks, the real file code in a temporary directory. No panel and no real browser folder.
- `BrowserPairingStoreTests`: records, name sanitizing (separators, controls, combining marks, caps), last-used coalescing and key lifetime, with an injected clock and a fake Keychain. Tests never touch the real Keychain.

## See also

- `../AGENTS.md`, `../../../docs/browser-bridge-protocol.md`, `../../../KeeForgeTests/AGENTS.md`
