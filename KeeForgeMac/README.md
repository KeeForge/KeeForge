# KeeForgeMac Target

Native macOS app configuration and AppKit lifecycle sources. `App/` owns startup,
the app delegate, the retained main window, menus, and Settings. The main window
keeps its `AppRootView` hosting controller mounted for the lifetime of the window.
Unlocked content embeds an AppKit `NSSplitViewController` with three independent
SwiftUI hosting controllers, and the window shows a native `NSToolbar` with an
`NSSearchToolbarItem`. Locked, opening, error, and list content use the
SwiftUI root and its bridged toolbar.

## Workspace presentation

`MainWindowController` owns one `MacWorkspacePresentation` and `MacWindowWorkspace`.
A `MacObservation` tracks the active unlocked session and database title, then
updates the native controller, toolbar, and window title. It re-arms on the main actor,
rejects queued callbacks after replacement/cancellation, and captures the window
controller weakly. A session lock drops the native controller; content revisions
and selection changes keep the same controller and hosting roots.

One outer `MacWorkspacePresentationHost` remains in `MacDatabaseWorkspaceView`,
around the native split representable, inside the always-mounted root host.
It owns workspace sheets, dialogs, alerts, banners, and the saving overlay.
Column revisions never replace it. It resets presentation state on workspace
disappearance and rejects old cloud reconnect completions. `AppRootView` keeps
launch presentations, enrollment, and its biometric observer mounted across
lock/unlock. This embedding avoids replacing the window's presentation hierarchy;
no content swap orders the window or assigns first responder.

The sidebar is collapsible (200–340 pt), the entries column is 260–460 pt, and
the detail takes the remaining width. `NSSplitView` autosave owns widths and
collapse state under `MacDatabaseWorkspace`, including across lock/unlock.
View → Show Sidebar is forwarded to the active native split controller.
The close guard settles unsaved work per registered database window, then locks
only its session. The app-owned registry follows the single main window's active
database and attributes activity from its sheets and children to that session.

## Toolbar and search

`MacWindowWorkspace` creates one `MacWorkspaceToolbar` per unlocked session,
beside the split controller, and drops it on lock or replacement. When it
exists, `MainWindowController` turns the root host's `.toolbars` scene bridging
off and installs it as the window toolbar; on lock it removes it and turns
bridging back on, so the list screen's Add Database and Settings items come back
from SwiftUI. One source owns the bar in each state. Column hosts never bridge.

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
   database on this Mac only; it is not written into the database.

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
