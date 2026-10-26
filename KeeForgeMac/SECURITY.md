# macOS Security Model

Maintained security boundaries and limitations for the native Mac app and its
AutoFill extension. Update this document when the implementation changes.
Vulnerability reporting belongs in the [root security policy](../SECURITY.md);
release verification belongs in [the direct-distribution release reference](../.agents/skills/prepare-release/references/direct-distribution.md).

## Secrets in memory

The Mac app uses the shared [EncryptedValue](../KeeForge/Models/EncryptedValue.swift)
model: passwords, TOTP secrets, and passkey private keys are sealed with a
per-session AES-GCM key. The passkey PEM is removed from ordinary custom fields
and decrypted when needed for signing. Lock clears the session key, composite
key, parsed tree, draft, attachment pool, and retained key-file data from the
[database session](../KeeForge/ViewModels/DatabaseViewModel.swift).

Biometric unlock stores composite keys in the Keychain, not raw master passwords.
[KeychainService](../KeeForge/Services/Security/KeychainService.swift) uses the
Data Protection Keychain with `WhenUnlockedThisDeviceOnly` and
`biometryCurrentSet` access control, which on the Mac also admits an authorized
Apple Watch (see "Lock and unlock lifecycle"). The app and extension share the
team-prefixed `com.keevault.sharedkeychain` group. It must remain the first
keychain access group: items written without an explicit `kSecAttrAccessGroup`
land there.

The model has the same residual limitations on iOS and macOS:

- Other user-defined protected custom fields remain plaintext strings in
  `customFields`.
- Protected values inside unrecognized XML are retained as plaintext in opaque
  fragments for round-tripping.
- Decrypted Swift `String` and `Data` copies cannot all be reliably zeroized.
  [SecureWipe](../KeeForge/Models/SecureWipe.swift) wipes app-owned key-derivation
  and encryption intermediates, but does not control framework-owned copies,
  raw key-file data, or every parser/signing temporary.

Session-key encryption does not protect an unlocked vault from an attacker who
can inspect the process's memory. Clearing session references is not a promise
that every earlier plaintext copy has been overwritten.

## Shared storage

The App Group `group.com.keevault.shared` carries encrypted database caches,
bookmarks, database references, shared settings, and synchronization metadata
needed by the app and extension. It must never hold master passwords, composite
or session keys, or decrypted vault contents. Shared metadata is not encrypted
by the KDBX password; filenames and database references remain sensitive.

Keep app-only plaintext metadata in the Mac app's own sandbox:

- [FaviconService](../KeeForge/Services/AppSupport/FaviconService.swift) puts its
  per-domain disk cache in Application Support on macOS, with a temporary-directory
  fallback. iOS shares that cache with AutoFill through the App Group. The Mac
  extension has no network entitlement and cannot re-fetch missing icons.
- [CloudAccountStore](../KeeForge/Services/Cloud/CloudAccountStore.swift) uses
  app-local defaults on macOS. Account display names and server paths do not
  belong in shared defaults; the extension does not need these account records.

[DatabaseListStore](../KeeForge/Services/Persistence/DatabaseListStore.swift)
owns production cache writes. [AppGroupGuardrailTests](../KeeForgeTests/AppGroupGuardrailTests.swift)
cover the narrower legacy `SharedVaultStore` cache/bookmark surface; they are not
an exhaustive audit of every App Group writer.
[AppGroupIsolationTests](../KeeForgeTests/AppGroupIsolationTests.swift) protect
unit tests from reaching the user's real shared container.

## Lock and unlock lifecycle

[MacLockMonitor](../KeeForge/Services/AppSupport/MacLockMonitor.swift) requests a
lock on screen lock, screensaver start, system sleep, fast-user-switch session
resign, and closure of the last UI-hosting window. App deactivation also requests
a lock under the strict `SettingsService.macLockPolicy` option. These requests
do not depend on the iOS-only `lockOnBackground` setting.

Under the strict option, one deactivation does not lock at once: the one caused
by KeeForge's own Touch ID, Apple Watch, or login-password prompt. macOS shows
that prompt from a separate process, which takes the foreground from the app, so
locking there would lock the vault the prompt was asked for (#203). The exemption
is tied to that process, not to a prompt having been requested: the application
in front must be the system's authentication UI, recognized by its bundle
identifier (`com.apple.LocalAuthentication.UIAgent`) in a bundle on the signed
system volume. A deactivation with any other application in front locks as
before, also while a request is pending and its prompt has not appeared yet.

While the deactivation is held, the session stays open behind the prompt. Any
other application coming forward locks at once. When the request ends, however
it ends, KeeForge must be the active app again within two seconds, or the
session locks; the reply can arrive just before the reactivation, so it does not
lock by itself. The other lock requests above are not held back by a prompt.

This leaves the session open for as long as the prompt stays unanswered with
nothing else brought forward, the same exposure as leaving KeeForge itself in
front. Auto-Lock Timeout and the other lock requests still apply then.

The separate Auto-Lock Timeout controls inactivity. The monitor resets that timer
on deliberate keyboard, click, and scroll activity inside KeeForge; mouse movement
and activity in other apps do not count.

**Unsaved work can defer a lock indefinitely.** An open editor or dirty draft
keeps the session and decrypted tree available while the Save / Discard / Keep
Editing decision is pending. This applies even to sleep or screen-lock requests.
Continuing to edit after an automatic lock request requires device-owner
authentication; unavailable or failed authentication forces a lock and discards
unsaved work. That authentication does not remove the memory exposure while the
prompt remains unanswered.

[MacWindowCloseGuard](../KeeForge/Services/AppSupport/MacWindowCloseGuard.swift)
resolves unsaved work before allowing the last host window to close, so a deferred
prompt cannot be stranded after its window disappears. Sheets and panels do not
count as host windows; Settings and minimized main windows do. Cancel keeps the
window and session open.

Revealing or copying a password or protected field asks for device-owner
authentication through the session's
[SecretAccessGate](../KeeForge/Services/Security/SecretAccessGate.swift). With
the Authentication Grace Period setting at its default, Always Ask, every such
action prompts. A longer setting (at most five minutes) skips the prompt for that
long after an unlock or a successful authentication. The grant is held in memory
only, ends on every lock request above, including one that unsaved work defers,
and on a failed or cancelled prompt, and is not extended by using it. Under the
default lock policy, switching to another app does not lock and therefore does
not end the period either; the strict policy ends it with the lock.

The opt-in Auto-Unlock with Touch ID setting prompts when a database opens in
its foreground key window or the user returns to that window: app or window
activation, or the screen unlocking or login session returning while KeeForge
stays the active app. Those events, rather than scene phase or a new lock cycle,
drive this flow. It needs Touch ID itself; an Apple Watch alone never prompts on
its own, matching the setting, which appears only with Touch ID.
The queued attempt rechecks the foreground window, eligibility, and lock cycle;
a screen-lock, sleep, or other lock arriving first invalidates it. A manual lock
stays locked until a later activation or an explicit unlock. Each lock cycle has
at most one presented automatic prompt, so cancellation or password fallback does
not immediately prompt again; either returns to the unlock form, not an error. The password form and explicit retry remain available.
AutoFill continues to use the same preference for its own foreground flow.

Quick unlock (#66) keeps one Keychain item per database. On the Mac its access
control is `[.biometryCurrentSet, .or, .companion]`: Touch ID with the currently
enrolled fingerprints, or an authorized Apple Watch. It carries no
`.userPresence` or `.devicePasscode` flag, so the Mac login password cannot
release it. It stays `WhenUnlockedThisDeviceOnly` in the data-protection
keychain and the shared access group; iPhone and iPad keep `.biometryCurrentSet`
alone. The unlock screen's button evaluates
`.deviceOwnerAuthenticationWithBiometricsOrCompanion`; automatic foreground
unlock uses that same policy and saved key.

The item permits either mechanism, but AutoFill asks only for biometrics. It
offers quick unlock only while Touch ID is available, evaluates
`.deviceOwnerAuthenticationWithBiometrics`, and reads the item with a
non-interactive context. So the Keychain cannot raise a Watch prompt of its
own. When the Touch ID context cannot release the item, AutoFill falls back to
the master password. The main app reads it the same way, so its single prompt is
the one it evaluated.

A successful unlock writes the item while Touch ID or the watch can evaluate
the policy. It rewrites an existing item even while neither can, because the
master key may have changed on another device. A master-key change rewrites an
existing item without checking either mechanism, and deletes it if that fails.
If the item can no longer be read after authentication succeeds, for example
because the enrolled fingerprints changed, the unlock screen reports
"Saved Unlock Key Unavailable" with the password form below it, and Try Again
does not repeat the quick unlock. The next password unlock writes a fresh item. Items written by earlier versions carry
`.biometryCurrentSet` alone. Touch ID still opens them, and the next unlock
rewrites them with the combined policy.

Beside that item sits an express-unlock item: the KDF output of the database
version last opened by the app or AutoFill, or saved by the app, bound to that
version's KDF parameters and the composite key. It has the same access control
and protection class. The app and the AutoFill extension read it with the
context that released the quick-unlock item, so it never prompts, and both
write it back right after the quick-unlock item, whose every write or removal
deletes it first. A hardware-key database never gets one. Quick unlock of an
unchanged file then skips the KDF, in the app and in AutoFill; a key that does
not open the file only costs the KDF.
Every save rotates the KDF salt: an app save stores the saved version's key in
its place, but only while the quick-unlock item holds the session's composite
key. A save anywhere else leaves the item unmatched, so the next unlock runs the
KDF and replaces it.

## Screen and clipboard privacy

Password reveal and copy actions recheck their originating session, lock cycle,
and content revision after device-owner authentication. Detail and editor actions
also reject changed navigation, selection, or inputs; changing the selected entry
conceals its fields. A successful prompt does not authorize a later session.

Custom-field drag reordering uses a native list of field names. Field values
are not displayed in that list or its drag previews.

[ScreenProtectionService](../KeeForge/Services/Security/ScreenProtectionService.swift)
places a blur cover over all app windows, including Settings, when the app
resigns active and removes it on activation. The SSH Agent tab also removes
its vault-derived entry titles and key fingerprints from its view while the app
is inactive
([MacSSHAgentController](../KeeForge/Services/SSHAgent/MacSSHAgentController.swift)
`concealsKeyList`). This cover is independent of the capture-blocking toggle.

The default-on Block Screen Capture setting applies `NSWindow.sharingType = .none`
to existing and newly observed windows, including Settings. Treat this as
best-effort: ScreenCaptureKit capture on macOS 15+ can bypass it. It is not a
security boundary against software with Screen Recording or Accessibility access.
Unlike iOS's recording shield, the Mac implementation has no equivalent capture
signal on which to base a guarantee.

[ClipboardService](../KeeForge/Services/AppSupport/ClipboardService.swift) marks
copies with `org.nspasteboard.ConcealedType`, a convention for cooperating clipboard
managers rather than an access restriction. A timer and completed database locks
clear the copy only when the pasteboard's `changeCount` still matches KeeForge's
write, preserving anything copied subsequently.

macOS has no equivalent of the iOS `.localOnly` and `.expirationDate` copy options.
Copied secrets can follow the user's Universal Clipboard setting, and KeeForge's
in-process clear timer cannot survive termination. Mac locks do not use the iOS
backgrounding exemption that keeps a copy available for pasting. A deferred lock
has not yet performed that clear.

## Menu bar quick search

The optional menu bar item and its global shortcut
([MacQuickAccessController](../KeeForge/Services/AppSupport/MacQuickAccessController.swift))
are off by default and add no lock rule, network access, or storage. Both
settings live in the app's own defaults. The shortcut is registered through
Carbon's `RegisterEventHotKey`, which needs no Accessibility permission and fails
rather than taking over a combination another app holds.

The panel reads the one active session on every render and holds no entry data
itself. It shows entry titles, user names, and folder paths only while that
session is unlocked; a locked or missing session sends the user to the main
window. Every existing lock trigger therefore empties it. Closing the last main
window still locks, so quick search needs that window open or minimized.

Copying follows the main window's rules: the password waits on the same
device-owner prompt as ⇧⌘C, skipped only inside the session's authentication
grace period, and is re-checked against the session after it,
while the user name and verification code copy without a prompt. Copies go
through `ClipboardService`, with its concealed marker, clear timer, and
clear-on-lock.

A new panel presentation invalidates an earlier pending password copy. Losing
focus to the authentication prompt may hide the panel and clear its query without
invalidating that copy; the original session and content must still match.

The panel is a non-activating, borderless `NSPanel`. It cannot become a main
window, so it never counts as a UI-hosting window for the lock monitor. It is
not titled, so the resign-active blur cover skips it. Because a search usually
starts while another app is active, the panel closes when it loses key status
and does not rely on that cover. It applies the Block Screen Capture setting to
itself when shown, with the same best-effort limits as the other windows.

## SSH agent

The optional SSH agent
([MacSSHAgentController](../KeeForge/Services/SSHAgent/MacSSHAgentController.swift))
is off by default. While it is on, it listens on `ssh-agent.sock` in the app's
container home. The socket is created mode 0600 inside a container directory only
the user can enter, and every connection is checked with `getpeereid` against the
app's own user. At most 64 connections are open at once, since each one costs the
app a thread; a further one takes the place of the connection that has gone longest
without a complete request, so clients that connect and then stall, stop inside a
message, or never read their answer cannot keep new ones out. No connection has a
time limit of its own: below 64, an idle one stays open. It needs no extra
entitlement and adds no network access. Turning
the agent off or quitting removes the socket; a file left by a crash is replaced on
the next start, and anything at that path that is not a socket is left alone and
reported.

The agent writes no keys anywhere. Which entries it serves is a per-database list of entry
UUIDs in the app's own defaults, chosen in Settings ▸ SSH Agent. Every request
reads those entries from the one active session at that moment, so nothing is
offered while that session is locked, closed, or has a lock pending: one waiting
on unsaved work or a window-close prompt, or Retry Save and Lock writing before it
locks.
The private key is read from the decrypted attachment pool for each request and
parsed off the main thread. A key file over 64 KiB, several times the largest
supported key, is refused before it is decoded, a `KeeAgent.settings` over the same
size is not parsed, and the list of identities is cut to the 256 KiB message limit,
so what an attachment can make one request do is bounded. A parsed key is kept in
memory only for the same entry, the same lock cycle of the same session, and
byte-identical key file content, so an unchanged key is not parsed for every
request. That cache is emptied the moment the session locks or a lock becomes
pending, when the selection changes, and when the agent is turned off; a key parsed
from a read of the session that such an event has overtaken is not kept. After signing, the agent reads the session
again and withholds the signature if the session's lock cycle, the selection, or the
entry's key attachment has changed. No key file is written to disk and no key is exported.

Supported keys are unencrypted OpenSSH private keys (`openssh-key-v1`) for Ed25519,
ECDSA P-256/P-384/P-521, and RSA. RSA signs only with `rsa-sha2-256` or
`rsa-sha2-512`; SHA-1 `ssh-rsa` requests fail. RSA keys outside OpenSSH's own
1024 to 16384 bit range are rejected when parsed, which also bounds the arithmetic a
crafted attachment can make a request do. Passphrase-protected keys, PEM and
PKCS #8 files, and PuTTY keys are listed as unsupported and never served. The agent
answers only identity listing and signing; requests to add, remove, or lock keys,
and protocol extensions, fail.

Like `ssh-agent`, the agent cannot tell one local process from another. Any process
running as the user that can reach the socket can list the chosen public keys and
obtain signatures while the database is unlocked, and there is no per-signature
confirmation. That also holds for an entry whose `KeeAgent.settings` asks for a
confirmation or a lifetime in KeeAgent or KeePassXC: KeeForge reads only the key's
attachment name from that file, and choosing the entry in Settings is the consent. Forwarding the agent to a remote host extends the same ability to that
host for the length of the connection. A signature is not bound to a destination
either: `session-bind@openssh.com` is refused like every other extension.

Not validated on a signed, sandboxed build: whether a client outside the container
reaches the socket without a prompt, how the covered Settings window and capture
block behave in Mission Control and under ScreenCaptureKit, and `ssh`, `git`, and
a forwarded agent end to end. Not measured: lock latency while many clients send
requests (each one reads the session on the main thread), and the time a
16384-bit RSA signature takes. The same-user peer check has no test with a peer of
another user.

## Plaintext attachment files and disk encryption

[AttachmentPreviewFileStore](../KeeForge/Services/AppSupport/AttachmentPreviewFileStore.swift)
writes plaintext temporary files for preview/share, removes them on dismissal and
completed database lock, and purges orphaned files at launch. Quick Look or another
receiving application may retain its own copies outside KeeForge's control.

The preview consumer validates its request and session after asynchronous loading
and before creating a plaintext file, so a completed lock or dismissed preview
cannot be followed by a late file write from that request.

[PlatformCompat.atomicProtected](../KeeForge/Extensions/PlatformCompat.swift)
uses atomic writes without iOS's per-file `.completeFileProtection` on macOS.
FileVault is the disk-encryption protection for these plaintext files; KDBX
password encryption does not cover them. File deletion is not secure erasure.
Sleep images and swap are also outside KeeForge's control, particularly on older
Intel Macs without a T2 chip. Do not promise app-level protection against recovery
of an unlocked session from memory or disk; the deferred-lock limitation applies
here too.

## Entitlements and distribution boundaries

Both release channels use App Sandbox and Hardened Runtime. Release artifacts
must have no `com.apple.security.cs.*` exceptions and no `get-task-allow`.
[verify_mac_artifact.sh](../ci_scripts/verify_mac_artifact.sh) checks the app and
nested executable bundles; [build_mac_direct.sh](../ci_scripts/build_mac_direct.sh)
also enforces this before direct-build notarization.

The source entitlements in [KeeForgeMac.entitlements](KeeForgeMac.entitlements) are:

| Entitlement | Purpose |
| --- | --- |
| `com.apple.developer.authentication-services.autofill-credential-provider` | Registers the containing app as an AutoFill provider; the extension needs it too. |
| `com.apple.security.app-sandbox` | Sandboxes both release channels. |
| `com.apple.security.files.user-selected.read-write` | Access to files selected by the user. |
| `com.apple.security.files.bookmarks.app-scope` | Persistent access through security-scoped bookmarks. |
| `com.apple.security.network.client` | Outbound provider sync, opt-in favicon fetching, feedback submission, and channel-specific store/update operations. |
| `com.apple.security.application-groups` | Shared encrypted vault caches and extension metadata in `group.com.keevault.shared`. |
| `keychain-access-groups` | Team-prefixed `com.keevault.sharedkeychain`, shared with AutoFill. |

The [direct-build entitlements](KeeForgeMacDirect.entitlements) add only
`com.apple.security.temporary-exception.mach-lookup.global-name`, for
`com.keevault.app-spks` and `com.keevault.app-spki`. These let the sandboxed app
reach Sparkle's installer services. The direct build must also enable
`SUEnableInstallerLauncherService`. The Mac App Store artifact must carry neither
the exception nor the enabled service. The artifact verifier checks both channels.

[project.yml](../project.yml) excludes the Dropbox and OneDrive providers and
removes SwiftyDropbox/MSAL from the Mac target's dependencies. Current provider
availability is defined by
[CloudProviderKind](../KeeForge/Services/Cloud/CloudSyncModels.swift), which enables
WebDAV and FTP on macOS. Reintroducing OneDrive requires restoring its source and
SDK dependency, the MSAL keychain group, and matching Developer ID profiles.

## AutoFill extension boundary

The [Mac extension entitlements](../AutoFillExtension/AutoFillExtensionMac.entitlements)
include only the AutoFill capability, sandbox, App Group, and shared keychain
group. There is no `network.client`, `files.user-selected.read-write`, or
`files.bookmarks.app-scope` entitlement. Network sync belongs to the app.

[CredentialProviderCoordinator](../AutoFillExtension/CredentialProviderCoordinator.swift)
loads the shared encrypted cache first. Shared code also has a security-scoped
bookmark fallback; its presence does not grant the Mac extension the containing
app's file-access entitlements. Keep the cache current on app saves rather than
relying on that fallback to reach an external original file.

The extension holds decrypted contents while filling and clears its session on
cleanup. It also supports passkey registration; its shared save machinery must
preserve encrypted storage, conflict checks, and pending-upload handling. The
boundary is not a claim that the extension is read-only.

A registration never writes a bookmarked file. The extension saves the encrypted
database to the shared copy it read and keeps the same bytes in
[PendingLocalSaveStore](../KeeForge/Services/Persistence/PendingLocalSaveStore.swift),
inside the App Group. The app merges them into the file after the next unlock,
through its ordinary save with the open-time hash check and a backup. Until then
the new passkey exists only in the App Group on this Mac. A pending save that
will not open with the database's key, or cannot be merged safely, moves into
the database's backups and the app says so. Backup rotation never removes that
file; it stays until the database is removed from KeeForge.

[KDFExecutionPolicy.autoFillExtension](../KeeForge/Models/KDFExecutionPolicy.swift)
bounds attacker-controlled Argon2 memory, work, and parallelism. The iOS runtime
memory preflight in [AutoFillMemoryLimit](../KeeForge/Services/AutoFill/AutoFillMemoryLimit.swift)
is unavailable on Mac, so that runtime check adds no protection there. The main
app has its own KDF policy; the extension's policy is not the only KDF protection
in the Mac product.

## Sparkle update trust

Only [project-direct.yml](../project-direct.yml) links Sparkle. The default App
Store spec has no updater dependency and blanks the feed, public key, and installer
launcher settings. The artifact verifier rejects Sparkle/update configuration in
MAS artifacts and StoreKit linkage in KeeForge's direct-build binaries.

[SoftwareUpdateService](../KeeForge/Services/AppSupport/SoftwareUpdateService.swift)
retains the direct-build updater and observes Sparkle's readiness on the main
actor to control Check for Updates availability during startup and update checks.
Sparkle owns appcast fetching, payload verification, and installation.

Direct updates use an HTTPS appcast, Sparkle EdDSA verification against the embedded
`SUPublicEDKey`, and notarized, stapled app payloads. The signing private key lives
outside the repository in the login Keychain. Its recovery backup is essential
release infrastructure; do not print or export it as part of routine verification.

[release_direct_artifact.sh](../ci_scripts/release_direct_artifact.sh) verifies the
immutable ZIP through the draft-release API and, separately, its final public URL
before publishing a staged appcast with an atomic base-feed comparison. These
checks bind publication to the accepted artifact; they do not replace update
signature verification in the installed app.

Control of the appcast host and signing key compromises the direct update channel.
Maintain both as trusted release infrastructure. Run the
[manual Sparkle rehearsal](../.agents/skills/prepare-release/references/direct-distribution.md#manual-sparkle-rehearsal-test-feed-only)
after changing update infrastructure or sandbox exceptions. ZIP extraction and
clean-account Gatekeeper verification are part of that procedure. Record each
run's evidence in the candidate manifest, not in this security model.
