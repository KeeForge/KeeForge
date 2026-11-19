# Browser Bridge Protocol

**Living document.** The wire contract between the KeeForge browser extension (`BrowserExtension/`), the native-messaging host, and the app's bridge; on macOS the host is `BrowserHost/` and the bridge is `KeeForge/Services/BrowserBridge/`. Change it in the same commit as any implementation. Protocol version: **1**.

Sections 1 to 8 are the shared contract and name no platform; every implementation keeps them. Section 9 says how macOS realises the transport requirements of sections 1, 2 and 4.

Design background: `docs/specs/2026-11-15-browser-extension.md`. Security boundary: `KeeForgeMac/SECURITY.md` (macOS) and `docs/threat-model.md`.

## 1. Parties and transport requirements

```text
extension  <-- native messaging (stdio) -->  host  <-- local channel -->  app bridge
```

The host is the native-messaging host the browser starts. The local channel is the connection between the host and the running app; a platform's transport section (section 9 for macOS) says what it is.

- **Frame:** a 4-byte unsigned length in little-endian order, then that many bytes of UTF-8 JSON (one object). The same framing is used on the browser's pipes and on the local channel.
- **Limits:** the JSON of a frame sent toward the app is at most 65,536 bytes; toward the extension, at most 1,048,576 bytes. The 4-byte length is not counted. A longer frame is a protocol error: the receiver closes the connection.
- **Local channel:** it admits only processes running as the same user as the app. The app checks each connection's peer and accepts at most a fixed number of connections at once.
- **Deadlines:** the app closes a connection that has not sent `hello` or `pair-commit` within 10 seconds of connecting, and one whose peer stops reading. The 10 seconds bind the extension, so they are the same on every platform; how a stalled peer is detected belongs to the transport.
- **Native host name:** `com.keevault.browser` on every platform, because the extension connects to the host by that name. The host's registration allows only the KeeForge extension: Firefox extension id `browser-extension@keeforge.com`; for Chromium-family browsers, the unpacked development key's ID until the Chrome Web Store assigns one (section 9 gives the macOS release status).
- The host forwards every frame unchanged, in both directions, except the host control frames in section 2. It never parses or logs any other frame.

Transport sections for other platforms, such as Windows, may be added beside section 9. A Safari Web Extension would relay the same frames through its native extension handler in place of the stdio host.

## 2. Host control frames

Frames whose `t` is `"host"` are exchanged between the extension and the host only. The host never forwards one to the app, and the app closes a connection that sends one.

| Direction | Frame | Meaning |
| --- | --- | --- |
| host → extension | `{"v":1,"t":"host","event":"connected"}` | The local channel is connected; the extension may send `hello` or `pair-commit`. Sent once per successful connect. |
| host → extension | `{"v":1,"t":"host","event":"unavailable","reason":"not-running"}` | No local channel, or nothing accepts on it. Also `"reason":"closed"` when a connected local channel closes. |
| extension → host | `{"v":1,"t":"host","cmd":"launch"}` | Drop the current local-channel connection if there is one, ask the operating system to open KeeForge (this also brings a running KeeForge forward), then retry the local channel for up to 10 seconds; answers `connected` or `unavailable`. |
| extension → host | `{"v":1,"t":"host","cmd":"connect"}` | Drop the current local-channel connection if there is one and try the local channel once now; answers `connected` or `unavailable`. |

On start the host tries the local channel once and sends `connected` or `unavailable`. It exits when stdin reaches end of file. After the local channel closes it stays alive and answers `launch` / `connect`.

## 3. Envelope

Every frame is an object with `"v": 1` and a type `"t"`. A receiver that sees another `v` answers `{"v":1,"t":"error","code":"unsupported-version"}` and closes. Unknown `t`, a missing field, or a field of the wrong type is `bad-request` and closes the connection. Unknown extra fields are ignored.

Plaintext error frame (app → extension): `{"v":1,"t":"error","code":"<code>"}` with code one of `unsupported-version`, `bad-request`, `unpaired`, `bad-handshake`, `pairing-declined`, `pairing-busy`, `disabled`.

Binary values are standard base64 with padding. Public keys are raw 32-byte X25519 keys.

## 4. Keys

- **Client static key `C`:** X25519, created by the extension per browser profile, private key non-extractable, kept in the extension's IndexedDB.
- **App static key `S`:** X25519, one per KeeForge installation, private key in the platform's protected secret storage, readable only by the app itself (not shared with its AutoFill extension), this device only (section 9 for macOS).
- **Client id:** lowercase hex of the first 16 bytes of `SHA-256(C_pub)` (32 characters).
- **Ephemeral keys `ec`, `es`:** fresh X25519 keys per connection, on each side.

## 5. Pairing

Pairing registers `C_pub` with the app after the user compares a six-digit code. It is a commit-then-reveal exchange, so neither side can choose its keys after seeing the other's. A same-user process that relays or impersonates the extension can still open its own pairings with the app, compute each one's code before revealing, and reveal only one that equals the code the extension shows; the app's pairing limits bound this to at most 5 code guesses a minute, each a one-in-a-million chance.

The app has one pairing slot. A `pair-commit` takes it before any `pair-key` is sent, and the attempt counts whether or not it is revealed. The app answers `error` `pairing-busy`, without a `pair-key`, while another pairing holds the slot, when 5 attempts have been admitted in the last 60 seconds, and for 10 seconds after a pairing that was declined, timed out, failed, or whose connection closed before the user answered. A committed pairing must reveal within 10 seconds or the app closes its connection and frees the slot.

1. extension → app: `{"v":1,"t":"pair-commit","commit":"<b64 SHA-256(C_pub || ec_pub || nonce)>","name":"<browser name, at most 64 characters>"}`. `nonce` is 32 random bytes. `||` is byte concatenation.
2. app → extension: `{"v":1,"t":"pair-key","pub":"<b64 S_pub>","eph":"<b64 es_pub>"}`, or `error` `pairing-busy` when the pairing slot or its limits refuse the attempt (above).
3. extension → app, within 10 seconds of the commit: `{"v":1,"t":"pair-reveal","pub":"<b64 C_pub>","eph":"<b64 ec_pub>","nonce":"<b64 nonce>"}`. The app recomputes the commitment; a mismatch is `bad-handshake`.
4. Both sides compute the code and show it: the extension in its pairing tab, the app in its alert. The app shows `name` as plain text, without control, format or bidirectional characters and with whitespace collapsed, and stores it the same way.
   `digest = SHA-256("KeeForge browser pairing v1" || C_pub || S_pub || ec_pub || es_pub)`; `code = (first 4 bytes of digest as a big-endian unsigned integer) mod 1000000`, shown as six digits with leading zeros.
5. app → extension, when the user answers: `{"v":1,"t":"pair-result","ok":true}` or `error` `pairing-declined`. A pairing the user has not answered within 120 seconds is declined. Closing the connection cancels it and dismisses the alert.
6. After `ok`, the app stores `{client id, C_pub, name, paired date}`. The extension stores `S_pub`. The extension then starts a session (section 6) on the same connection or a new one.

Pairing again with a known `C_pub` replaces that record after the same confirmation.

## 6. Session handshake

1. extension → app: `{"v":1,"t":"hello","client":"<client id>","eph":"<b64 ec_pub>"}`.
2. app → extension: `{"v":1,"t":"hello","eph":"<b64 es_pub>","app":"<app version>"}`, or `error` `unpaired` when the client id is not registered (including a browser removed while the handshake is in flight), or `error` `disabled` when the bridge is being turned off.
3. Both sides derive two keys:

   ```text
   ikm  = X25519(ec, es) || X25519(C, es) || X25519(ec, S)
   salt = SHA-256("KeeForge browser bridge v1" || ec_pub || es_pub || C_pub || S_pub)
   k_c2s = HKDF-SHA256(ikm, salt, info = "c2s", 32 bytes)
   k_s2c = HKDF-SHA256(ikm, salt, info = "s2c", 32 bytes)
   ```

   The extension computes `X25519(C, es)` with its static private key and `X25519(ec, S)` with the app's static public key; the app computes the mirror values. A side that does not hold the right static key derives different keys, so its first message fails to decrypt.

4. All later frames are `{"v":1,"t":"msg","n":<counter>,"c":"<b64 ciphertext || 16-byte tag>"}`: AES-256-GCM, key by direction, nonce = 4 zero bytes followed by the counter as an 8-byte big-endian integer, additional data = the ASCII bytes `msg`. Each direction's counter starts at 0 and increases by 1 per frame; the receiver requires exactly the next value. A wrong counter or a failed tag is `bad-handshake` and closes the connection. The plaintext is the UTF-8 JSON of one inner message.

A connection carries one session. A second `hello` on a connection is `bad-request`.

## 7. Inner messages

Requests come from the extension and carry an integer `id` chosen by it (0 to 2^53 - 1, not reused while a request with that id is unanswered); each gets exactly one reply with the same `id`. Replies are `{"id":n,"ok":true,...}` or `{"id":n,"ok":false,"error":"<code>"}`.

| Request | Fields | Successful reply |
| --- | --- | --- |
| `{"type":"status"}` | | `"app"`: version, `"unlocked"`: count of unlocked databases, `"locked"`: count of open but locked databases |
| `{"type":"matches"}` | `"origin"` | `"entries"`: array of `{"entry","db","dbName","title","username","hasTotp","exact"}`, `"locked"`: count of open but locked databases |
| `{"type":"credential"}` | `"entry"`, `"db"`, `"origin"`, optional `"totp": true` | without `"totp"`: `"username"` and `"password"`; with `"totp": true`: `"totp"` (the current code) only |
| `{"type":"reveal"}` | `"entry"`, `"db"` | none |
| `{"type":"unlock"}` | optional `"db"` | none |

- `origin` is a serialized web origin, as the browser serializes it: `https://host` or `https://host:port`, printable ASCII only (an internationalized host in punycode). `http://` is accepted only for `localhost`, `127.0.0.1` and `[::1]`. Anything else is `bad-origin`.
- `entry` and `db` are UUID strings. `username` is already resolved (field references included); `matches` never contains a password, a code, or any other field.
- `matches` allows a burst of 10 per connection, then 5 a second; more is `rate-limited`, whatever the origin. It returns the entries the app's site matcher offers for that origin from every database that is unlocked and has no lock pending, at most 50. `title`, `username` and `dbName` are cut to 256 characters, and rows are dropped from the end until the reply fits the frame limit; only the rows returned are offered. `"exact": true` marks an entry that lists this host itself; the others are possible matches on a related host of the same site, listed after the exact ones, and the extension shows them apart.
- The conformance fixtures in `../TestFixtures/browser-bridge/` (format in its README) pin the origin rules and `matches` behaviour above case by case; an implementation of the app side must pass them, and a change in that behaviour changes them in the same commit.
- `credential` is answered only for an `entry`/`db` pair that a `matches` reply on this connection returned for the same `origin`; otherwise `not-offered`. The app matches again (the entry must still be an exact or possible match for the origin) and checks the lock state again before answering. The reply can take as long as a device-owner prompt; the extension waits up to 120 seconds.
- The app releases a `credential` only inside the database's grace period (which a successful unlock or device-owner authentication starts) or after the user passes a device-owner prompt that names the entry's title and the origin's host (in punycode, without its port or a leading `www.`). On a device that cannot authenticate its owner, a request outside the grace period is `denied` without a prompt.
- A `credential` request with `"totp": true` asks for the code alone: its reply never contains `username` or `password`, and an entry without a code is `unavailable`. A request without `"totp"` is never answered with a code. The extension rejects a reply that carries the other kind's fields as `bad-request`.
- `reveal` fronts that database's window and selects the entry. `unlock` fronts the named database's locked window, or the Databases window. Together they allow a burst of 3 per connection, then one per second; more is `rate-limited`.

Error codes: `bad-request`, `bad-origin`, `locked` (no unlocked database, or that one locked since), `not-offered`, `no-match` (the entry no longer matches the site), `denied` (the device-owner check failed, was cancelled, or is unavailable outside the grace period), `unavailable` (the entry or database is gone, or a code-only request names an entry without a code), `rate-limited`.

## 8. Rules both sides keep

- Nothing is logged that names an origin, a title, a user name or a secret.
- The extension takes `origin` from the browser's own tab or frame data, never from page script.
- The extension keeps no credential after filling and caches no `matches` reply across openings of its popup or in-field menu.
- The app releases nothing while the bridge is switched off; switching it off closes every connection.

## 9. macOS transport

How the Mac app and its embedded host realise sections 1, 2 and 4. None of it changes what the extension sends or receives.

- **Local channel:** the Unix socket `b.sock` in the container of the app group `<TeamID>.com.keevault.browser`, mode 0600. The app accepts only peers whose effective user is its own (`getpeereid`), and at most 64 connections.
- **Stalled peers:** a write that waits 5 seconds, or too much work queued behind a stalled write, closes the connection.
- **Native host registration:** the host is `keeforge-browser-host` inside KeeForge.app at `Contents/MacOS/`; setting a browser up in Settings ▸ Browsers writes `com.keevault.browser.json` into that browser's per-user `NativeMessagingHosts` folder. Chromium-family browsers: only debug builds carry an extension ID (the unpacked development key's); release builds have none until the Chrome Web Store assigns one, so setting up a Chromium-family browser fails in a release build. This is an open release blocker for Chromium-family browsers.
- **App static key:** the private key is in the app's Keychain in the app's own access group (not the group shared with AutoFill), this device only.
- **`launch`:** the host asks LaunchServices to open KeeForge.
