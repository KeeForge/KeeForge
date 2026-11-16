# KeeForge browser extension

Manifest V3, plain ES modules, no packages. Requires Chrome-family 133+ or Firefox 130+ (WebCrypto X25519). Run `env -u NODE_USE_SYSTEM_CA node --test` here; `tools/build.sh` reads the marketing version in `../project.yml` and writes deterministic `build/chrome.zip`, `build/firefox.zip` and unpacked directories. Python 3 and Node with WebCrypto X25519 are needed for development. The root `.gitignore` already ignores `build/` directories.

## Load for development

Run `tools/build.sh`. In Chrome enable Developer mode at `chrome://extensions`, choose Load unpacked, and select `build/chrome`. In Firefox open `about:debugging#/runtime/this-firefox`, choose Load Temporary Add-on and select `build/firefox/manifest.json`. The manifest intentionally has no development `key`; the store-assigned Chrome id is added to the native-host allowlist later. Unpacked ids can change with the extension path.

The same manifest is used in both archives. Chrome 121+ ignores `background.scripts` and runs `background.service_worker`; Firefox uses `background.scripts` as an event page. Both support `background.type: "module"` at our minimum versions (Chrome 92+, Firefox 112+). See [MDN background](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background) and [Mozilla compatibility data](https://github.com/mdn/browser-compat-data/blob/main/webextensions/manifest/background.json). [X25519 compatibility](https://github.com/mdn/browser-compat-data/blob/main/api/SubtleCrypto.json) sets the higher browser minimums. These are documentation checks; neither browser has been launched to validate loading, IndexedDB CryptoKey persistence or script injection.

## Manual native mock

`tools/mock-host.mjs` is a real stdio native-messaging host backed by `test/mock-app.js`. It does no network I/O and writes only framed protocol objects on stdout. It automatically allows pairing and serves disposable demo credentials. Options: `--decline`, `--busy`, `--pending`, `--locked`, `--empty`, `--mixed`, `--hold-credential`, `--unavailable` (a mock `launch` makes it available). App keys and registered clients last only for the host process; after it exits, pair again. To exercise persistent app pairing use the real host/app from the other items. Do not use the mock with real vault data.

No native-host manifest is installed by these tools. To set one up manually, create an executable wrapper with an absolute path to your Node binary and an absolute path to `tools/mock-host.mjs`, then point the browser's native-host registration at that wrapper. The host JSON is:

```json
{
  "name": "com.keevault.browser",
  "description": "KeeForge development mock",
  "path": "/absolute/path/to/mock-wrapper",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://YOUR_UNPACKED_CHROME_ID/"]
}
```

For Firefox replace `allowed_origins` with `"allowed_extensions": ["browser-extension@keeforge.com"]`. On macOS the per-user registration directories are `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` and `~/Library/Application Support/Mozilla/NativeMessagingHosts/`; use `com.keevault.browser.json`. Installing either is a manual developer action, not part of the build. The browser handles native framing for extension code; only the standalone mock handles stdio framing.

## UI and fill seams

Extension pages call `chrome.runtime.sendMessage({type, ...fields})`. Only this extension's own page URLs are accepted. Responses are plain objects; failures are `{ok:false,error:code}`. `getState` and `launchApp` return `{state,reason}`. States: `host-missing`, `app-unavailable`, `unpaired`, `pairing`, `ready`, `error`. `startPairing({name})` sends the detected browser label and returns `{code}` after reveal; poll `getState` for completion or decline/busy/timeout reason. At the connection layer it returns `{code,result}` with a completion promise. `getTarget()` probes the active tab and returns the inspected `{tabId,frameId,documentId,origin}`. `getMatches({tabId,frameId})`, `fill({tabId,frameId,entry,db,totp?})`, `reveal({entry,db})`, `unlock({db?})`, and `forgetPairing` round out the API. `frameId` defaults to 0. Matches are returned to the caller without any background cache. The app enforces that credential requests were offered on this connection.

Background starts without opening a native port. First use opens it; 60 seconds without active work closes it. Pairing and pending requests keep it busy until completion. Each request uses a fresh id; credential timeout is 120 seconds, all others 10 seconds. Timeout closes the session, avoiding acceptance of late replies. `hostCommand('connect')` retries an unavailable relay without launching the app. `launchApp` also fronts an already-running app; it uses a fresh connection without a prior hello before sending the host launch command.

`targetDocument` reads the tab through `tabs.get` and inspects the requested frame using `scripting.executeScript` in the default isolated world. `activeTab` access must have been granted by a user gesture; cross-origin subframes without that grant fail closed. No page-supplied or UI-supplied origin is used. Non-HTTP(S), non-loopback HTTP, and opaque documents are rejected. The target is checked again after authentication. Chrome provides `documentId`; Firefox did not add it until 153, so Firefox 130–152 needs frame-id targeting plus the in-frame origin check in the adapter. See [Mozilla injection compatibility](https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/scripting.json). UI fields never select a credential origin.

The entry point supplies the isolated-world `fillDocument` injection adapter. It targets the inspected document (using `documentId` where supported), verifies the expected origin again inside the injected function, and returns only completion. Code-only filling sends only the code into the chosen frame; login filling sends only user name and password. It neither retains the credential nor returns it to the popup. The core clears the reply object's fields even if the adapter throws, and `fill` returns only `{ok:true}`. Without an adapter, filling fails before requesting a credential. JavaScript strings and browser/GC internal copies cannot be securely zeroed; clearing references is the retention boundary.

`KeyStore` accepts storage with asynchronous `read()`, `write(record)`, `clear()`; production uses one atomic IndexedDB record and tests use structured-cloning memory storage. Both stored CryptoKeys are non-extractable. WebCrypto initially generates an exportable public half, so it is reimported non-extractable and its public bytes are stored alongside it for protocol messages. Forgetting clears the record and closes the session.

`test/vectors.test.js` reads the Swift-owned `test/vectors.json` directly. Missing or unrecognised vectors fail. It checks identity, commitment, pairing code, both derived keys, and the recorded plaintext/envelope pairs in both directions. Do not edit the fixture from JavaScript work.


## Popup and filling

Click the toolbar action or use Ctrl+Shift+L (Command+Shift+L on Mac). The shortcut only opens the popup. Browser or OS shortcut conflicts may require assigning it in the browser’s extension shortcut settings.

The background probes all accessible frames, choosing the focused frame when it contains a visible editable input, otherwise the top frame. An unfocused cross-origin child is never selected. `activeTab` may prevent even probing a cross-origin frame; inaccessible frames fail closed. The probe supplies no origin. The background derives it independently, pins the selected target during the popup session, and rechecks document and origin after a credential reply. The popup displays the serialized origin, including any port, and marks subframes. Only the chosen frame receives a credential, after a final in-frame origin check.

Firefox 130–152 has no script-injection `documentId`. On those versions the adapter targets exactly one `frameId`, with background origin checks before and after authentication and the in-frame origin check. This refuses cross-origin navigation but cannot distinguish same-origin document replacement; newer browsers additionally pin document identity. JavaScript strings and browser-internal message copies cannot be securely zeroed.

Exact matches precede a separate possible-match section. Multiple databases get separate headings within each section. Enter fills the first login, Up/Down selects a login, and Tab reaches code and reveal actions. A code action fills only a verification code. Waiting for a credential shows “Confirm in KeeForge”; the popup requests no close until filling succeeds. Browser-enforced popup dismissal when focus moves to another app remains outside extension control.

Pairing opens a separate tab, shows the browser label sent to KeeForge, and displays the comparison code until the app accepts or declines. Browser naming uses available brands, user agent and optional Brave detection; browsers hiding their identity (notably Arc and Vivaldi) may appear as Chrome. No extra permission is requested.

All nine locales ship under `_locales/`; zh-Hans maps to zh_CN and zh-Hant to zh_TW. Pages use external scripts/styles only, system fonts, light/dark colors, and a shipped SVG key glyph. Toolbar/extension PNG artwork is intentionally omitted; the owner should supply production icons. No deterministic SVG-to-PNG rasterizer is included in this dependency-free project.

## Owner browser walkthrough (not verified here)

Run this checklist in both real Chrome and Firefox with a manually registered `tools/mock-host.mjs` host. No browser was loaded during this work.

- [ ] Load both build outputs; check manifest/CSP errors, popup styling, key glyph, light/dark mode, 200% zoom, screen-reader names, focus visibility, and every locale.
- [ ] Before installing the host registration, open the popup: setup instructions appear with no ineffective setup button.
- [ ] Start the host with `--unavailable`: Open KeeForge reconnects; Pair with KeeForge opens a tab and closes the popup. Confirm browser label and a six-digit code, then success. The mock allows immediately, so the comparison-code screen may be brief.
- [ ] Re-register/restart with `--decline`, `--busy`, and `--pending`: verify declined, busy, and 120-second timeout reasons. A fresh mock process forgets clients; use the pairing tab directly or clear the extension’s development IndexedDB before each new mock process.
- [ ] On an HTTPS disposable form, click a login, then test Enter, Up/Down, Tab, code-only filling and Show in KeeForge. The mock supports `--mixed`, `--empty`, and `--locked` for grouping, no-logins, and Unlock in KeeForge states. Mock reveal/unlock only acknowledge; verify actual window selection with the real app later.
- [ ] With `--hold-credential`, verify “Confirm in KeeForge” remains while the request waits and eventually times out. With the real app, verify Touch ID success/cancellation and popup behavior when the OS moves focus.
- [ ] Try autocomplete hints, multiple forms, framework-controlled inputs, hidden/disabled/read-only/off-screen inputs, and code fallback to a focused input. Values update without form submission.
- [ ] Focus inputs in top, same-origin child, and cross-origin child frames; confirm displayed origin and selected frame. Cross-origin frames lacking activeTab access must fail closed. An unfocused child must never receive values.
- [ ] Navigate while a credential is pending, including a same-origin reload; confirm document-id browsers refuse replacement. Repeat on legacy Firefox and verify the documented same-origin limitation.
- [ ] Browser pages, file URLs, ordinary HTTP, and pages without editable fields show a one-line reason. Loopback HTTP remains allowed by the protocol.
- [ ] Assign/test the shortcut in each browser. It opens a visible popup and never fills on its own.

The mock uses disposable demo credentials only; do not point it at real databases. Real native-host installation, app-side policy, locked-database recovery, Touch ID, and hardware behavior require integration testing with the other browser-bridge items.

## Development ID

`manifest.json` carries a `key` so an unpacked copy always loads in Chromium browsers as `pihelgeaeflnpjjdajbdmfmcpgeoefbf`; debug builds of KeeForge allow that ID. Nobody holds the private half, so it cannot sign a package, and `tools/build.sh` removes the key from the store archives. Release builds of KeeForge allow only the store-assigned ID.
