# Browser extension core

Owns the Manifest V3 extension, browser-side protocol/crypto/storage, native port lifecycle, development mock, packaging and Node tests. UI and DOM fill integrate through the background API and its credential injection adapter.

- Plain JavaScript ES modules and WebCrypto only; no packages, bundler or remote code.
- Permissions are closed: nativeMessaging, activeTab, scripting, storage. No host permissions, persistent content scripts or web-accessible resources.
- Origins come only from browser-authorized tab/frame inspection. Refuse opaque origins and insecure non-loopback HTTP.
- Never retain credentials after injection, cache matches across popup openings, or log site/vault/secret data. An injection adapter must target the inspected document and recheck its origin inside the fill function.
- Keep the client private key non-extractable in IndexedDB; close and discard session state on protocol errors. Serialize inbound and outbound crypto independently.
- Change docs/browser-bridge-protocol.md in the same commit whenever the wire contract changes.

Run `cd BrowserExtension && node --test`; no dependencies or Xcode required. `tools/build.sh` produces deterministic Chrome/Firefox archives and unpacked copies under ignored `build/`.
