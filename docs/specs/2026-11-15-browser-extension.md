# Browser extension

Date: 2026-11-15.
Issue: #299.
Status: implemented on the `browser-extension` branch and covered by unit tests
only; not yet verified in a signed build or a real browser. The current rules
live in `docs/browser-bridge-protocol.md`, `KeeForge/Services/BrowserBridge/AGENTS.md`,
`BrowserHost/AGENTS.md`, `BrowserExtension/AGENTS.md`, `KeeForgeMac/SECURITY.md`
("Browser bridge") and `docs/threat-model.md`; this document is not maintained.

## Goal

Fill logins into web pages in Chrome-family browsers and Firefox on the Mac from
the databases KeeForge already has open, without a second copy of the vault and
without unlocking anything in the browser. The user opens the extension's popup
on a login page, sees the logins that match the site, and picks one; KeeForge
asks for Touch ID or the Mac password, as Copy Password does, and the extension
fills the user name and password, or a verification code.

## Non-goals

- Passkeys. The bridge fills passwords and codes only; passkeys stay with the
  system AutoFill provider.
- Saving or updating logins from the browser. The bridge never writes a
  database.
- Safari. Safari's extensions use a different packaging and native-app model,
  and the system AutoFill provider already serves it.
- iPhone and iPad. Mobile browsers have no native messaging; AutoFill covers
  them.

## Architecture

```text
extension  <-- native messaging (stdio) -->  keeforge-browser-host  <-- Unix socket -->  KeeForge.app
```

- **The extension** (`BrowserExtension/`, Manifest V3, plain JavaScript, no
  packages) owns the popup, the pairing tab, frame selection and filling. It
  keeps a per-profile X25519 key pair, non-extractable, in IndexedDB.
- **The native-messaging host** (`BrowserHost/`) is a small tool embedded in the
  app at `Contents/MacOS/keeforge-browser-host` and started by the browser. It is
  sandboxed with only the browser App Group, relays complete frames between the
  browser's pipes and the socket, and can ask LaunchServices to open KeeForge. It
  understands nothing but its own launch and connect commands.
- **The bridge** in the app (`KeeForge/Services/BrowserBridge/`) listens on
  `b.sock` in the container of the team-prefixed App Group
  `<TeamID>.com.keevault.browser`, only while the user has turned it on. It
  decides everything: pairing, which logins a site is offered, and whether a
  password is released.

Why this shape:

- Native messaging is the only channel both browser families give an extension
  to a local program without a network listener. The browser starts that program
  itself, as its own child process, for each connection, so it cannot be the
  running app; a relay carries the frames to the app.
- The relay holds no keys and no logic, so a bug in it cannot release anything,
  and it can be sandboxed down to one App Group. A separate group, not the one
  AutoFill shares, keeps the relay away from vault caches.
- The Unix socket in a group container gives a filesystem path both sandboxed
  processes can reach, owner-only, with a same-user peer check, and no port any
  web page or other user can reach.
- The design copies the Mac SSH agent (`KeeForge/Services/SSHAgent/`): an opt-in
  local socket, served from the open sessions, re-checked against lock state on
  every request. Both now share `LocalSocketServer`.

## Decisions

- **Manifest installed through a user-granted folder.** The sandboxed app cannot
  write into other apps' Application Support folders. Settings ▸ Browsers asks
  the user to grant each browser's `NativeMessagingHosts` folder in an open panel,
  writes `com.keevault.browser.json` there, and keeps a security-scoped bookmark
  so it can repair the file later without asking.
- **Password fills follow the Copy Password rule.** Each credential takes the
  owning session's device-owner gate, including its grace period. The bridge adds
  no separate approval setting; a user who wants a prompt for every fill keeps the
  grace period at Always Ask, the default.
- **The app's site matcher is unchanged.** Matching uses the same exact and
  possible matches as AutoFill's interactive picker, so a login appears in the
  browser exactly where it would in AutoFill. Only databases that take part in
  AutoFill are offered.
- **No browser signature check.** The app does not verify the browser binary or
  the host's peer. Same-user code can already rewrite the native-messaging
  manifest or reach the socket, so a check would add complexity without a
  boundary. Pairing and the device-owner gate are the controls.
- **The extension lives in this repo,** so the protocol, its test vectors and both
  implementations change in one commit. The Swift tests write the vectors the
  Node tests read.
- **One app key pair per installation**, in the app's own Keychain access group,
  not the group AutoFill shares. Paired browsers are public keys in the app's own
  defaults.
- **Pairing in an extension tab, commit-then-reveal, with a compared code.** The
  popup closes when focus moves to KeeForge's alert, so pairing runs in a tab that
  stays open. The extension commits to its keys before seeing the app's, both
  sides show a six-digit code derived from all four public keys, and the user
  allows the pairing only when they match. One pairing slot, an attempt limit and
  a cooldown bound how often a relay can try to match the code.
- **Host name `com.keevault.browser`**, following the app's existing
  `com.keevault` identifiers rather than the product name.

## Alternatives considered

- **Unlocking in the browser, as some competitors do:** the extension would hold
  vault data or keys in the browser's process; rejected because it puts secrets
  where KeeForge's session encryption and lock handling do not reach.
- **A localhost HTTP or WebSocket server:** reachable by any web page and any
  local user's process through the network stack; rejected for a same-user Unix
  socket.
- **The KeePassXC-Browser protocol:** would reuse an existing extension but ties
  KeeForge to another project's protocol, trust model and release schedule, and
  its association has the user name the connection instead of comparing a code.

## Left for the owner

- Store listings for the Chrome Web Store and Firefox Add-ons, and the Chromium
  store extension ID, which goes into `BrowserBridgeIdentifiers.swift`. Until it
  is there, release builds refuse to set up Chromium browsers.
- Production toolbar icons for the extension.
- An end-to-end check on a signed, sandboxed build with real browsers: the host
  reaching the group container, the pairing alert coming forward over the
  browser, Touch ID on a fill, and the walkthrough in `BrowserExtension/README.md`.
