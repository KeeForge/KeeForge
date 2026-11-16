# Browser extension

Owns the Manifest V3 extension, browser-side protocol/crypto/storage, native port lifecycle, development mock, packaging and Node tests. Owns toolbar popup state and rendering, pairing-tab UI, all nine browser locales, chosen-frame probing, and isolated-world field selection/injection through the background API.

- Plain JavaScript ES modules and WebCrypto only; no packages, bundler or remote code.
- Permissions are closed: nativeMessaging, activeTab, scripting, storage. No host permissions, persistent content scripts or web-accessible resources.
- Origins come only from browser-authorized tab/frame inspection. Refuse opaque origins and insecure non-loopback HTTP.
- Credential lists exist only in the extension popup, never in a web page. The pairing page shows only pairing state and the comparison code. UI messages carry ids and browser targets, never credential values.
- Fill only the chosen frame after an in-frame origin re-check. The background derives origins independently of probe results, pins popup selection, and rechecks origin/document identity before injection. Use document-id targeting where available; older Firefox uses one frame id plus the in-frame origin check. Never submit a form.
- Never retain credentials after injection, cache matches across popup openings, or log site/vault/secret data. An injection adapter must target the inspected document and recheck its origin inside the fill function.
- Keep the client private key non-extractable in IndexedDB; close and discard session state on protocol errors. Serialize inbound and outbound crypto independently.
- Change docs/browser-bridge-protocol.md in the same commit whenever the wire contract changes.

Run `cd BrowserExtension && env -u NODE_USE_SYSTEM_CA node --test`; no dependencies or Xcode required. `tools/build.sh` produces deterministic Chrome/Firefox archives and unpacked copies under ignored `build/`.

Tests cover protocol/connection lifecycle and native framing, real Swift interoperability vectors (missing or incompatible fixtures fail), DOM-independent popup state/grouping/keyboard requests, frame selection, fake-DOM filling and native input events, browser labels, and locale completeness. Real Chrome/Firefox validation remains manual; follow README.md with the disposable mock host.
