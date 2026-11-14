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
window whose session was retired elsewhere (removed from the list). Remove in
the Databases window is refused, with an alert, while that database's session has
unsaved work or a write in flight.

Window restoration: the coordinator is the only owner of top-level frames and
records the topology in `MacWindowRestorationStore` (the app's own defaults) as
windows open, close for good, move, finish resizing, minimize, change order, and as
the Databases window is shown or closed. A relaunch applies the plan once the launch
presentations are done (`MacApplicationRouting`'s `restoreWindows` effect, ahead of
queued and Quick Launch opens): each surviving database comes back locked in its
own window, registered as restoring so automatic Touch ID waits until the user
clicks or types in it or opens it explicitly; that first interaction posts
`MacBiometricAutoUnlockController.restorationEndedNotification`, which asks for the
attempt even in an already-key window. The recorded frontmost is fronted. Quick Launch runs only when nothing was restored and no file arrived. New
windows open at the default size, a second one cascaded from the frontmost; unit tests inject the store's defaults, screen
frames and the quit prompt. `-ui-testing` turns restoration and recording off, and
`-ui-testing-database-window-size <w>x<h>` sets the database window's content size
(`MacWindowLaunchOptions`).

The Databases window (780 x 620 pt, title hidden, full-size content so the
brand panel runs under the traffic lights; tall enough for a 560 pt sheet) is
`MacDatabasesLauncherViewController` inside a SwiftUI host that presents its
sheets and confirmations. The brand panel shows the app icon, name and version
and sends New Database…, Open Database File… and Connect to Server… (captioned
with the server types) to the same nil-targeted commands as the File menu. The
list renders `MacDatabasesLauncherViewModel.rows` (local, WebDAV and FTP only)
in an inset `NSTableView`: storage tile, name, "file · storage", a problem or
last-opened line, and Quick Launch, Read-Only, Open (window unlocked) or the
lock, and Touch ID. Return and double-click open or front the selected row;
the row menu holds Open and the management items; the bottom bar's + offers
the three add commands and − removes the selection. With nothing listed the
list area shows the empty state alone. It never shows a database's contents.
The host keeps the creation, server and Database Details sheets, rename, key
file, export, the remove confirmation and refusal, and the pending-upload
alerts in SwiftUI, driven by state on the view model. It also presents the
transition notice and What's New, once per launch, and asks which database a
verification-code link belongs to when no database window was targeted.

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
It owns workspace sheets, dialogs, SwiftUI alerts, and the saving overlay; the
detail column has no banners. The save-conflict family (Save Conflict with
Cancel on Escape, Changes Merged, Couldn't Merge Changes) and the failed Sync Now
alert are `NSAlert`s from `MacWorkspaceAlerts`, which the split controller owns
and starts once it has a window; releasing it on lock ends any alert still up.
A Save Conflict alert closes when its conflict clears or changes, and an answer
counts only for the conflict it was shown for with no save running. What a Push
Pending Changes from the status card reports (reconnect, merge, failure) comes
back through `MacWorkspacePresentation.pushAlert` and shows in that window, not
the Databases window.
Column revisions never replace it. It resets presentation state on workspace
disappearance and rejects old cloud reconnect completions. `MacDatabaseRootView`
keeps enrollment and its biometric observer mounted across lock/unlock. This
embedding avoids replacing the window's presentation hierarchy; no content swap
orders the window or assigns first responder.

The split's sidebar and entries items are AppKit controllers
(`MacSidebarViewController`, `MacEntryListViewController`); the detail item hosts
one SwiftUI column, which shows `MacEntryDetailView` (`KeeForge/Views/Entry/Mac/`)
on `MacEntryDetailModel`: a header with Edit, cards of label/value rows and a
footer with the History link. Attachment Quick Look and Share go through the
window's `MacAttachmentPreviewController`, an `NSResponder` installed right after
the window in its responder chain, so the shared `QLPreviewPanel` takes that
window's `AttachmentPreviewSession` as its data source; Share opens an
`NSSharingServicePicker` from the row's button. Show in Large Type (the password
row's button and View ▸ Show in Large Type, validated by
`DatabaseCommands.canShowPasswordInLargeType`) goes through the reveal gate, then
hands the password to the app's one `MacLargeTypePanelController`: a borderless
key `NSPanel` centred over the window, hosting `MacLargeTypeView`. Opening
another replaces it, and it closes on any key, click or loss of key status and
on lock, content or selection changes, its window closing and resign active;
the reasons are in `SECURITY.md`. The sidebar renders
`MacSidebarSnapshot` in a source-list `NSOutlineView` (Library, Groups, Tags and
Recycle Bin headers, Tags keeping a caption row while there are none; the Recycle
Bin section is a Deleted Entries row, which selects the bin group, then the
deleted groups dimmed, and is left out while the bin is empty) with the status
card beneath. Library is All Entries, Verification Codes and Passkeys; each group
row counts every entry in its subtree, the Recycle Bin's left out, and Deleted
Entries counts the bin's own entries. Each header folds from the chevron after its
title or its "Show"; folded sections are the presentation's
`collapsedSidebarSections`, and a selection inside one keeps the list with no
row selected until a new selection unfolds it. One
`MacObservation` rebuilds the snapshot and applies it per parent with insert,
remove and move on row objects cached by `MacSidebarItemID`, never a full reload,
so expansion and selection survive edits. Selection writes the workspace and
follows it back (unfolding ancestors); expansion is the presentation's
`collapsedGroupIDs`, kept for the window's life. Group-row menus come from
`MacSidebarGroupActions` and set the same presentation state the host presents.
Entry rows dragged from the list drop onto a group row (native drop-on-row
highlighting and drag image) and move through `MacEntryDrop`, which applies Move
to Group…'s gates and `PendingMove`, save included; Library, tags, headers,
Deleted Entries and deleted groups refuse the drop. The drag pasteboard holds only
entry UUIDs under a private type tagged with the database and window, so another
window or app refuses or ignores it. Groups do not drag.
The status card is always shown for an unlocked database: its name (with the
Read-Only badge), Database Settings, Sync Now (cloud only) and Lock, the
storage and state line from `MacDatabaseStatus`, and the state's one recovery
action (Retry Save, Resolve…, Reconnect, Push Pending Changes). Sync and upload
notices sit above the entry list (`MacWorkspaceNoticesView`). Both act through
`MacDatabaseStatusActions`; pending upload counts and Push come from the
database list through `MacWorkspacePresentation.pendingUploads`. The
outline is disabled while saving and takes its appearance from the window, which
the root host's `preferredColorScheme` sets from the in-app setting. Focus and
keyboard come from the outline as first responder; nothing routes focus to it.
The outline scrolls the selected row into view only once it has a visible area,
so a tall sidebar opens at its top. Each row's identifier sits on its title text,
because XCUITest drops a table cell's own identifier.

The entry list renders `MacEntryListSnapshot` in a view-based inset `NSTableView`
(no column header; icon, title, username, the "Personal › Work" path across groups,
and the EXPIRED pill and passkey and verification-code badges) under the list
header (title, "Personal · 12 entries" count line, Sort), with the empty state,
the footer hint and, under `-ui-testing`, the `search.results.count` label. Its `MacObservation`
applies edits as row inserts, removes and moves, reloading only when the list
switches, and resolves usernames only for cells it draws. Selection follows
`MacEntryListSelection` both ways: several rows are the workspace's
`entrySelection`, which the row menu's Move to Group… and Delete, the menu bar's
Delete and the detail column's selection summary act on. Row menus
come from `EntryRowActions`; Copy Password uses the menu-bar command's guarded
path with this window's `isCurrent` recheck. Row-menu shortcuts are display
only: the main menu answers the key first, and row and sidebar menu selectors
never match a main-menu selector, or the controller in the responder chain
would catch the nil-targeted command. Return and double-click open the
editor through the workspace request; the table is disabled while saving.
In Verification Codes each row keeps the usual title and username and shows the
live code trailing, dimmed with an orange ring in its last five seconds; clicking
the code copies it (the per-entry command, no prompt). One timer redraws the
visible rows on each whole second, only while that list is on screen and the
session is unlocked; `MacVerificationCodeClock` keeps only the codes shown and
forgets them whenever the timer stops. A copy from the row menu, the code or the
menu bar leaves a green tick on its row for 1.5 seconds (`MacCopyFeedback`, in
the window's presentation, so it clears with it on lock).

The sidebar is collapsible (200–340 pt), the entries column is 260–460 pt, and
the detail takes the remaining width. `NSSplitView` autosave owns widths and
collapse state under `MacWindowRestorationStore.splitViewAutosaveName(for:)`, one
name per database, including across lock/unlock. View → Show Sidebar is forwarded
to the target window's native split controller. The split ignores the root
host's top safe area, so it runs under the titlebar, and each item keeps
`allowsFullHeightLayout`: with it off, a sidebar collapsed while one of its rows
was first responder never shows again. The sidebar runs full height; the entries
and detail columns take their top inset from their own safe area (the table's
scroll view adjusts its content insets, the detail host passes it to SwiftUI).
The unlock, opening and error screens keep the root's safe area.

## Commands and closing

`MacDatabaseCommandTargetResolver` picks the window a database command acts on:
the key database window (or the one a key sheet belongs to); with Settings or a
panel key, the main database window; with the Databases window key, or no
database window, none, so database commands are disabled. Validation and dispatch
both ask it when they run, through `AppDelegate.supplementalTarget` and each
controller's `isCommandTarget` gate. Commands that also need the window's
presentation (Duplicate, Move to Group, the View menu's Library, Sort and
Expand/Collapse items, Sync Now, Database Settings) go through
`MacWorkspaceCommands`. File ▸ New Database, Open Database File and Connect to
Server are launcher operations and ignore every session's state; Connect to
Server offers the server types first when there is more than one.
Window ▸ Databases shows the Databases window, which AppKit's own window list
leaves out; that list names each open database window, adding the unlocked
window's subtitle in parentheses, and `MacWindowMenuDecorator` gives each an
open or closed lock glyph. Database ▸ Lock All Databases (⌥⌘L, dimmed while no
window is unlocked) asks every unlocked window's session to lock through the
same request as Lock, so unsaved work asks in that window. View ▸ Hide Sidebar
reads Show Sidebar while the target window's sidebar is collapsed. Settings is an auxiliary window that cannot become main
and chooses its own database where it needs one.

Close Window, Close Database and Escape on the unlock screen all go through the
window's guarded close (`MacWindowCloseGuard`); Close Window is disabled while a
sheet is up, but Close Database still asks the guard, so an open editor answers
with its own prompt. A committed close locks and
retires exactly that session and releases its controller; cancel or a failed save
keeps both. A close waits out a write in flight on its session and asks again; a
failed master-key or encryption-settings write keeps the window. Lock keeps the window open on its unlock screen.

Quit (`applicationShouldTerminate`, also on logout and restart) goes through
`MacWindowCoordinator.requestTermination`: with nothing unsaved and no write in
flight it terminates at once; otherwise it waits out each write, then fronts each
window with an unsaved write in turn, front first, asks the close prompt (holding
that session's lock pending, so the SSH agent withdraws its keys), and writes only
after every answer is in. Cancel, a failed save or key or settings change, or a
window whose editor still holds fields (fronted, for the user to
finish) cancels the quit and leaves every window and session as it was. Don't Save
covers the draft at the revision answered for; work added after it stops the quit. A quit
that proceeds records the pre-quit topology, then freezes the record so the closes
that follow cannot shrink it.

## Toolbar and search

`MacWindowWorkspace` creates one `MacWorkspaceToolbar` per unlocked session,
beside the split controller, and drops it on lock or replacement. When it
exists, `DatabaseWindowController` turns the root host's `.toolbars` scene bridging
off and installs it as the window toolbar; on lock it removes it and turns
bridging back on for the unlock screen. One source owns the bar in each state.
Column hosts never bridge.

Each item's identifier is also its view's accessibility identifier. Tracking
separators on the split's two dividers put the search field and New Entry (the
read-only glasses instead in a read-only database) over the entry list; Edit is
in the detail's header, not the toolbar. The window title is hidden while this toolbar is installed, as
the list header shows it. The database's name is a plain (`isBordered` off) item
between flexible spaces that draws the name at the detail column's centre
(`MacToolbarTitleView`), whatever the status items take. The status card's line (plain text, `isBordered` off), Database Settings, Sync Now
and Lock join the trailing end of the detail only while the sidebar is collapsed. Each item has a
menu form for the overflow menu. Enablement comes from `DatabaseCommands` and
`MacDatabaseStatus`, and the whole bar is disabled while saving.

The search field and `DatabaseViewModel.searchText` are bound both ways through
the toolbar's observation. Edit ▸ Find (`findEntry:`) calls
`MacWorkspaceToolbar.focusSearch()`, which begins the search item's interaction.
Title bridging is off; AppKit observation owns
the database title and group/tag/search subtitle. The SwiftUI detail root applies saving
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
