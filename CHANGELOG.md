# Changelog

## macOS App (in development — ON HOLD, do not release until revisited)

Not part of any iOS release. The `KeeForgeMac` targets build and test green but the Mac app must not ship until the items below are done and the UX has been personally approved.

Done so far (2026-07-12 → 2026-07-15, spec: `docs/specs/2026-07-12-macos-port/`):
- Native macOS build target: full KDBX core, local vaults, unit suite (701 tests) running natively; App Sandbox + Hardened Runtime, provisioning verified.
- Menu bar commands, Settings window, automatic locking on screen lock/sleep/screensaver; Escape on the unlock screen returns to the database list.
- System-wide AutoFill extension (passwords + passkeys) embedded and signed — see TODO on Settings visibility.
- Screen-privacy protections (blur on focus loss, screen-capture blocking toggle), attachment Quick Look, review prompts, favicon cache kept out of the world-readable group container (`docs/macos-security-notes.md`).
- Dropbox/OneDrive OAuth implemented but hidden in the UI; WebDAV fully available.
- Native visual polish pass: three-column sidebar navigation, Mac toolbar, standard input fields, tightened density, window sizing.

TODO before the first macOS release:
- [ ] User verdict on the UX polish pass (daily-drive the app; after-screenshots reviewed).
- [ ] AutoFill provider not appearing in System Settings → AutoFill & Passwords despite correct registration/entitlements. Next rungs: reboot, distribution-signed build (comes with slice 07), diff against a known-working provider.
- [ ] Re-enable Dropbox/OneDrive UI after end-to-end validation on Mac (`TODO(macos-port)` in `CloudSyncModels.swift`); register/verify redirect URIs in the Dropbox and Azure consoles.
- [ ] Slice 07 — distribution (`07-distribution.md`): App Store Connect Mac platform + universal purchase, TestFlight, Developer ID certificate + provisioning profile for `com.keevault.app.autofill` (xcodebuild cannot auto-create DevID profiles), notarization, Sparkle (EdDSA key, appcast hosting), MAS/Developer ID build-config seam, tip-jar vs Sponsors swap, release-skill/docs updates.
- [ ] Manual QA: cloud sign-in end-to-end with relaunch token survival; AutoFill matrix (Safari/Chromium/native fill, webauthn.io passkeys, cancel-everywhere relock); reveal-auth prompt on a non-Touch-ID Mac; ⇧⌘4 capture-block behavior recorded on macOS 26.

## Unreleased

### New Features

- Change a database's master password: Database Details now has a "Change Master Key" screen for setting a new password and adding, replacing, or removing a key file — no need to export the database to a computer and use another KeePass app (#59). A backup under the old key is kept, and Face ID/Touch ID unlock keeps working without being set up again. Available on writable KDBX 4 databases once any pending edits are saved.

## v1.13.0 (2026-08-09)

### New Features

- Copy databases straight from a computer: KeeForge's Documents folder now appears in Finder (and iTunes/Windows File Sharing), and any `.kdbx` file dropped there is added to the database list automatically (#63). Replacing a file with a newer copy of the same name keeps the existing entry and its settings; deleting a file marks its entry so it can be removed with one tap — or restored by dropping the file back in.
- Choose an entry's icon: tap the icon on an entry to pick from the standard KeePass icon set or the custom icons already stored in the database. The choice is saved into the database itself, so it appears in other KeePass apps and on every synced device, and it can be undone from the entry's history.
- Download a website's icon: the icon chooser can fetch a site's favicon and store it in the database as a custom icon. The image is scaled down to a bounded size first, and the same icon used on several entries is stored only once.
- Create a new credential without leaving the signup page: the AutoFill picker now has a **+** button — and a "Create New Credential" button when it has nothing to show — that opens an entry form pre-filled with the site's name, address, and a generated password (#46). Saving stores the entry in the default AutoFill database and fills the form right away. iOS only, and only for writable databases.
- Closing a database with the Lock button is now animated instead of cutting away instantly: the open database fades back as the database list returns, and where locking lands on the unlock screen instead, that screen's padlock clicks shut as it arrives. Locking is not delayed to play it — automatic locks keep the instant cut.

### Fixes

- The Face ID / Touch ID prompt shown when revealing a password now appears in German, French, and Spanish; it was asking in English regardless of the app's language.
- The Custom Name field in Database Details now sits on one line next to its label, matching the other rows, instead of taking two lines.
- Website icons now load on networks that block QUIC traffic (UDP port 443), where every favicon download previously stalled for a minute and failed. Downloads no longer reuse the connection setup that insisted on QUIC, give up after a few seconds instead of sixty, and retry once over a plain TCP connection — the same route Safari takes on such networks. This affects both the opt-in list icons and "Download Website Icon" in the icon chooser.
- An edit made while a save was still uploading (for example to a cloud database on a slow connection) is no longer silently lost; the save now picks up the newer change and writes it too.
- The AutoFill picker no longer dead-ends on "No Credentials Found" for sites KeeForge cannot match: a new "Show All Credentials" action lists everything you can fill. The same action appears in the verification-code picker.
- AutoFill no longer dismisses with empty fields on passkey-capable sites: when a site supports passkeys, iOS asks KeeForge for a combined passkey-and-password list, and a vault with no matching passkey ended the request right after Face ID with no picker and nothing filled — even when matching password entries existed. The password list (or the empty-state picker with search and "Create New Credential") now appears instead.
- AutoFill no longer vanishes without filling anything when Face ID succeeds but the unlock finishes while the extension is still returning from the Face ID sheet. iOS silently discards a screen presented at that moment, which could leave a successfully unlocked request with no picker and no way to complete; the picker (and any post-unlock prompt) now waits for the extension to be back on screen and presents then.
- AutoFill now shows a clear error — naming both numbers and the way out — instead of silently doing nothing when a database's Argon2 memory setting is larger than the memory iOS gives the AutoFill extension (#57).
- Databases with high Argon2 iteration counts but modest memory now open: the fixed 1000-iteration ceiling is replaced with budgets based on actual cost, and oversized settings get a clear message instead of a generic parse error. The Argon2 version stored in the file is honored too, so Argon2 v1.0 databases unlock instead of reporting a wrong password (#74).

## v1.12.0 (2026-08-05)

### New Features

- Edit a group: long-press a group and choose "Edit Group" to rename it, give it tags, pick an icon, write notes, and hide or show it in Search & AutoFill — all in one form, saved together (#73). Tags on a group carry down to the entries inside it, so tagging a folder makes everything in it findable by that tag. The Recycle Bin and its contents stay uneditable, as does a read-only database; the existing "Change Icon" and "Hide from Search & AutoFill" shortcuts are still on the same menu. Note that giving a group its first tag upgrades the database file from KDBX 4.0 to 4.1 the next time it is saved, because group tags are a 4.1 feature: current KeePass, KeePassXC, KeePassium and Strongbox versions all read 4.1, but very old KeePass releases may not, and KeeForge never puts a database back to 4.0.
- Save new passkeys: choosing KeeForge when an app or website offers "Add Passkey" now creates a passkey entry in the default AutoFill database, stored in the KeePassXC-compatible format so other KeePass apps can sign in with it too. Previously that request showed a blank screen (#52).
- Search results and the tag browser now show which folder an entry lives in, as a small caption under the entry (#24).
- Groups hidden from AutoFill are now also hidden from in-app search, matching how KeePass treats the underlying "enable searching" flag (#24). Browsing and the tag browser still show the group and its entries, and the context-menu wording now says "Hide from Search & AutoFill".
- Entry details now show the tags an entry gets from the groups it sits in, next to its own tags and marked as coming from a group, so a tag-browser result is explainable from the entry itself (#72). Those inherited tags are not editable from the entry — they belong to the group, and are changed in the group editor above.
- French localization: the app, the AutoFill extension, and the README/contribution guide are now available in French.
- Spanish localization: the app, the AutoFill extension, and the README/contribution guide are now available in Spanish.

### Fixes

- Added the missing open-source acknowledgments for swift-psl and its bundled Public Suffix List data.
- Entry details now show inherited group tags as a single folder pill without a redundant caption, and custom-field separators use consistent insets.
- Automatic Face ID / Touch ID unlock no longer fails on the first try with "KeeForge couldn't finish the biometric unlock flow" (#60). The unlock ran while the app was still on its way to the foreground — where iOS refuses to show the biometric prompt at all — which spent the attempt on an error screen that a manual retry then cleared. It now waits for the app to be active, and a prompt that was never shown no longer counts as a failed unlock. Most visible on iPad, where the database stays on screen across an app switch.
- Choosing "Use Password" in the Face ID / Touch ID prompt now returns to the master password field instead of reporting an unexpected biometric error.
- OTP AutoFill identities now preserve each explicit web host, including meaningful subdomains, instead of collapsing entries to their registrable domain. Verification-code suggestions for an exact host now win over ones for a broader domain, so a code for `vt.example.com` fills straight away instead of asking which `example.com` entry was meant.
- The gear button inside an open database now opens the same settings screen as the database list's "Database Details". It had been missing the file format, size, encryption and key-derivation rows, the "Include in AutoFill" toggle, and the cloud account and sync status.
- The "Read-only" toggle in Database Details no longer offers to make a KDBX 3.1 database editable. KeeForge keeps that legacy format read-only, so turning the toggle off changed nothing; it is now disabled and says why.
- Edited entry titles and usernames now refresh immediately in entry lists, search results, and title sorting without reopening the database.
- Saving a OneDrive database could show a false "Save Conflict" alert (typically on the second save in a session), and OneDrive databases could re-download in full even though nothing changed remotely. OneDrive rewrites its revision tags on its own after an upload; saves now check the file's actual content before declaring a conflict, and quietly proceed when nothing really changed.
- Revealed passwords no longer show ambiguous hyphens that are not part of the stored password when a long value wraps onto another line.
- Protected custom fields are now masked in entry details and stored history versions. Revealing or copying one uses the same device-owner authentication gate as passwords.
- "Open iOS AutoFill Settings" was hidden exactly when it was needed — it only appeared once AutoFill was already on. If the one-tap prompt did not work, there was no way to reach the iOS setting from inside KeeForge. It is now always available.
- Tapping "Turn On AutoFill" and then declining the iOS prompt closed the whole Settings screen with the status still on "Off" and no word about what happened, which looks like the switch turning itself back off. KeeForge now keeps a note on the AutoFill screen explaining that the attempt did not turn it on, and pointing at the manual route. The screen also states that the per-database selections only take effect once KeeForge is enabled as a provider in iOS.
- "On" and "Off" in the AutoFill provider status were never translated.
- Invalid XML key files now show an error during database creation or unlock instead of continuing without that key-file component.
- Stored passwords now start concealed in the entry editor. Returning to unsaved work after an automatic or background lock also asks for device-owner authentication.
- AutoFill now uses its bundled public-suffix data when organizing website suggestions, improving handling for domains such as `com.pl` and hosted sites such as `github.io`.
- Unusual passkey data and extreme database timestamps are now handled gracefully instead of closing the app or AutoFill extension.

## v1.11.0 (2026-08-01)

### New Features

- Restore an entry's earlier version: open History, pick a version and restore it. The entry's current contents are kept as a new version so it can be undone — unless the database is set to keep no history, which the confirmation now says plainly.
- See an entry's earlier versions. KeePass keeps a copy of an entry each time it changes, and KeeForge has always preserved those copies — now you can open them: tap "History" on an entry to browse the stored versions and inspect one. Useful for checking what a password used to be.
- Added a tag browser: browse entries by tag (including tags inherited from groups), search by tag, and tag suggestions while editing.
- AutoFill now separates exact credentials from possible sibling-subdomain matches. Possible matches are never filled automatically; users can use one as-is or confirm adding the original request URL before saving it to the entry.
- Change a group's icon: long-press a group and choose "Change Icon" to pick from the standard KeePass icon set. If the group used a custom icon from the database, picking a standard one replaces it — a custom icon takes precedence over the standard one, so it has to go for the new choice to show. The Recycle Bin keeps its trash-can icon, and nothing is editable in a read-only database.
- Copy an entry's verification code to the clipboard when AutoFill fills its password, for sites whose one-time code field iOS does not recognize. Off by default; turn on "Copy Verification Code on AutoFill" under Settings › AutoFill. The copy clears itself after the Clipboard Clear Timeout and never leaves the device. While the setting is on, filling a suggestion for an entry that has a verification code asks you to confirm in KeeForge rather than filling silently, because AutoFill can only write the clipboard while its panel is on screen.

### Fixes

- Editing an entry in a database created by KeePass or KeePassXC could silently throw away its most recent stored versions. Once an entry reached the version limit, every save kept the oldest copies and discarded the newest — so the version from last week was lost while one from months ago survived. The two apps store the version list in opposite orders, and KeeForge assumed its own. It now decides what to keep by date. Databases created in KeeForge were never affected, and the order versions are stored in is left untouched, so files stay byte-friendly to other KeePass clients.
- The "Delete Entry" confirmation in the entry editor (and the "Remove Database" / "Discard pending upload" confirmations in the database list) could appear as a floating popover in the middle of the screen on modern iOS. These dialogs are now anchored to the control or row that triggered them.
- Permanently deleting an entry from the entry editor ("Delete Entry" → "Delete Permanently") left the app stuck on the editor screen until force-quit: deleting the entry tore down the navigation destination that had presented the editor, so nothing could pop it. The deletion itself was saved correctly. The editor now dismisses and returns to the group list, including when the entry was already in the recycle bin. ("Move to Recycle Bin" was unaffected.)
- On iPad, that same permanent delete also abruptly reset the whole workspace: the sidebar snapped back to the vault root mid-save and the editor vanished without animation. The detail screen's close was popping the sidebar's navigation stack (its own column had nothing to pop), and the editor was torn down before the save finished. Permanent delete now unwinds exactly like "Move to Recycle Bin": the editor pops after the save completes and the sidebar stays on the open group.
- KeeForge now preserves unknown KDBX4 inner-header fields when saving, protecting data written by future KeePass format extensions.
- AutoFill credential identity-store mutations are serialized within each process, and refreshes tolerate macOS system identity objects that omit the `recordIdentifier` Objective-C accessor instead of terminating the app after unlock.
- An unlock that finishes after cancellation can no longer repopulate or present UI for the old AutoFill request.
- Saving a cloud database from AutoFill wrote the shared cached copy twice; the redundant second write briefly widened the window in which a concurrent reader could see cache bytes that mismatch the pending-upload marker.
- A cloud download interrupted by the app terminating at exactly the wrong moment could leave a stray temporary file in the shared database cache forever. Cloud syncs now sweep out staging leftovers that have been parked for over an hour.
- Replaced the Apple-logo glyph used for standard icon 64 with a generic computer. Apple's SF Symbols license excludes the symbols depicting its own trademarks and logos, so it was not ours to ship — and the new group icon picker offers that index as a choice rather than only rendering it. Groups and entries already using icon 64 will show the new glyph on first open; the stored `IconID` is unchanged, so other KeePass clients are unaffected.
- Fixed a cloud save on a database with no recorded revision (databases added before revision tracking, or opened from the offline cache) being able to overwrite newer changes made on another device. Such saves now verify against the remote copy first and raise the usual conflict prompt.
- Two conflict copies created within the same minute produced the same filename, and the second replaced the first. Names now include seconds, and a cloud conflict copy can never overwrite an existing file.
- Pressing ⌘S repeatedly on macOS while a save was still running started a second save and could raise a spurious "changed in the cloud" prompt.
- Returning to KeeForge while a save or queued AutoFill upload was completing could roll back the recorded cloud revision, causing a false conflict on the next save.
- Refreshing the cached cloud copy now replaces it atomically, so the cached database cannot be lost if the app is interrupted mid-refresh.
- Fixed a rare data-loss bug where a credential saved through AutoFill could overwrite a save made in the app moments earlier on the same cloud database; such cases now surface as a resolvable conflict instead.
- AutoFill saves to cloud databases are now crash-safe end to end: the upload record is written before the database bytes, and every sync path that replaces the cached copy first preserves a timestamped backup of unsynced changes.
- Added a "Discard pending upload" action (with confirmation and automatic backup) to resolve stuck cloud upload conflicts from the database list.
- A cloud change saved from AutoFill while the app is syncing is no longer left permanently flagged as conflicted once its content has actually reached the cloud.
- Dropbox: fixed a crash that could occur when Dropbox was contacted from two places at once (e.g. opening a database while a pending AutoFill upload drained).
- Dropbox: disconnecting an account now always removes its saved sign-in token from the device, even when Dropbox had not been contacted since app launch.
- Dropbox: opening a database with no network now shows the offline notice and uses the cached copy instead of an internal error message.
- Dropbox: operations retry automatically when Dropbox is busy, and out-of-space, permission, and rejected-filename problems are reported in plain language instead of raw error text. Saves also no longer rebuild the connection and re-authorize before every request.
- OneDrive: a single rate-limit or server hiccup no longer fails a whole save, download, or file listing — transient failures retry with backoff, and an interrupted large upload resumes where the server left off instead of starting over.
- OneDrive: errors now explain themselves accurately — a permission problem, a full drive, or a busy service no longer all read as "reconnect this account", and a TLS failure is no longer reported as "no network connection".
- OneDrive: concurrent operations no longer race on token refresh, and a second sign-in can no longer interrupt one already in progress.
- Build/CI: App Store archives now fail the build when `ONEDRIVE_CLIENT_ID` is missing or still a placeholder, instead of shipping a dead OneDrive sign-in. The check was never wired up when OneDrive support was added; `ONEDRIVE_CLIENT_ID` remains optional for local development and simulator CI runs.
- Build/CI: the Dropbox CI placeholder key no longer produces an illegal `db-CI_PLACEHOLDER_DROPBOX_APP_KEY` URL scheme (App Store Connect ITMS-90158). The placeholder is now RFC1738-safe, archives fail the build when the real `DROPBOX_APP_KEY` is missing instead of shipping a placeholder, and a unit test validates every declared URL scheme.

### Changes

- Reworked the release process around a `release/{major}.{minor}` branch and the public TestFlight channel. Candidate builds are archived from `rc/{version}-b{build}` tags, soaked with external testers, and the exact soaked build is the one submitted to the App Store — `v{version}` now records what shipped instead of triggering a fresh archive. Adds per-build build numbers, measured-and-reported soak signals (48h for a minor release, 24h for a patch), release-branch backports as real merges into `main`, `release/**` PR gating and branch rules, and `ITSAppUsesNonExemptEncryption` in `Info.plist` so export compliance no longer prompts per build.

## v1.10.4 (2026-07-25)

### New Features

- Choose which databases appear in AutoFill, get suggestions from all of them at once, and clear AutoFill suggestions in Settings.
- Hide individual groups from AutoFill. Long-press a group and pick "Hide from AutoFill": its entries stop appearing in QuickType suggestions and in the AutoFill panel's search, while staying fully visible when browsing the database in the app. Subgroups follow their parent unless you turn one back on explicitly. The setting is stored in the standard KDBX `<EnableSearching>` group field, so it is shared with KeePass and KeePassXC instead of living in app-only state. Because the field is shared, a database where you had already set "exclude from search" on a group in KeePass will now have those entries hidden from AutoFill on first open — use "Show in AutoFill" on the group to get them back. Thanks to [@miquno](https://github.com/miquno) for the contribution.
- Switch between databases inside the AutoFill panel.

### Fixes

- Fix OneDrive databases stored in a folder or file whose name contains a space, `#`, `&`, or an accented character failing to open, download, or save. The path was being escaped twice on the way to OneDrive, so the app asked for a file that did not exist.
- Fix "Couldn't Save Database: the request is malformed or incorrect" on OneDrive saves that then succeeded when you tapped Retry Save. Ordinary saves now upload in a single request instead of going through OneDrive's large-file handshake, and when that handshake is still needed it retries briefly before giving up.
- Fix copied values disappearing from the clipboard before you could paste them. Copying a password and switching to another app locked the database on background and scrubbed the copy on the way out, so the paste arrived empty and the copy button looked broken. Backgrounding the app now leaves the copy alone; it still clears itself after the Clipboard Clear Timeout and never leaves the device. Locking the database yourself, and the auto-lock timeout firing while the app is open, both still clear the clipboard immediately. Thanks to [@miquno](https://github.com/miquno) for the contribution.
- Fix the AutoFill provider remaining on an empty view when an interactive request arrives after its presentation lifecycle callback. Thanks to [@ftorga](https://github.com/ftorga) for the contribution.

### Security

- App Transport Security now stays enforced for the app's own fixed hosts — favicons (DuckDuckGo), feedback, and the Dropbox/Microsoft cloud endpoints — via per-domain exceptions. The global arbitrary-loads allowance remains only for user-entered WebDAV servers, many of which still require legacy TLS ciphers that ATS otherwise rejects. Thanks to [@miquno](https://github.com/miquno) for the contribution.
- Saving a database now regenerates the file header's random material — master seed, encryption IV, inner stream key, and KDF salt — on every save, matching KeePass 2.x and KeePassXC. KDF cost settings (Argon2 iterations/memory/parallelism, AES-KDF rounds) are preserved, and saved files remain fully compatible with other KeePass clients. Thanks to [Kinglike1337](https://github.com/Kinglike1337) for the contribution.

### Changes

- Add an RFC 8439 known-answer vector for the inner-stream ChaCha20 cipher to the crypto test suite. Thanks to [@miquno](https://github.com/miquno) for the contribution.

## v1.10.3 (2026-07-18)

### New Features

- Database Details now shows file metadata read from the database's plaintext header without unlocking it: KDBX format version, file size, last-modified date, encryption algorithm, key-derivation settings (Argon2/AES-KDF parameters), and compression. Cloud databases report the locally cached copy.

### Security

- AutoFill no longer fills a credential without user selection unless the stored URL's host exactly matches or is a subdomain of the requested site; URL- and title-substring matches (e.g. `mybank.com` for a `bank.com` request) now only appear in the interactive picker, and the no-interaction fallback with several candidates defers to the picker instead of filling the first match.
- Passkey private keys are now re-encrypted in memory with the per-session key like passwords and TOTP secrets, and decrypted only at the moment of signing; locking the vault makes them unreadable instead of leaving the key as a plain string in memory.
- macOS: cloud-account records (provider account emails, WebDAV server/user strings) are now stored in the app's own sandbox defaults instead of the App Group container, which on macOS 14 is readable by the user's other non-sandboxed processes; a one-time migration scrubs any previously written value from the group container. iOS storage is unchanged.

### Fixes

- Raise the minimum supported iOS version to 18.0. On iOS 17 the app could wedge into an unresponsive state when opening the entry editor from an entry's detail screen: a SwiftUI `NavigationStack` bug on iOS 17 mishandled the nested navigation destination used to push the editor, spinning the main run loop so the editor never appeared. The issue is resolved on iOS 18 and later, so iOS 17 is no longer supported rather than shipping a build where entries cannot be edited. (macOS behavior, which presents the editor as a sheet, was unaffected.)
- Fix a crash when unlocking a database on a WebDAV server whose base URL path contains characters that need percent-encoding, such as mailbox.org's "Meine Dateien" folder: building the file URL mixed the decoded base path into a percent-encoded path and hit a Foundation fatal error on every unlock attempt. Local copies of the same database were unaffected.
- Fix a crash when opening a database containing an `otpauth://` entry with duplicate query parameter names (e.g. `secret` appearing twice, in any letter case); the first occurrence now wins, matching the KeeOTP parser.
- Fix a potential crash rendering TOTP codes for entries with a zero or negative period or an oversized digit count in their OTP settings; out-of-range values now fall back to the standard 30-second/6-digit defaults.
- Search is now diacritic-insensitive in both directions: searching "Café" finds entries stored as "cafe" and vice versa, matching how the search index was already folded.
- Show the correct icon for entries and groups: all 69 KeePass standard icons are now mapped to symbols (previously only 4 were, so most entries fell back to a generic key), and custom icons embedded in the database (`Meta/CustomIcons`) are now displayed for entries and groups. Custom icon XML continues to round-trip untouched on save.
- A search box containing only whitespace now shows the neutral search placeholder instead of a "No entries matched" message quoting the blank query.
- Locking a database on iOS now immediately clears a password copied via KeeForge from the clipboard (changeCount-guarded, so content copied elsewhere afterward is never touched) instead of leaving it until the clipboard timeout expires.
- Decrypted attachment-preview temp files left behind by a crash or force-quit are now purged at the next app launch instead of lingering until the next lock.
- Coordinated file reads and writes now surface a recoverable error instead of crashing if an unresponsive file provider returns without running the file accessor.
- Fix WebDAV connections to servers whose TLS configuration lacks App Transport Security's required forward-secrecy cipher suites (e.g. webdav.directbox.com, which offers only ECDHE CBC-SHA2 and plain-RSA/DHE AES-GCM ciphers): the app now allows the system to negotiate non-forward-secrecy TLS with user-specified servers, while WebDAV addresses remain HTTPS-only in code unless the user explicitly opts into HTTP. Also split the misleading "certificate is invalid" message so a TLS handshake failure now points at the server's outdated TLS settings, with separate messages for genuine certificate problems and unsupported client-certificate servers.
- Fix a cloud-sync data-loss risk where a credential saved through AutoFill (while another device had newer changes) could be silently lost. The queued upload now verifies its bytes against the saved snapshot before pushing, the shared cache is backed up before a sync-down overwrites it, and the drainer no longer force-pushes over a genuine cross-device conflict.
- Fix overlapping cloud upload drains (app foreground plus the AutoFill "enqueued" notification firing together) that could create duplicate cloud revisions or resurrect an already-completed upload; drains are now coalesced and serialized, and a dropped queue marker can no longer be recreated by a losing drain.
- Fix concurrent writes to the database list (a background cloud upload racing a rename/read-only/quick-launch edit) that could revert one change or manufacture a spurious "changed outside KeeForge" conflict; all list writes are now serialized. Cloud saves also write their local backup before uploading, and the staged conflict-download file now gets full data protection on iOS.
- Remove the UI-test cloud provider doubles from release builds. They previously shipped gated only by a launch argument, which on macOS let a local process substitute a fake sync provider against the real app; they are now compiled out of release entirely.
- Revealed passwords are no longer system-selectable, so copying always goes through KeeForge's expiring, local-only clipboard path instead of a system copy that bypassed auto-clear, Universal Clipboard exclusion, and clear-on-lock.
- Recognize passkeys created by Strongbox and older KeePassXC builds that use the legacy `KPEX_PASSKEY_GENERATED_USER_ID` / `KPXC_PASSKEY_USERNAME` field names, so those entries register for AutoFill and sign-in instead of appearing to have no passkey.
- Fix databases that lack a RecycleBinUUID element accumulating duplicated Meta XML (Generator, DatabaseName, CustomData, …) on every save, which compounded across edits and could confuse other KeePass clients.
- Fix the password generator letting every character-set toggle be switched off and then displaying a lowercase password while all toggles read "off"; the sheet now keeps at least one set enabled so the shown toggles match the generated password.
- Fix the Tip Jar: the StoreKit transaction listener now starts at launch so out-of-app completions (Ask to Buy, deferred payments) finish correctly, pending and failed purchases now surface feedback instead of nothing, and a transient product-load failure no longer wipes an already-loaded tip list.
- Fix WebDAV browsing of folders whose names contain a literal `%XX` sequence (previously shown as phantom self-nested folders), cap the response size accepted from a WebDAV server to prevent a memory-exhaustion denial of service, and accept pasted server addresses containing spaces or non-ASCII characters instead of rejecting them as malformed.
- Fix the cloud file browser flashing a spurious "cancelled" error and, with a slow server, showing stale results while typing in search.
- Make the Xcode Cloud CI test run reliable: the localization catalog tests now read the four raw `.xcstrings` catalogs from the test bundle (copied in verbatim by a build phase) instead of the source checkout, which is absent on Cloud's separate test machines; and several UI tests were hardened against Cloud's slower, four-way-parallel simulators (a shared longer element timeout, an unlock helper that retries a flaky first attempt, the attachment-row count asserted before the QuickLook preview interaction, and — under UI testing only — skipping the device-owner Face ID/passcode prompt on password reveal/copy so XCUITest isn't blocked by a system sheet it cannot dismiss on CI simulators that have a passcode enrolled). Test-only change gated behind the `-ui-testing` launch argument; production behavior is unaffected.
- Fix several test failures that only appear on the iPhone 15 Pro (iOS 17.5) and iPhone SE Xcode Cloud destinations: the one-time-code credential-identity unit tests now `XCTSkip` below iOS 18 (the `ASOneTimeCodeCredentialIdentity` API is iOS 18+) instead of failing; the shared text-entry helper scrolls a field clear of the software keyboard before typing so compact-device forms (iPhone SE) no longer drop keyboard focus; the password-generator test reveals the Regenerate/Use buttons that sit below the fold on small screens; and the database reorder-handle test matches the system reorder control's `Reorder` label prefix, which omits the row name on iOS 17.5. Test-only changes; production behavior is unaffected.

## v1.10.2 (2026-07-17)

### New Features

- Send Feedback now supports optional follow-up: enable "Allow Follow-Up" and enter an email so we can reply about that specific report. Nothing is sent unless you opt in.
- Send Feedback now supports attaching a single photo. Photos are downscaled and re-encoded as JPEG on-device (metadata such as location is stripped) and capped at 5 MB.
- Add a user-friendly What's New sheet that appears once per feature-bearing version on both iOS and macOS, with platform-specific feature filtering and release copy curated from the changelog's New Features section.
- Add full German localization (iOS app, macOS app, and AutoFill extension): 648 strings across UI, error messages, alerts, and Info.plist usage descriptions, plus a localization test suite that gates translation completeness, format-specifier parity, and app/extension consistency.
- Show TOTP codes for entries created by the KeeOTP/KeeOtp2 plugins (`key=...` values in the otp/OTP/Otp fields, with Base32, Base64, Hex, and UTF8 secret encodings, and KeeOtp2's defaults for omitted parameters), preserving the original field spelling and query verbatim when editing and saving.

### Fixes

- Fix AutoFill showing a blank sheet when picking KeeForge on a one-time-code field (#20): the extension never handled the interactive verification-code list request, so choosing AutoFill → Passwords on a TOTP form did nothing. It now unlocks the vault and fills the code directly when a single entry matches the site, or shows the TOTP entry picker otherwise; a stale QuickType code suggestion also falls back to the picker instead of failing.
- Fix local databases silently opening a stale copy after the file was deleted or replaced in the Files app (#13): iOS bookmarks follow the old file into Recently Deleted, so KeeForge now detects a trashed database file, refuses to open or save to it, and explains how to restore or re-add the current file.
- Fix local HTTP WebDAV vaults getting stuck on the initial metadata check before KeeForge could download and cache them.

### Security

- Password reveal and copy now always require device-owner authentication, even when biometrics are unavailable (hardening back-ported from the macOS work).

## v1.10.1 (2026-07-12)

### New Features
- Allow trusted local WebDAV servers to use unencrypted HTTP through an explicit Advanced connection toggle, while keeping HTTPS required by default and warning that credentials and database traffic will not be encrypted.
- Open Twofish-encrypted KDBX 4 databases and legacy KDBX 3.1 databases, preserving Twofish when saving editable vaults.
- Show a dismissible tip on the database list when KeeForge isn't enabled as an iOS AutoFill provider, with one-tap enablement on iOS 18 (deep link into iOS Settings on iOS 17), plus a matching provider status row and enable/open-settings button in Settings → AutoFill.

### Fixes
- Fixed the app freezing at launch or while opening a database when an offline SMB or other file-provider location does not respond.
- Refresh a revealed entry password immediately after the password is edited.
- Show red warning indicators in lists and a dedicated warning section in entry details when an enabled KeePass expiry time has passed, and show the enabled expiration timestamp in entry details.
- Exclude expired credentials from proactive and automatic AutoFill while keeping them available for explicit selection in the interactive picker.

## v1.10.0 (2026-07-05)

### New Features
- Sync databases over WebDAV (Nextcloud, Synology, and other WebDAV servers). Add a WebDAV server from Add Database or New Database by entering an https server address, username, and password (Nextcloud app passwords recommended), then browse and open or create databases in it.
- Show a read-only "Attachments" section on the entry detail screen, with QuickLook preview and share for each attachment; dangling references are shown disabled and marked unavailable. Preview/share uses short-lived, file-protected temp files that are cleaned up on dismiss and on database lock.
- Add a "Buy Me a Coffee" link to the Tip Jar section in Settings for supporting development outside the App Store.

### Changes
- Replace the Dropbox and OneDrive PNG icons with custom SF Symbol assets and render all cloud provider icons (including WebDAV) through one symbol pipeline, so their size, tint, and dark/light appearance match built-in icons in menus, labels, and rows across iPhone, iPad, and Mac.
- Parse `<Entry>/<Binary>` attachment references structurally into `KPEntry.attachments`, resolvable against the KDBX4 inner-header binary pool via the new read-only `BinaryPool` (name and pool ref preserved verbatim, including on history entries and dangling refs). The writer continues to re-emit the binary pool verbatim; no attachment editing yet.
- Add attachment test coverage: a deterministic `attachments.kdbx` KDBX4 fixture (non-ASCII filename plus an identical-bytes dedup pair), compatibility-matrix scenarios asserting attachment names and resolved pool SHA-256s survive edit round-trips, external `keepassxc-cli attachment-export` SHA-256 verification in the compatibility gate, and an `EntryAttachmentsSmokeUITests` UI smoke test for the attachments list and QuickLook preview.

## v1.9.4 (2026-07-02)

### Fixes
- Preserve the KDBX 4 minor version when saving existing databases instead of rewriting all KDBX 4 files as 4.0.
- Preserve unknown KDBX outer header fields when saving existing databases.

### Changes
- Add KDBX 4.1 fixture coverage for public custom-data outer header preservation.
- Cover recycle-bin permanent deletes in the KDBX compatibility matrix instead of live-object hard-delete scenarios that the app does not expose.

## v1.9.3 (2026-06-28)

### New Features
- Add a reveal toggle to the unlock master-password field.
- Add a Display setting for choosing System Default, Light, or Dark app appearance.
- Add group deletion from open databases, including recycle-bin moves and permanent deletion from inside the recycle bin.
- Show a thank-you tip jar state for returning supporters and move repeat tips into a compact menu.

### Fixes
- Improve database unlock failure reports with visible safe diagnostics.
- Move entries to the recycle bin from the long-press context menu instead of permanently deleting them.
- Write KDBX ChaCha20 databases with the raw ChaCha20 stream cipher expected by KeePass-compatible apps.

### Tests
- Add a KDBX compatibility matrix and external KeePassXC opener gate for database edit/save safety.

## v1.9.2 (2026-05-12)

### Fixes
- Fixed a bug where the OneDrive account could not be connected

## v1.9.1 (2026-05-10)

### New Features
- Add OneDrive support for signing in, browsing KDBX files, opening databases, and saving cloud-backed edits.

### Changes
- Add a Dropbox sign-in note explaining that the low-user-count OAuth warning is expected for an indie app.
- Remove the retired Dropbox write-scope upgrade reminder and always-on passkey feature flag.
- Replace the full-width cloud sync warning banner in unlocked databases with a compact toolbar warning icon that opens the detailed status message.

## v1.9.0 (2026-04-27)

### New Features
- Added support for creating new local KDBX 4.x databases from KeeForge.
- Added support for creating new KDBX 4.x databases directly in Dropbox folders.
- Show estimated password strength and entropy bits below visible password displays and the entry password editor.

### Changes
- Use shared monospaced password styling across entry detail, password generation, editing, unlock, and AutoFill credential creation screens.

### Fixes
- Remove the root lock/unlock transition animation and refresh empty groups immediately after creating their first entry.

## v1.8.3 (2026-04-24)

### New Features
- Add group creation from the unlocked database add menu, including duplicate-name validation.
- Split app settings into separate Security, AutoFill, Display, and About pages while keeping Tip Jar prominent on the main settings screen, and add a privacy toggle to hide last-opened usage stats from the locked database list

### Security
- Reduce in-app feedback uploads to the typed message plus visible error details, removing dedicated contact fields and automatic app/device metadata collection

### Changes
- Move Send Feedback to the main Settings page, place About at the bottom, and tighten database/app settings helper copy

### Fixes
- Keep password/key-file unlock failures visible during lockout backoff and restore the unlock error accessibility hooks used by UI tests
- Stabilize entry-creation UI coverage by validating new entries after a lock/reopen cycle and hardening list scrolling against stale simulator snapshots
- Let entry notes use native text selection handles so part of a note can be copied without copying the whole field.

## v1.8.2 (2026-04-20)

### New Features
- Add adaptive iPad layout support with a persistent sidebar, regular-width vault workspace, and a non-modal iPhone vault flow
- Add an in-app feedback form that can be opened from Settings and database-open failure screens without requiring GitHub or email

### Fixes
- Improve database-open failure handling by separating expected password/key-file errors from unexpected file, format, cloud, and biometric failures
- Add copyable sanitized error details and safer feedback payloads for database-open issues without including vault contents, passwords, key files, or raw database files
- Restore database list row sizing to match v1.8.1, including the selected-row highlight footprint on both iPhone and iPad layouts
- Respect the configured auto-lock timeout across app switching by making immediate background locking optional and applying elapsed timeout checks when returning from the background

## v1.8.1 (2026-04-16)

### New Features
- Add KDBX 3.1 read/open compatibility for password-only databases, including legacy AES-KDF headers, hashed block streams, and Salsa20 protected fields

### Fixes
- Toggling read-only in Database Settings now updates the current view immediately
- Fix unlocked vault displaying a wrapper "Root" group instead of showing database contents directly
- Fix read-only ribbon and unsaved-changes banner accessibility identifiers for UI test visibility
- Fix settings navigation from the unlocked database view (gear button → Database Settings → App Settings)
- Prevent adding the same local database file twice; opening an already-added file via Files/AirDrop now reliably opens the existing entry

### Changes
- Replace the yellow read-only banner with a lock icon in the navigation toolbar so the indicator stays visible across groups and entry details
- Unify Quick Launch and Read Only badge styling in the database list
- Use a check mark toggle for Quick Launch in the database context menu to match the Read-only toggle

## v1.8.0 (2026-04-12)

### New Features
- **Entry editing** — create, edit, and delete entries directly in the app with built-in password generation, autosave, save-conflict resolution, and read-only mode
- **AutoFill credential creation** — save new credentials and generate strong passwords directly from the AutoFill extension, with offline-safe queueing for Dropbox-backed databases
- **Database settings** — tap the settings button in the unlocked view to manage nickname, read-only mode, key file, metadata, and cloud sync

### Editing Details
- Changes autosave immediately — no manual save button; a progress overlay shows while the database is being written
- Full entry history is preserved on every edit, so previous passwords and fields can be reviewed
- Passwords are visible by default in the editor with a toggle to hide them
- Deleting an entry already in the Recycle Bin permanently erases it
- No data loss: unknown XML elements and third-party KeePass fields are preserved when saving
- Automatic timestamped backups before each save, with detection of external changes to prevent overwrites
- Saving works correctly for databases stored in Files folders like Downloads
- Dropbox-backed databases can be saved back to Dropbox with conflict detection
- Field labels stay visible while typing, and password styling is consistent across the app

### Fixes
- New entries from AutoFill are placed under the correct root group instead of a hidden internal group
- Recycle Bin is created under the correct root group
- Group entry counts update immediately after edits
- Dropbox icon renders correctly in dark mode
- Provider-specific cloud sync status shown during unlock
- Fixed Xcode Cloud CI bootstrap for clean machines

### Changes
- Improved AutoFill new-credential screen with labeled fields and toolbar buttons
- Saved AutoFill credentials queue in the shared App Group cache and are cleared on reinstall
- Simplified entry editor by removing custom fields and one-time password sections
- Added SwiftyDropbox to the Acknowledgments screen

## v1.7.0 (2026-04-05)

### New Features
- Add read-only Dropbox cloud sync with OAuth account linking, native cloud browsing, shared cached copies for AutoFill, and cloud status indicators in the database list and settings

### Fixes
- Simplify database list rows by using source icons instead of separate Dropbox and biometric badges, and fix oversized whitespace in Dropbox cloud-sync details

### Changes
- Split developer-specific build identifiers into a gitignored local xcconfig and move generated git metadata into a separate build-time config file
- Bootstrap a simulator-only local build config in GitHub Actions so CI no longer requires developer-specific identifiers

## v1.6.0 (2026-04-03)

### New Features
- Add a multi-database home screen that replaces the single-file launch screen with a database list, per-database unlock flow, add/remove/reorder actions, quick launch, nicknames, and key file association management
- Add migration from the legacy single-database bookmark/cache/keychain model to persisted per-database references with UUID-keyed shared cache files and lazy biometric key migration
- Support opening .kdbx files from other apps (Files, Mail, AirDrop, etc.) with UTType support for KeePassium, Strongbox, MiniKeePass, and more
- Add open source acknowledgments screen in Settings showing Argon2Swift and Argon2 license texts

### Fixes
- Improve privacy shield: show only app icon and name over blur instead of misleading "KeeForge Locked" text, trigger on background only (not inactive) to avoid flashing during Face ID or Control Center, and fix BiometricService auth-in-progress flag
- Fixed false "File unavailable" warnings for cloud-backed databases, restored the Add Database picker flow, and replaced the old unlock flash on launch with a dedicated opening screen
- Fixed multi-database file picker selections being dropped after dismissal before the chosen database or key file could be processed
- Fixed newly added databases failing to unlock with "The file couldn’t be opened because it doesn’t exist" by capturing bookmarks while document access is active and falling back to the cached copy when needed

### Changes
- Restyle the database unlock flow as a native sheet with plain system background instead of a full-screen page with blue gradient
- Update AutoFill to keep one active source database at a time by tracking the last successfully unlocked database across the app and extension
- Clarified quick launch behavior versus global Face ID auto-unlock, improved database detail/settings copy, and split Quick AutoFill into its own settings section
- Move Tip Jar above About in Settings
- Extract SecurityScopedBookmarkManager for cleaner bookmark handling
- Remove .kdb support from file type declarations, keep only .kdbx

## v1.5.1 (2026-03-31)

### New Features
- Add TOTP one-time code AutoFill support (iOS 18+) — verification codes from TOTP entries now appear in the QuickType bar alongside passwords and passkeys

### Fixes
- Fixed AutoFill credential lookup falling back to slow matching every time by parsing stable UUIDs from KDBX entry XML instead of generating random UUIDs on each parse
- Fixed AutoFill key icon flow showing all entries instead of filtering to the current site; replaced non-scrollable alert picker with scrollable search view and pre-filled domain search
- Fixed "KDF parameter out of range" error when opening databases created with KeePassXC 2.7.12+ that use high Argon2 iterations or parallelism values

### Changes
- Consolidated UI tests: merged 6 post-unlock test classes into a single `UnlockedDatabaseUITests` class with one unlock flow, reducing simulator + Argon2 overhead

## v1.5.0 (2026-03-10)

### New Features
- **Passkey AutoFill** — passkeys stored in KDBX (KeePassXC format) now appear in the iOS QuickType bar and AutoFill sheet. Tap to authenticate with Face ID, just like passwords. Works with any website that supports WebAuthn/FIDO2 passkey sign-in.
- Fixed Tip Jar product loading

### Fixes
- Fixed "Choose Different File" button not opening file picker
- Fixed Face ID auto-triggering immediately after manual lock
- Fixed AutoFill for cloud-hosted databases (Google Drive, OneDrive, Dropbox) by caching the selected `.kdbx` in the App Group shared container
- Fixed QuickType AutoFill identities being left stale after refreshing the shared database cache while unlocked
- Hidden credential ID from passkey detail view (shows relying party + username only)
- Fixed Google Drive `.kdbx` files being grayed out in the database picker by keeping a generic item fallback for cloud providers
- Show database picker validation failures as alerts on the unlock screen
- Listen for `Transaction.updates` at launch to ensure StoreKit transactions are always finished

## v1.4.1 (2026-03-09)

Rejected

## v1.4.0 (2026-03-08)

### New Features
- **Key file support** — unlock databases with password + key file (composite key). Supports all KeePass key file formats: binary, hex, XML v1.0 (`.key`), XML v2.0 (`.keyx`), and arbitrary files
- **Tip Jar** — three tip tiers via StoreKit 2 consumable IAPs in the About section
- **Feedback button** — links to GitHub Issues from the About section
- **Entry timestamps** — created and modified dates shown in entry detail view
- **Sort direction** — ascending/descending toggle for all sort orders

### Security
- Exponential backoff after failed password attempts (2s→4s→8s→16s→30s cap)
- Screen recording detection — blurs vault content when `UIScreen.isCaptured` is true
- QuickType AutoFill now enabled by default for new users

### Fixes
- Fixed backoff error message — now shows "Too many failed attempts. Try again in Xs." immediately instead of raw crypto error
- Sort direction toggle added to list view toolbar (was only in Settings)
- Fixed "Choose Different File" button not opening file picker (two `.fileImporter` modifiers on same view)
- Fixed Face ID auto-triggering immediately after manual lock
- Fixed cloud drive files (Google Drive, OneDrive, Dropbox) grayed out in document picker
- Fixed key file picker not opening (consolidated to single file importer)
- Fixed favicon provider label (Google → DuckDuckGo)
- Tip Jar shows "not available" instead of infinite spinner when products aren't configured
- Fixed demo.kdbx TOTP entries (bare base32 → proper `otpauth://` URIs)
- App Store screenshot test: reveals colored password + scrolls to show TOTP

### Known Issues
- AutoFill extension cannot access databases opened from cloud drives (Google Drive, OneDrive, Dropbox). Use local files for AutoFill.

## v1.3.0 (2026-03-03)

### New Features
- **QuickType AutoFill** — credential suggestions appear in the keyboard bar in Safari. Tap to autofill with Face ID, no full AutoFill popup needed. Toggle in Settings → Quick AutoFill.

### Fixes
- Fixed QuickType domain extraction — www-stripping, subdomain collapsing, multi-part TLD support (e.g. `login.facebook.com` → `facebook.com`, `bbc.co.uk` handled correctly)
- Fixed AutoFill Face ID timing — biometric now deferred until view is presented, resolving "User interaction required" error on QuickType tap
- Increased tap targets for view/copy/open URL buttons in entry detail (44pt minimum per Apple HIG)

### Security
- Hardened KDBX parser: `DataReader` now throws on truncated data instead of silently truncating
- Bounded Argon2 KDF parameters (iterations, memory, parallelism) to prevent resource exhaustion from malicious files
- Validated variant-map value lengths before decoding
- Passwords and TOTP secrets stored as AES-GCM `EncryptedValue` in memory (lazy decrypt on demand)
- Switched favicon provider from Google to DuckDuckGo (privacy)
- Private/internal domains filtered from favicon fetching

### Changes
- Renamed from KeeVault to KeeForge (display name, all internal references, folders, scheme, module name)
- License changed to GPLv3

## v1.2.0 (2026-02-26)

### New Features
- Opt-in website favicon support with disk cache (DuckDuckGo, SHA256 cache keys, 7-day TTL)
- "Download Website Favicons" toggle in Settings (off by default) with "Clear Favicon Cache" action
- Auto Face ID unlock on app open (opt-in setting in Security)
- Auto Face ID unlock in AutoFill extension (shared via App Group)
- Auto-lock inactivity timer (resets on user interaction, configurable in Settings)
- List sorting by title, created date, or modified date (persisted)
- Multiple URLs per entry via KP2A_URL custom fields (display + AutoFill matching)
- Exclude Recycle Bin from search, AutoFill, and group navigation

### Security
- Clipboard now uses `.localOnly` — passwords no longer sync via Universal Clipboard
- Constant-time HMAC/hash comparison (timing side-channel mitigation)
- Decompression bomb protection (256MB limit)
- Favicon cache written with `NSFileProtectionComplete`
- AutoFill extension clears parsed entries from memory after use
- Removed "Never" from clipboard clear timeout options
- Production logging gated behind `#if DEBUG`
- Negative block size validation in KDBX parser

### Fixes
- Fixed duplicate lock button in root view
- Fixed AutoFill subtitle missing in iOS Settings
- Fixed Face ID unlock not appearing on device (improved keychain existence check)
- Fixed keychain account key to use filename instead of full path
- Fixed 3 failing UI tests (navigation helpers now prefer non-empty groups)

### UI
- Renamed "Show Website Icons" → "Download Website Favicons"
- Renamed "Clipboard Timeout" → "Clipboard Clear Timeout"
- Renamed "Sort Order" → "Default Sort Order"
- Lock button in group list toolbar
- Removed debug state label from unlock screen
- Removed GitHub Repository link from Settings

### Infrastructure
- GitHub Actions CI workflow (build + unit tests)
- Auto-lock unit tests + enriched test fixture (7 entries, nested groups, unicode, edge cases)

## v1.1.0 (2026-02-22)

- Fixed inner stream decryption — passwords now display correctly
- Fixed TOTP parsing from `otp://` custom property
- Replaced vendored argon2 C code with Argon2Swift SPM package
- Fixed search — no longer dismisses on typing, works on all pages
- Fixed duplicate entries from History elements leaking into results
- Face ID required to reveal/copy passwords
- No lock shield flash during biometric authentication
- Fixed launch screen placeholder icon
- Resolved Xcode warnings (concurrency, deprecations)

## v1.0.0 (2026-02-17)

- KDBX 4.x read & decrypt
- Group/entry browsing with navigation
- Search across all entries
- TOTP display & copy
- Face ID database unlock
- AutoFill credential provider extension
- Initial App Store release
