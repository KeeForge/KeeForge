# KeeForge browser extension core

Manifest V3, plain ES modules, no packages. Requires Chrome-family 133+ or Firefox 130+ (WebCrypto X25519). Run `node --test` here; `tools/build.sh` reads the marketing version in `../project.yml` and writes deterministic `build/chrome.zip`, `build/firefox.zip` and unpacked directories. Python 3 and Node with WebCrypto X25519 are needed for development. The root `.gitignore` already ignores `build/` directories.

## Load for development

Run `tools/build.sh`. In Chrome enable Developer mode at `chrome://extensions`, choose Load unpacked, and select `build/chrome`. In Firefox open `about:debugging#/runtime/this-firefox`, choose Load Temporary Add-on and select `build/firefox/manifest.json`. This item has no popup, pairing page, or fill function yet. Those enter through the API below. The manifest intentionally has no development `key`; the store-assigned Chrome id is added to the native-host allowlist later. Unpacked ids can change with the extension path.

The same manifest is used in both archives. Chrome 121+ ignores `background.scripts` and runs `background.service_worker`; Firefox uses `background.scripts` as an event page. Both support `background.type: "module"` at our minimum versions (Chrome 92+, Firefox 112+). See [MDN background](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background) and [Mozilla compatibility data](https://github.com/mdn/browser-compat-data/blob/main/webextensions/manifest/background.json). [X25519 compatibility](https://github.com/mdn/browser-compat-data/blob/main/api/SubtleCrypto.json) sets the higher browser minimums. These are documentation checks; neither browser has been launched to validate loading, IndexedDB CryptoKey persistence or script injection.

## Manual native mock

`tools/mock-host.mjs` is a real stdio native-messaging host backed by `test/mock-app.js`. It does no network I/O and writes only framed protocol objects on stdout. It automatically allows pairing and serves disposable demo credentials. Options: `--decline`, `--busy`, `--unavailable` (a mock `launch` makes it available). App keys and registered clients last only for the host process; after it exits, pair again. To exercise persistent app pairing use the real host/app from the other items. Do not use the mock with real vault data.

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

Extension pages call `chrome.runtime.sendMessage({type, ...fields})`. Only this extension's own page URLs are accepted. Responses are plain objects; failures are `{ok:false,error:code}`. `getState` and `launchApp` return `{state,reason}`. States: `host-missing`, `app-unavailable`, `unpaired`, `pairing`, `ready`, `error`. `startPairing` returns `{code}` after reveal; poll `getState` for completion or decline/busy/timeout reason. At the connection layer it returns `{code,result}` with a completion promise. `getMatches({tabId,frameId})`, `fill({tabId,frameId,entry,db,totp?})`, `reveal({entry,db})`, `unlock({db?})`, and `forgetPairing` round out the API. `frameId` defaults to 0. Matches are returned to the caller without any background cache. The app enforces that credential requests were offered on this connection.

Background starts without opening a native port. First use opens it; 60 seconds without active work closes it. Pairing and pending requests keep it busy until completion. Each request uses a fresh id; credential timeout is 120 seconds, all others 10 seconds. Timeout closes the session, avoiding acceptance of late replies. `hostCommand('connect')` retries an unavailable relay without launching the app.

`targetDocument` reads the tab through `tabs.get` and inspects the requested frame using `scripting.executeScript` in the default isolated world. `activeTab` access must have been granted by a user gesture; cross-origin subframes without that grant fail closed. No page-supplied or UI-supplied origin is used. Non-HTTP(S), non-loopback HTTP, and opaque documents are rejected. The target is checked again after authentication. Chrome provides `documentId`; Firefox did not add it until 153, so Firefox 130–152 needs frame-id targeting plus the in-frame origin check in the adapter. See [Mozilla injection compatibility](https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/scripting.json). UI fields never select a credential origin.

The next item replaces the entry point’s `new Background()` with `new Background({injectCredential: async (target, credential) => ...})`. The adapter must inject into the inspected document (using `documentId` where supported), verify the expected origin again inside the injected function, and return only completion. It must neither retain the credential nor return it to the popup. The core clears the reply object's fields even if the adapter throws, and `fill` returns only `{ok:true}`. Without an adapter, filling fails before requesting a credential. JavaScript strings and browser/GC internal copies cannot be securely zeroed; clearing references is the retention boundary.

`KeyStore` accepts storage with asynchronous `read()`, `write(record)`, `clear()`; production uses one atomic IndexedDB record and tests use structured-cloning memory storage. Both stored CryptoKeys are non-extractable. WebCrypto initially generates an exportable public half, so it is reimported non-extractable and its public bytes are stored alongside it for protocol messages. Forgetting clears the record and closes the session.

`test/vectors.test.js` documents its assumed Swift-vector JSON schema at the top. It skips explicitly only if `test/vectors.json` is absent; a present but incompatible file fails and must be reconciled with the Swift worker.
