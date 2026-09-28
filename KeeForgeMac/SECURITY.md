# macOS Security Model

Maintained security boundaries and limitations for the native Mac app and its
AutoFill extension. Update this document when the implementation changes.
Vulnerability reporting belongs in the [root security policy](../SECURITY.md);
release verification belongs in [CI Scripts](../ci_scripts/README.md#macos-distribution-channels).

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
`biometryCurrentSet` access control. The app and extension share the
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

The main app does not automatically raise Touch ID on activation.
`BiometricAutoUnlockPolicy` requires explicit unlock on Mac because an active
scene does not prove the user has returned to a foreground window. The AutoFill
extension has its own foreground authentication flow and still honors
`SettingsService.autoUnlockWithFaceID`.

Apple Watch unlock (#66) is a separate explicit action on the unlock screen,
never raised by a lock cycle. Its composite-key copy is a device-only Keychain
item protected by the `.companion` access-control flag, and LocalAuthentication
evaluates `.deviceOwnerAuthenticationWithCompanion`; neither accepts the Mac
login password. The copy is created only while a paired watch is available; once it exists,
every unlock rewrites it, because the master key may have changed on another
device. It is stored independently of the Touch ID item, so it cannot weaken or
migrate the Touch ID policy. A master-key change rewrites both items even when Touch ID or
the watch cannot authenticate at that moment. AutoFill's own prompt stays
biometric-only.

## Screen and clipboard privacy

[ScreenProtectionService](../KeeForge/Services/Security/ScreenProtectionService.swift)
places a blur cover over vault-content windows when the app resigns active and
removes it on activation. Settings is excluded from the cover because it contains
no vault secrets. This cover is independent of the capture-blocking toggle.

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

## Plaintext attachment files and disk encryption

[AttachmentPreviewFileStore](../KeeForge/Services/AppSupport/AttachmentPreviewFileStore.swift)
writes plaintext temporary files for preview/share, removes them on dismissal and
completed database lock, and purges orphaned files at launch. Quick Look or another
receiving application may retain its own copies outside KeeForge's control.

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
[manual Sparkle rehearsal](../ci_scripts/README.md#manual-sparkle-rehearsal-test-feed-only)
after changing update infrastructure or sandbox exceptions. ZIP extraction and
clean-account Gatekeeper verification are part of that procedure. Record each
run's evidence in the candidate manifest, not in this security model.
