# Browser Bridge Protocol

**Living document.** The wire contract between the KeeForge browser extension (`BrowserExtension/`), the native-messaging host (`BrowserHost/`), and the Mac app's bridge (`KeeForge/Services/BrowserBridge/`). Change it in the same commit as either implementation. Protocol version: **1**.

Design background: `docs/specs/2026-11-15-browser-extension.md`. Security boundary: `KeeForgeMac/SECURITY.md` and `docs/threat-model.md`.

## 1. Parties and transport

```text
extension  <-- native messaging (stdio) -->  host  <-- Unix socket -->  Mac app bridge
```

- **Frame:** a 4-byte unsigned length in little-endian order, then that many bytes of UTF-8 JSON (one object). The same framing is used on the browser's pipes and on the socket.
- **Limits:** the JSON of a frame sent toward the app is at most 65,536 bytes; toward the extension, at most 1,048,576 bytes. The 4-byte length is not counted. A longer frame is a protocol error: the receiver closes the connection.
- **Socket:** `b.sock` in the container of the app group `<TeamID>.com.keevault.browser`, mode 0600. The app accepts only peers whose effective user is its own (`getpeereid`), and at most 64 connections.
- **Deadlines:** the app closes a connection that has not sent `hello` or `pair-commit` within 10 seconds of connecting, and one whose peer stops reading: a write that waits 5 seconds, or too much work queued behind a stalled write, closes it.
- **Native host name:** `com.keevault.browser`. Firefox extension id: `browser-extension@keeforge.com`.
- The host forwards every frame unchanged, in both directions, except the host control frames in section 2. It never parses or logs any other frame.

## 2. Host control frames

Frames whose `t` is `"host"` are exchanged between the extension and the host only. The host never forwards one to the app, and the app closes a connection that sends one.

| Direction | Frame | Meaning |
| --- | --- | --- |
| host → extension | `{"v":1,"t":"host","event":"connected"}` | The socket is connected; the extension may send `hello` or `pair-commit`. Sent once per successful connect. |
| host → extension | `{"v":1,"t":"host","event":"unavailable","reason":"not-running"}` | No socket, or nothing accepts on it. Also `"reason":"closed"` when a connected socket closes. |
| extension → host | `{"v":1,"t":"host","cmd":"launch"}` | Drop the current socket connection if there is one, ask LaunchServices to open KeeForge (this also brings a running KeeForge forward), then retry the socket for up to 10 seconds; answers `connected` or `unavailable`. |
| extension → host | `{"v":1,"t":"host","cmd":"connect"}` | Drop the current socket connection if there is one and try the socket once now; answers `connected` or `unavailable`. |

On start the host tries the socket once and sends `connected` or `unavailable`. It exits when stdin reaches end of file. After the socket closes it stays alive and answers `launch` / `connect`.

## 3. Envelope

Every frame is an object with `"v": 1` and a type `"t"`. A receiver that sees another `v` answers `{"v":1,"t":"error","code":"unsupported-version"}` and closes. Unknown `t`, a missing field, or a field of the wrong type is `bad-request` and closes the connection. Unknown extra fields are ignored.

Plaintext error frame (app → extension): `{"v":1,"t":"error","code":"<code>"}` with code one of `unsupported-version`, `bad-request`, `unpaired`, `bad-handshake`, `pairing-declined`, `pairing-busy`, `disabled`.

Binary values are standard base64 with padding. Public keys are raw 32-byte X25519 keys.

## 4. Keys

- **Client static key `C`:** X25519, created by the extension per browser profile, private key non-extractable, kept in the extension's IndexedDB.
- **App static key `S`:** X25519, one per KeeForge installation, private key in the app's Keychain in the app's own access group (not the group shared with AutoFill), this device only.
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
| `{"type":"credential"}` | `"entry"`, `"db"`, `"origin"`, optional `"totp": true` | `"username"`, `"password"`, and `"totp"` (current code) when asked and the entry has one |
| `{"type":"reveal"}` | `"entry"`, `"db"` | none |
| `{"type":"unlock"}` | optional `"db"` | none |

- `origin` is a serialized web origin: `https://host` or `https://host:port`. `http://` is accepted only for `localhost`, `127.0.0.1` and `[::1]`. Anything else is `bad-origin`.
- `entry` and `db` are UUID strings. `username` is already resolved (field references included); `matches` never contains a password, a code, or any other field.
- `matches` returns the entries the app's site matcher offers for that origin from every database that is unlocked and has no lock pending, at most 50. `title`, `username` and `dbName` are cut to 256 characters, and rows are dropped from the end until the reply fits the frame limit; only the rows returned are offered. `"exact": true` marks an entry that lists this host itself; the others are possible matches on a related host of the same site, listed after the exact ones, and the extension shows them apart.
- `credential` is answered only for an `entry`/`db` pair that a `matches` reply on this connection returned for the same `origin`; otherwise `not-offered`. The app matches again (the entry must still be an exact or possible match for the origin) and checks the lock state again before answering. The reply can take as long as a device-owner prompt; the extension waits up to 120 seconds.
- `reveal` fronts that database's window and selects the entry. `unlock` fronts the named database's locked window, or the Databases window. Together they allow a burst of 3 per connection, then one per second; more is `rate-limited`.

Error codes: `bad-request`, `bad-origin`, `locked` (no unlocked database, or that one locked since), `not-offered`, `no-match` (the entry no longer matches the site), `denied` (the device-owner check failed or was cancelled), `unavailable` (the entry or database is gone), `rate-limited`.

## 8. Rules both sides keep

- Nothing is logged that names an origin, a title, a user name or a secret.
- The extension takes `origin` from the browser's own tab or frame data, never from page script.
- The extension keeps no credential after filling and caches no `matches` reply across popup openings.
- The app releases nothing while the bridge is switched off; switching it off closes every connection.
