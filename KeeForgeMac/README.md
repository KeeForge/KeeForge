# KeeForgeMac Target

Native macOS app configuration and AppKit lifecycle sources. `App/` owns startup,
the app delegate, the window coordinator, menus, and Settings.

## Windows

`MacWindowCoordinator`, owned by `AppDelegate`, retains the Databases window
(`DatabasesWindowController`, identifier `databases`) and one
`DatabaseWindowController` per open database, keyed by the database UUID. That
UUID names both the session in `DatabaseSessionStore` and the window in
`MacDatabaseWindowRegistry`. Opening a database calls `sessionStore.open`
(creation uses `adopt`) and creates its window, or fronts and deminiaturizes the
one already open; opening another database never closes, locks or retires one
that is open. The app keeps running with no windows; Dock reopen shows the
Databases window when nothing is visible.

The coordinator turns `MacApplicationRouting` effects into window effects through
`MacWindowPresenting`, the seam unit tests replace: launch presentations first,
then queued URL and Quick Launch opens, duplicates fronting the open window. It
applies the capture policy to each window it creates before showing it, supplies
Quick Access with the database window the user last made key, and closes a
window whose session was retired elsewhere (removed from the list).

Window restoration: the coordinator is the only owner of top-level frames and
records the topology in `MacWindowRestorationStore` (the app's own defaults) as
windows open, close for good, move, finish resizing, minimize, change order, and as
the Databases window is shown or closed. A relaunch applies the plan once the launch
presentations are done (`MacApplicationRouting`'s `restoreWindows` effect, ahead of
queued and Quick Launch opens): each surviving database comes back locked in its
own window, registered as restoring so automatic Touch ID waits until the user
clicks or types in it or opens it explicitly, and the recorded frontmost is
fronted. Quick Launch runs only when nothing was restored and no file arrived. New
windows open at the default size, a second one cascaded from the frontmost; unit tests inject the store's defaults, screen
frames and the quit prompt. `-ui-testing` turns restoration and recording off, and
`-ui-testing-database-window-size <w>x<h>` sets the database window's content size
(`MacWindowLaunchOptions`).

The Databases window (about 600 x 620 pt, so the 540 x 560 pt sheets fit) hosts
`DatabaseListView`'s macOS branch with `MacDatabasesLauncherViewModel`: the
local, WebDAV and FTP references, double-click or Return to open, Create New,
Add Existing, Connect to Server, and the existing row management. It never shows
a database's contents. It also presents the transition notice and What's New,
once per launch, and asks which database a verification-code link belongs to
when no database window was targeted.

Each `DatabaseWindowController` owns its session for its whole life and never
looks one up through `activeSession`. Its window (identifier
`database.<UUID>`, no frame autosave, not restorable) hosts the
always-mounted `MacDatabaseRootView`: that session's unlock, opening, error and
unlocked content, its `MacBiometricAutoUnlockObserver`, and enrollment sheets
bound to this database. The window title is the database name in every state.

## Workspace presentation

Each database window owns one `MacWorkspacePresentation` and `MacWindowWorkspace`.
A `MacObservation` tracks the session's unlocked state and title, then
updates the native controller, toolbar, and window title. It re-arms on the main actor,
rejects queued callbacks after replacement/cancellation, and captures the window
controller weakly. A session lock drops the native controller; content revisions
and selection changes keep the same controller and hosting roots.

One outer `MacWorkspacePresentationHost` remains in `MacDatabaseWorkspaceView`,
around the native split representable, inside the always-mounted root host.
It owns workspace sheets, dialogs, alerts, banners, and the saving overlay.
Column revisions never replace it. It resets presentation state on workspace
disappearance and rejects old cloud reconnect completions. `MacDatabaseRootView`
keeps enrollment and its biometric observer mounted across lock/unlock. This
embedding avoids replacing the window's presentation hierarchy; no content swap
orders the window or assigns first responder.

`MacSidebarViewController` is the AppKit sidebar, built and unit-tested but not
yet installed in the split (the SwiftUI column still is). It renders
`MacSidebarSnapshot` in a source-list `NSOutlineView` (Library, Groups and Tags
headers; the Recycle Bin a top-level row) with the status card beneath. One
`MacObservation` rebuilds the snapshot and applies it per parent with insert,
remove and move on row objects cached by `MacSidebarItemID`, never a full reload,
so expansion and selection survive edits. Selection writes the workspace and
follows it back (unfolding ancestors); expansion is the presentation's
`collapsedGroupIDs`, kept for the window's life. Group-row menus come from
`MacSidebarGroupActions` and set the same presentation state the host presents.

The sidebar is collapsible (200–340 pt), the entries column is 260–460 pt, and
the detail takes the remaining width. `NSSplitView` autosave owns widths and
collapse state under `MacWindowRestorationStore.splitViewAutosaveName(for:)`, one
name per database, including across lock/unlock. View → Show Sidebar is forwarded
to the target window's native split controller.

## Commands and closing

`MacDatabaseCommandTargetResolver` picks the window a database command acts on:
the key database window (or the one a key sheet belongs to); with Settings or a
panel key, the main database window; with the Databases window key, or no
database window, none, so database commands are disabled. Validation and dispatch
both ask it when they run, through `AppDelegate.supplementalTarget` and each
controller's `isCommandTarget` gate. File ▸ New Database, Open Database and
Connect to Server are launcher operations and ignore every session's state.
Window ▸ Databases shows the Databases window, which AppKit's own window list
leaves out; that list names each open database window, adding the unlocked
window's subtitle in parentheses. Settings is an auxiliary window that cannot become main
and chooses its own database where it needs one.

Close Window, Close Database and Escape on the unlock screen all go through the
window's guarded close (`MacWindowCloseGuard`); Close Window is disabled while a
sheet is up, but Close Database still asks the guard, so an open editor answers
with its own prompt. A committed close locks and
retires exactly that session and releases its controller; cancel or a failed save
keeps both. Lock keeps the window open on its unlock screen.

Quit (`applicationShouldTerminate`, also on logout and restart) goes through
`MacWindowCoordinator.requestTermination`: with nothing unsaved it terminates at
once; otherwise it fronts each window with an unsaved write in turn, front first,
asks the close prompt, and writes only after every answer is in. Cancel, a failed
save, or a window whose editor still holds fields (fronted, for the user to
finish) cancels the quit and leaves every window and session as it was. A quit
that proceeds records the pre-quit topology, then freezes the record so the closes
that follow cannot shrink it.

## Toolbar and search

`MacWindowWorkspace` creates one `MacWorkspaceToolbar` per unlocked session,
beside the split controller, and drops it on lock or replacement. When it
exists, `DatabaseWindowController` turns the root host's `.toolbars` scene bridging
off and installs it as the window toolbar; on lock it removes it and turns
bridging back on for the unlock screen. One source owns the bar in each state.
Column hosts never bridge.

Each item's identifier is also its view's accessibility identifier. The
database-scoped items are navigational, so they
lead before the window title; Edit and the search field sit at the trailing
edge. Each item has a menu form for the overflow menu. The cloud sync controls
are the shared SwiftUI view in a hosting view; the others are AppKit controls.
Enablement comes from `DatabaseCommands` where a rule exists, and the whole bar
is disabled while saving.

The search field and `DatabaseViewModel.searchText` are bound both ways through
the toolbar's observation. Edit ▸ Find (`findEntry:`) calls
`MacWorkspaceToolbar.focusSearch()`, which begins the search item's interaction.
Title bridging is off; AppKit observation owns
the database title and group/tag/search subtitle. Column roots apply saving
disablement and appearance explicitly across hosting boundaries.

## Status

This file is reference material for working in the target: constraints, platform limits, and gotchas. macOS work follows the ordinary changelog flow under `## Unreleased`; release mechanics belong in the release skills, not here.

## SSH Agent

Settings ▸ SSH Agent turns on an agent that lets `ssh`, `git`, and other OpenSSH
clients sign in with private keys stored in an unlocked database (#163). The code
lives in `../KeeForge/Services/SSHAgent/`; the security boundary is in
[SECURITY.md](SECURITY.md#ssh-agent).

Setup:

1. Turn on Enable SSH Agent.
2. Click Copy SSH Configuration and paste it into `~/.ssh/config`. It points
   every host at `ssh-agent.sock` in the app's sandbox container. Copy the path from
   there rather than typing it: macOS may name the container folder after a UUID
   instead of `com.keevault.app`, as in this example:

   ```text
   Host *
     IdentityAgent "/Users/<you>/Library/Containers/ECC6B676-0D4E-46EE-9539-F33541F8924B/Data/ssh-agent.sock"
   ```

   Setting `SSH_AUTH_SOCK` to the same path works too.
3. Unlock the database and turn on each key under Keys. The choice is stored per
   database on this Mac only; it is not written into the database. While more
   than one database is unlocked, pick the one whose keys the list shows. The
   agent offers the chosen keys of every unlocked database at once.

Key entries: KeeForge looks at an entry's attachments. If the entry has a
`KeeAgent.settings` attachment (written by KeeAgent, KeePassXC, and Strongbox)
whose location is an attachment, that attachment is the key; otherwise the first
attachment that looks like a private key file is. The key must be an unencrypted
OpenSSH private key, the format `ssh-keygen` has written by default since OpenSSH
7.8: Ed25519, ECDSA P-256/P-384/P-521, or RSA. Passphrase-protected keys, PEM and
PKCS #8 files, and PuTTY `.ppk` files show as unsupported, and a key that KeePassXC
reads from a file outside the database is not offered. The agent uses the key's comment, or the entry title when the key has
none, as the comment `ssh-add -l` prints.

Verifying on a Mac, with one key turned on and the database unlocked:

```bash
SSH_AUTH_SOCK="<path from Copy SSH Configuration>" ssh-add -l
ssh -T git@github.com   # or any host that trusts the key
```

`ssh-add -l` lists the key with the fingerprint Settings shows. Lock the database and
both commands find no key; quit KeeForge or turn the agent off and they cannot reach
the agent at all.

## Build contracts

The app requires macOS 15. Source membership and AutoFill sharing rules belong
in [the shared-source guidance](../KeeForge/AGENTS.md). Both channels produce
`KeeForge.app`; all four product targets share the iOS marketing version and
build number. Mac unit tests run hosted in the app and compile the shared test
suite. Native window interactions belong in the Mac UI suite.

## Entitlements Gotchas

- App Sandbox + Hardened Runtime, user-selected read-write files, network client, app-scoped security bookmarks, App Group `group.com.keevault.shared`.
- `keychain-access-groups`: the app and the extension both list exactly one group, `com.keevault.sharedkeychain`. Ordering matters the moment a second one is added — items stored without an explicit `kSecAttrAccessGroup` land in the **first** listed group, so the shared group must stay first (see comments in both entitlements files). MSAL's macOS token cache group (`com.microsoft.identity.universalstorage`) is deliberately absent: the Mac app offers only WebDAV and FTP, so nothing authenticates through MSAL. Re-enabling OneDrive means adding it back *and* regenerating the Developer ID profiles, which embed the entitlements.

## Info.plist Sync

Keep `Info.plist` in sync with `KeeForge/Info.plist`, minus the cloud OAuth surface: the Mac app builds neither cloud SDK, so it declares no `db-*`/`msauth.*` URL scheme and none of the `DropboxAppKey`/`OneDriveClientID`/`OneDriveRedirectURI` keys (`URLSchemeFormatTests` pins the absence of the schemes). What must stay in sync: the `otpauth` scheme that routes incoming verification-code links into `TOTPEnrollmentDestinationView`, the ATS arbitrary-loads-plus-first-party-exceptions setup, and the kdbx document/UTType declarations.

## Security Posture

The [macOS security model](SECURITY.md) covers secrets, shared storage, lock behavior, platform limits, extension entitlements, and update trust. Keep it current when Mac-relevant security behavior changes. Release procedures live in [the direct-distribution release reference](../.agents/skills/prepare-release/references/direct-distribution.md).

## What Mac Work Has To Test

See "macOS tests" in `../AGENTS.md`, with the build and test commands. CI coverage is in `../.github/AGENTS.md`.

## Distribution Channels

One target, two channels, chosen when the project is generated rather than when it is built:

- `xcodegen generate` — **Mac App Store**: no Sparkle in the binary and StoreKit tip jar. Adding macOS to the existing App Store Connect app record established universal purchase with iOS; there is no separate toggle. This is the default, so every ordinary workflow and every CI job builds this.
- `xcodegen generate --spec project-direct.yml` — **Developer ID direct download**: links Sparkle, compiles `KEEFORGE_DIRECT_DOWNLOAD`, shows GitHub Sponsors instead of the tip jar, never calls StoreKit. It is also the only spec that selects `KeeForgeMacDirect.entitlements` and sets `SUEnableInstallerLauncherService` and `SUEnableAutomaticChecks` (daily checks from the first launch, switchable in Settings → About): a sandboxed app cannot submit Sparkle's installer job itself, and without the `-spks`/`-spki` mach-lookup exceptions an update downloads and verifies and then hangs forever at the progress window. Those two entitlement files must stay identical apart from that one key. `ci_scripts/build_mac_direct.sh` drives it and restores the App Store spec on exit.

Two specs rather than two targets: both channels ship an app named `KeeForge.app` (the executable name is inside the signature and cannot be renamed afterwards), and two targets producing the same product path is a hard Xcode error. Separate specs also make the channels mutually exclusive by construction — an App Store build must never contain an updater.

Read the channel at runtime through `DistributionChannel` only. `SUFeedURL` / `SUPublicEDKey` in `Info.plist` come from the `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` build settings and are empty in the App Store build, which ignores them.
