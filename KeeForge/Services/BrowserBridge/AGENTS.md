# Browser Bridge Services

**Scope:** the macOS-only, opt-in bridge a browser extension asks for credentials through (#299): protocol and crypto for one connection, and where pairings and the app's bridge key are kept. Every file is `#if os(macOS)`, excluded from iOS in both project specs (the direct spec inherits the base), and absent from both AutoFill allow-lists. No sockets, Keychain, UI, database/session models or logging.

## Ownership

- Framing owns directional byte caps; messages own strict wire decoding; crypto owns X25519, HKDF and AES-GCM; the connection state machine owns pairing order, one handshake, counters and pending replies.
- The caller serializes calls off the main thread, supplies the app static key and client lookup, coordinates pairing admission across connections, persists `.paired`, and drives the 120-second pairing timeout and connection cancellation. The request handler owns origin validation, offers, authorization and database policy.
- `BrowserPairingStore` owns the paired-browser records (client id, public key, sanitized name, dates) in the app's own defaults through `SettingsService`, and the installation's X25519 private key in the Keychain. It is an actor; a caller that needs a synchronous lookup keeps its own snapshot.

## Invariants

- Wrong version, unknown type, missing and mistyped fields remain distinct decode errors. Ignore unknown extra fields; validate canonical padded base64 and fixed binary lengths. Decode successful replies with the original request operation (`BrowserBridgeJSON.decodeReply`) because the wire has no reply discriminator.
- Each direction requires exactly the next counter, beginning at zero; counters never wrap. Protocol errors send a plaintext error and close, clearing ephemeral state and session keys.
- Never log origins, titles, user names or secrets.
- Pairing records never go in the App Group. The bridge key is stored with the signed app's application-identifier access group, never the default shared group the AutoFill extension reads, as `WhenUnlockedThisDeviceOnly`. A missing signing identity or a Keychain error fails; it never replaces an existing key. Removing a browser keeps the key; reset deletes the key and every record.
- Keep `../../../docs/browser-bridge-protocol.md` in the same commit as wire changes. Flag ambiguities for the protocol owner instead of silently changing the contract.

## Tests

- `BrowserBridgeProtocolTests` in `KeeForgeMacTests`: framing, strict decoding, pairing, handshake, rejection paths, authenticated counters and deterministic vectors. The client reference lives only in that test file.
- `../../../BrowserExtension/test/vectors.json` is bundled by `UnitTestFixtures`; regeneration instructions are in the test header. The extension tests consume the same file.

- `BrowserPairingStoreTests`: records, name sanitizing, last-used coalescing and key lifetime, with an injected clock and a fake Keychain. Tests never touch the real Keychain.

## See also

- `../AGENTS.md`, `../../../docs/browser-bridge-protocol.md`, `../../../KeeForgeTests/AGENTS.md`
