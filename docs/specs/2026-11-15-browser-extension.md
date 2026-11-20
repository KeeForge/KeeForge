# Browser extension

Date: 2026-11-15.
Issue: #299.
Status: implemented on the `browser-extension` branch and covered by unit tests
only; not yet verified in a signed build or a real browser. The current rules
live in `docs/browser-bridge-protocol.md`, `KeeForge/Services/BrowserBridge/AGENTS.md`,
`BrowserHost/AGENTS.md`, `BrowserExtension/AGENTS.md`, `KeeForgeMac/SECURITY.md`
("Browser bridge") and `docs/threat-model.md`; this document is not maintained.
The amendment of 18 November 2026 at the end replaces the popup-only filling
described below and records the real-browser checks done since.

## Goal

Fill logins into web pages in Chrome-family browsers and Firefox on the Mac from
the databases KeeForge already has open, without a second copy of the vault and
without unlocking anything in the browser. The user opens the extension's popup
on a login page, sees the logins that match the site, and picks one; KeeForge
asks for Touch ID or the Mac password, as Copy Password does, and the extension
fills the user name and password, or a verification code. (Amended 18 November
2026: the user now starts from a key button in the field; the popup remains.)

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
  packages) owns the popup, the pairing tab, frame selection and filling (and,
  since the amendment, the in-field key button and menu). It
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
  the user to grant each browser's `NativeMessagingHosts` folder (or the browser's
  own folder, used once to create it) in an open panel, writes
  `com.keevault.browser.json` there, and keeps a security-scoped bookmark of the
  `NativeMessagingHosts` folder only, so it can repair the file later without
  asking.
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
- Production toolbar icons for the extension. (Done; see the amendment.)
- An end-to-end check on a signed, sandboxed build with real browsers: the host
  reaching the group container, the pairing alert coming forward over the
  browser, Touch ID on a fill, and the walkthrough in `BrowserExtension/README.md`.

## Amendment, 18 November 2026: filling from the field

### Decision

The owner reversed the popup-only design. The extension now draws a key button
in login and verification-code fields, and a click on it opens a menu under the
field that lists the matching logins and fills one. The toolbar popup and its
shortcut remain.

Until this change the extension filled only from its toolbar popup. Its
permissions were `nativeMessaging`, `activeTab`, `scripting` and `storage`, with
no host permissions, no content scripts and no web-accessible resources, and
its rules said credential lists exist only in the popup, never in a web page
(`BrowserExtension/AGENTS.md` at the time; this spec described only the popup
flow).

### Why

In hands-on use the popup flow took too many steps: click the toolbar icon,
find the login, pick it. Filling from the field is what users of 1Password and
KeePassXC expect.

### What was given up

- **A closed permission set.** The extension now holds host access to every
  `https` page and to `http` on `localhost`, `127.0.0.1` and `[::1]`, and runs a
  persistent isolated-world content script in every such frame from
  `document_start`. `activeTab` stays, so the popup still works where the user
  limits site access to "on click" or, in Firefox, has not granted host
  access. A compromised
  extension can read and change all of those pages, not only the ones the user
  fills. Chrome shows the "read and change all your data on all websites"
  warning at install, and store review will ask for a justification.
- **No extension UI inside pages.** The menu is drawn inside the page, in an
  extension frame. The page cannot read it and the frame sends it nothing, but
  the page can see that the button's host element exists, remove or restyle it,
  find the buttons and the menu card by hit-testing, tell from focus when the
  menu opens and closes, and read what is filled.
- **Unframable extension pages.** The extension-pages CSP now allows `https`
  and loopback `frame-ancestors`, because the manifest policy covers every
  extension page and the menu would not load otherwise.
- **Clickjacking resistance that does not depend on the browser.** Chrome can
  detect an occluded or transparent menu; Firefox cannot, so there a fill takes
  a second click.
- **A user-name step without the password.** A lone e-mail or user-name step is
  decorated and receives only the user name, but the app still releases the
  whole login to the extension, because the protocol has no user-name-only
  request.

### What was kept

- The native app, the native-messaging host and the wire protocol are
  unchanged. The app still enforces that a credential was offered on the
  connection for that origin, matches the origin again, and takes the
  device-owner check.
- Origins still come only from the browser's own tab and frame data, never from
  the page.
- Filling still goes through the existing guarded path: the per-document pin
  and origin are checked again after the device-owner check and inside the fill,
  passwords go only into password fields, and no form is submitted.
- No credential or match list is kept after a fill or across openings, and
  nothing is logged.
- `popup.html` and `pair.html` stay out of the web-accessible list, so pages
  cannot frame or fetch them; `inline.html` is the only web-accessible file.

### Design of the key button and menu

- **Discovery is silent.** Before a trusted click on the button (or Option+Down
  in the field) the content script reads only field types, hints and layout and
  sends nothing to the background or the app. The button looks the same on
  every site, whatever the vault holds or whether the browser is paired, and
  uses the extension's own colours, never the field's. Its listeners register
  at `document_start`, before page script; a document without inputs gets no
  host, observer or timer. Sandboxed frames and frames smaller than 256×196 px
  get no buttons and are left to the popup.
- **One closed host.** All buttons live in one zero-sized element with a closed
  shadow root, a child of the document element or of the page's open modal
  dialog, popover or fullscreen element so the button works in the top layer;
  the page's fields are never wrapped, restyled or given attributes. Buttons
  are capped, and only open shadow roots are searched.
- **The menu is an extension frame.** A trusted click puts an iframe of the
  web-accessible `inline.html` inside the closed root. The menu lists matching
  logins, offers Unlock, Open KeeForge or Pair when needed, and refreshes itself
  while visible. It sends the page nothing: it is a fixed 320×264 px card
  (smaller only when the viewport is) and closes through the background to the
  recorded frame, so the page learns neither the extension's origin nor a
  handle to the frame. Chrome serves it with `use_dynamic_url`, so pages have
  no usable URL for it; a copy opened any other way has no token and does
  nothing.
- **Sessions come from the browser.** The background builds a menu session for
  the tab from the browser's sender data (tab, frame, document ID, origin) and
  its own inspection of the frame, with an unpredictable token and a new
  per-document pin, and replaces any earlier session in the tab. `matches` is
  asked only for that frame's own origin. Menu requests are accepted only from
  the extension's own `inline.html` in the same tab while the session is
  current. The first menu document owns the session; a call from another
  document, a second load of the menu frame, a fill, dismissal, navigation or
  opening the toolbar popup ends it. A cross-origin child frame
  gets its own buttons and is matched with its own origin.
- **Clickjacking delays.** Every control in the menu acts only on trusted
  events, after the menu has been fully visible without a break for 300 ms,
  300 ms after it opened and 300 ms after its rows last changed. In Chrome it
  also requires IntersectionObserver v2's `isVisible` (`trackVisibility`, delay
  100), so an overlay or opacity on the host or the page makes it refuse; it
  fails closed, so a site with full-viewport overlays can make it unusable. In
  Firefox, which has no visibility tracking, a fill needs a second click, at
  least 300 ms later, on a Fill button at a random horizontal offset in the
  row. The menu closes if it or its field moves more than 1 px (scrolling
  included), its host is restyled, or the viewport or URL changes; a page
  script move in the same animation frame as the click remains a theoretical
  gap.
- **Code fields get codes.** A verification-code field lists only logins with
  a code and fills the code alone.
- New artwork, a shared light and dark theme, and redesigned popup and pairing
  pages came with the change.

Checked in real headless Chrome 158 against the development mock host with
trusted input, and in Firefox 160 for the button and the menu frame only, not
the app. An adversarial review of this surface found no way to have a
credential requested for one origin and injected into another; its findings
(state leaking through frame messages, frame replacement, clickjacking by
moving the menu, an invisible button, a close a page could block, and tests
that passed with checks removed) were fixed on the same branch. The
current rules are in the documents listed at the top.
