# Browser Bridge Protocol

**Scope:** synchronous, platform-neutral protocol and crypto for one Mac app connection. Every file is `#if os(macOS)`, excluded from iOS in both project specs (the direct spec inherits the base), and absent from both AutoFill allow-lists. No sockets, Keychain, UI, database/session models or logging.

## Ownership

- Framing owns directional byte caps; messages own strict wire decoding; crypto owns X25519, HKDF and AES-GCM; the connection state machine owns pairing order, one handshake, counters and pending replies.
- The caller serializes calls off the main thread, supplies the app static key and client lookup, coordinates pairing admission across connections, persists `.paired`, and drives the 120-second pairing timeout and connection cancellation. The request handler owns origin validation, offers, authorization and database policy.

## Invariants

- Wrong version, unknown type, missing and mistyped fields remain distinct decode errors. Ignore unknown extra fields; validate canonical padded base64 and fixed binary lengths. Decode successful replies with the original request operation (`BrowserBridgeJSON.decodeReply`) because the wire has no reply discriminator.
- Each direction requires exactly the next counter, beginning at zero; counters never wrap. Protocol errors send a plaintext error and close, clearing ephemeral state and session keys.
- Never log origins, titles, user names or secrets.
- Keep `../../../docs/browser-bridge-protocol.md` in the same commit as wire changes. Flag ambiguities for the protocol owner instead of silently changing the contract.

## Tests

- `BrowserBridgeProtocolTests` in `KeeForgeMacTests`: framing, strict decoding, pairing, handshake, rejection paths, authenticated counters and deterministic vectors. The client reference lives only in that test file.
- `../../../BrowserExtension/test/vectors.json` is bundled by `UnitTestFixtures`; regeneration instructions are in the test header. The extension tests consume the same file.

## See also

- `../AGENTS.md`, `../../../docs/browser-bridge-protocol.md`, `../../../KeeForgeTests/AGENTS.md`
