# macOS Security Notes

Honest per-platform security deltas for the native macOS app. This is a living
note (no date prefix): it describes how KeeForge's macOS build differs from iOS
and what those differences do and do not protect against. Keep it truthful — it
backs the README security-highlights row and the in-app Settings copy.

## In-memory secret model — unchanged

The `EncryptedValue` + per-session `SymmetricKey` model is pure
Foundation/CryptoKit and ports to macOS with no changes. Secrets are re-encrypted
in memory, lock clears the session key and invalidates access, and composite keys
live in the Keychain rather than as raw master passwords. macOS is at parity with
iOS here.

Passkeys have the same parity: the imported private key PEM
(`KPEX_PASSKEY_PRIVATE_KEY_PEM`) is diverted out of `customFields` at parse time
and held as a session-key-sealed `EncryptedValue` (`KPEntry.passkeyPrivateKey`),
exactly like the entry password and TOTP secrets. It is decrypted just-in-time
for WebAuthn signing in the AutoFill extension and becomes unreadable on lock.

Accepted residuals of this model (on both platforms):

- Protected values captured inside `unknownXML` opaque fragments are re-rendered
  with embedded plaintext for round-tripping (`KDBXParser`'s protected-value
  re-render), so a protected field inside an unrecognized element still lives as
  a plaintext string until the entry is freed.
- Other user-defined `Protected="True"` custom fields remain plaintext `String`s
  in `customFields`; only the password, TOTP secrets, and the passkey private
  key are session-key sealed today.
- Transient `String`/`Data` copies made during parsing and signing cannot be
  zeroized (see "Swift `String` does not zeroize" below).

## App Group container world-readability (macOS 14)

On iOS the App Group container (`group.com.keevault.shared`) is sandbox-private.
On macOS 14 the same container is **readable by the logged-in user's other
(non-sandboxed) processes**. Standing guardrail (epic-wide): only encrypted KDBX
bytes, security-scoped bookmarks, and filenames are ever written there — never key
material.

Slice 06 tightens one specific case: the **favicon disk cache**. A favicon cache
is a plaintext, per-domain fingerprint of the vault's entries (which sites you
have logins for), so it is deliberately kept **out** of the group container on
macOS:

- **iOS** keeps the favicon cache in the App Group container so the AutoFill
  extension can read icons without re-fetching.
- **macOS** relocates it to the app's own sandbox container (Application
  Support), which is not group-shared. The macOS AutoFill extension therefore
  renders without favicons or re-fetches them rather than widening the
  group-container exposure. (`FaviconService.cacheDirectory`.)

The same relocation applies to **cloud-account records** (the
`KeeForge.cloudAccounts` defaults key). These records carry PII — Dropbox and
OneDrive account emails, WebDAV `user@host/path` display strings — so:

- **iOS** keeps them in the App Group `UserDefaults` suite (sandbox-private;
  unchanged behavior). The AutoFill extensions do not read this key.
- **macOS** stores them in the app's own sandbox defaults
  (`UserDefaults.standard`). On first access, `CloudAccountStore` runs a
  one-time migration that copies any value an earlier build wrote to the group
  suite into standard defaults (without clobbering an existing value) and then
  deletes it from the group suite, scrubbing previously written PII from the
  world-readable container. (`SharedVaultStore.cloudAccountDefaults`,
  `CloudAccountStore.migrateAccounts(from:to:)`.)

## Lock lifecycle — driven only by `MacLockMonitor`, and unconditional

macOS has no "scene entered background" moment worth locking on (windows
background on minimize and app hide), so `MacLockMonitor` is the whole lock
lifecycle: screen lock, screensaver start, system sleep, fast-user-switch
session resign, the last window closing, and — only under the strict `Lock
Automatically` option — app deactivation. It applies
`SettingsService.macLockPolicy` itself, and that picker (Settings ▸ Security) is
the only lock switch the Mac exposes.

The window-close trigger exists because ⌘W closes the only window without
quitting, while the session lives in app-level `@State`: without it an unlocked
vault would sit decrypted in memory with no window to lock it from and no
File ▸ New Window to get it back. `NSWindow.willCloseNotification` fires the
lock only when no window that could host the app's UI remains (sheets and
panels never count; the Settings window does, and closing it later re-runs the
check). Like every other trigger it is unconditional and policy-independent —
`lockRequest()` still defers a *dirty* draft to the usual discard prompt, which
the user sees when the window comes back.

The lock path is therefore **unconditional** once a trigger fires:
`DatabaseViewModel.handleSceneDidEnterBackground()` locks on macOS without
consulting `SettingsService.lockOnBackground`. That key is iOS-only (`Lock When
App Goes to Background`, rendered only by the iOS Security settings screen), so
gating the Mac on it would let an imported or shared-defaults `false` silently
disable the whole macOS lock guarantee with no UI to notice or repair it.
macOS also never takes the iOS clipboard exemption: every Mac lock trigger
means the user walked away, so the copy is scrubbed (see "Clipboard" below).

## No lifecycle biometric auto-unlock on macOS

`BiometricAutoUnlockPolicy.allowsAutomaticUnlock` is `false` for the native Mac
app, so KeeForge never raises a Touch ID prompt on its own there; the Mac keeps
the explicit "Unlock with Touch ID" button in `UnlockView`.

The reason is the same one that disables it for iOS apps running in
compatibility mode on a Mac (#84): `scenePhase == .active` does not prove the
window is frontmost. On macOS it is worse — `MacLockMonitor`'s triggers are
delivered synchronously while the scene still reports `.active`, and sleep and
fast-user-switch resign do not deactivate the app at all. An automatic attempt
would therefore fire in the same turn as the lock the user's *absence* just
caused, raising a prompt against a machine that is locking, sleeping, or
running a screensaver; and because an attempt that comes back
`.promptUnavailable` returns its lock cycle's one attempt, it would retry
rather than settle.

`SettingsService.autoUnlockWithFaceID` remains meaningful on the Mac: it still
gates the macOS AutoFill extension's auto-unlock
(`AutoFillExtension/CredentialProviderCoordinator.swift`), which runs in its
own foreground extension context.

## Screen privacy — layered, and best-effort on macOS 15+

iOS uses `UIScreen.isCaptured` to shield the app while it is being recorded.
macOS has no equivalent signal, so protection is layered:

1. **Deterministic blur cover on resign-active.** Whenever KeeForge stops being
   the frontmost app it places a frosted-glass overlay over every vault-content
   window, lifted again when it becomes active. This is unconditional and does
   not depend on the toggle below. The **Settings window is excluded** — it shows
   no secrets, so covering it would be visual noise; capture blocking is still
   applied to it uniformly through the single choke point.
2. **Best-effort capture blocking** (the "Block screen capture" setting, default
   on). A single choke point applies `NSWindow.sharingType = .none` to every
   window; new windows inherit the current policy through the key-window
   observer, so there are no per-window call sites. **This is best-effort: on
   macOS 15 and later, ScreenCaptureKit-based capture ignores `sharingType`**, so
   a determined screen recorder can still capture the window. When it does work
   (notably ⇧⌘4 and legacy capture on macOS 14), a screenshot of KeeForge comes
   out black or fails — that is the protection working, not a bug.

This matches the competitive landscape: Strongbox ships the same opt-in toggle,
Bitwarden blocks by default, KeePassium relies on screen-lock instead.

## Clipboard / Universal Clipboard ceiling

macOS applies the `org.nspasteboard.ConcealedType` marker (hides copied values
from clipboard-manager apps) and a changeCount-guarded clear timer plus
clear-on-lock. But **macOS cannot exclude a copy from Handoff's Universal
Clipboard**, so a copied password may briefly appear on the user's other devices'
clipboards. iOS can set `.localOnly`/expiry; macOS cannot. This is surfaced
honestly in Settings → Security.

Clear-on-lock is unconditional on macOS. iOS exempts one case — backgrounding
the app, which is when the user switches away to paste (issue #34) — but that
exemption deliberately stops at the platform line: it leans on the
system-enforced `.expirationDate` and `.localOnly` that macOS does not have, and
every Mac lock trigger (screen lock, screensaver, sleep, user switching) means
the user walked away from the machine rather than switched apps. Since the
macOS clear timer is an in-process `Task`, it does not survive app termination,
which makes the scrub-on-lock the real bound here.

## Attachment previews rely on FileVault

Attachment preview/share writes short-lived plaintext temp files that are removed
on dismiss and on database lock (`AttachmentPreviewFileStore.clearAll()`). On iOS
these are written with Data Protection (`.completeFileProtection`). **On macOS
per-file Data Protection is inert** — setting a protection class fails with EPERM
(verified on macOS 26), so `Data.WritingOptions.atomicProtected` omits it on macOS
and at-rest encryption is provided by **FileVault** instead. The same rationale
governs every protected write in the app (see `PlatformCompat.atomicProtected`).
Quick Look itself uses SwiftUI's native `.quickLookPreview(_:)` on macOS; iOS
keeps the `QLPreviewController` representable.

## Non-T2 Intel hibernation caveat

On Apple Silicon and T2 Macs the encrypted hibernation image and secure memory
handling limit what a powered-off-then-imaged attack recovers. On **older Intel
Macs without a T2 chip**, hibernation/sleep images and swap are weaker, and an
unlocked session's decrypted secrets could in principle be recovered from disk if
the machine is seized while suspended. FileVault plus locking on sleep is the
mitigation; there is no app-level fix.

## Entitlements and hardened-runtime posture

Reviewed against the shipping build before the first Mac release. Both channels
are sandboxed and hardened-runtime, and **neither carries a single
`com.apple.security.cs.*` exception** — no disabled library validation, no
allow-jit, no unsigned-executable-memory, no `get-task-allow`. Sparkle 2 needs
none of them: Xcode signs its XPC services with the same team id, and library
validation permits a same-team load. `ci_scripts/build_mac_direct.sh` enforces
this on the app *and* on every nested bundle it embeds, so an exception added to
the AutoFill extension or to a Sparkle XPC service fails the release build
rather than shipping quietly.

What the **app** (`KeeForgeMac/KeeForgeMac.entitlements`) asks for, and why:

| Entitlement | Why it is needed |
| --- | --- |
| `app-sandbox` | Required for the Mac App Store, kept for the direct channel too. |
| `files.user-selected.read-write` | The user picks a `.kdbx` themselves; there is no other way to reach it. Grants access to what they chose, nothing else. |
| `files.bookmarks.app-scope` | Re-opening that same file after relaunch without asking again. The alternative is a file picker on every launch. |
| `network.client` | Cloud sync (WebDAV for the first release), opt-in favicon fetching, and the user-initiated feedback form. Outbound only; there is no `network.server`. |
| `application-groups` → `group.com.keevault.shared` | The only channel through which the AutoFill extension sees a database. See the container caveat above. |
| `keychain-access-groups` → `com.keevault.sharedkeychain` | Composite keys shared with the extension. Must stay **first**: an item stored without an explicit `kSecAttrAccessGroup` lands in the first listed group. |

That list is the whole of it. An earlier draft also carried
`com.microsoft.identity.universalstorage`, MSAL's macOS token cache group, which
the shipping build never exercises: Dropbox and OneDrive are hidden from the
macOS UI (`CloudProviderKind.isAvailableOnCurrentPlatform`), so nothing on a Mac
authenticates through MSAL and nothing writes to that group. It was removed
before the first release rather than after — a hand-made Developer ID profile
embeds the entitlements it authorizes, so changing the set later costs a profile
regeneration and a re-sign.

Be accurate about what that bought. Keychain access groups are namespaced by the
team prefix, so `$(AppIdentifierPrefix)com.microsoft.identity.universalstorage`
was only ever reachable by apps signed with this team's identity — Microsoft's
own apps included a different prefix and could not reach it. Removing it closed
no path an attacker had. What it does is keep the entitlement set equal to what
the app actually uses, so a future reviewer of this file does not have to
re-derive why an unused permission is there.

The larger version of the same question is still open: `SwiftyDropbox` and
`MSAL` remain dependencies of the `KeeForgeMac` target, and
`DropboxCloudProvider.swift` / `OneDriveCloudProvider.swift` compile into it, so
both OAuth SDKs ship inside a binary whose UI cannot invoke them. Cutting that
means `#if`-guarding the providers and giving up the property that their code
stays compiled and unit-tested on both platforms. Not done, and deliberately so.

Whoever unhides OneDrive on macOS must add the keychain group back — MSAL checks
for it by suffix match before enabling its cache, and silent token refresh
across relaunch does not work without it — and regenerate the Developer ID
profiles in the same change. Both entitlements files carry that note.

## AutoFill extension boundary

The macOS AutoFill extension is the process that holds decrypted vault contents
while it fills, so its entitlement set is deliberately the **smallest of the
four targets** — smaller than the app's, and identical to the iOS extension's
apart from `app-sandbox`, which iOS extensions get implicitly:

- **No `network.client`.** The extension cannot reach the network at all. It
  cannot sync, cannot fetch favicons, and cannot exfiltrate over a socket even
  if a parsing bug were exploited inside it. Cloud work belongs to the app.
- **No `files.user-selected.read-write`, no `files.bookmarks.app-scope`.** The
  extension cannot resolve a security-scoped bookmark or reach the user's
  original `.kdbx` on disk. It reads only the encrypted copy the app cached into
  the App Group container — which is why the app refreshes that copy on save.
- **One keychain group**, the shared one, in the same order as the app's, so a
  composite key written by either process is readable by the other and by
  nothing else. MSAL's group is app-only and intentionally absent.

The boundary is enforced by more than review: `AppGroupGuardrailTests` pins the
group container's write surface to encrypted KDBX payloads, bookmark blobs, and
filename metadata, and the container is world-readable to the user's other
processes on macOS 14 (above), so widening that surface is a security change and
not a convenience one.

The memory ceiling is a separate constraint with a security edge:
`KDFExecutionPolicy.autoFillExtension` bounds what a hostile KDBX header can ask
the extension to allocate. It is the **only** KDF guard on macOS, where
`os_proc_available_memory` does not exist and the iOS pre-flight has nothing to
read (`AutoFillExtension/README.md`).

## Sparkle update channel — direct builds only

Attack surface the iOS app never had, and it exists in exactly one of the two
channels. The App Store build cannot contain an updater by construction: Sparkle
is declared in `project-direct.yml`, an overlay spec, so a plain
`xcodegen generate` produces a project with no Sparkle package in it at all.
There is no runtime flag to get this wrong.

What authenticates an update in the direct channel:

- **EdDSA signatures.** Sparkle verifies each download against `SUPublicEDKey`
  before it will install. The private half lives in the login keychain, never in
  the repo and never in CI logs. Losing it strands every direct install with no
  supported way to update them — treat its backup as a release-critical secret,
  not a developer convenience.
- **HTTPS appcast.** `SUFeedURL` must be `https://`. The release script refuses
  to build otherwise, and refuses an empty `SUPublicEDKey`, so a direct build
  that could not authenticate its own updates never reaches notarization.
- **Notarized, stapled payload.** The zip the appcast serves is the stapled app,
  so a first launch offline still passes Gatekeeper.

Residual risk to be honest about: whoever controls the appcast host and the
EdDSA private key together can push code to every direct install. That is
inherent to self-distributed updates. The App Store channel does not have this
property, which is one reason it is the default build.

## Not fixable at the app level

These are outside KeeForge's control on macOS and should not be represented as
solved:

- **Malware already granted Accessibility or Screen Recording permission** can
  read the screen and synthesize input regardless of `sharingType`.
- **Admin-level memory dumps** (e.g. attaching a debugger as root, or reading
  another process's memory) can reach decrypted secrets while a vault is
  unlocked. The session-key model raises the bar but cannot defeat a privileged
  local attacker.
- **Swift `String` does not zeroize.** Decrypted secrets that transit Swift value
  types cannot be reliably wiped from memory; an `mlock`/`SecureBytes`-style
  buffer is epic backlog, not shipped. Key material is handled more tightly:
  the composite key is a CryptoKit `SymmetricKey` (CryptoKit zeroes its backing
  storage on release), and the `Data`/array intermediates KeeForge itself builds
  from it — KDF inputs and outputs, master and HMAC keys, the ChaCha20
  outer-cipher state, the Keychain write buffer — are wiped with `memset_s`
  (`Models/SecureWipe.swift`); Argon2 runs through the reference C `argon2_hash`
  directly so no wrapper keeps copies. Still out of reach: the bytes the
  Security framework hands back on Keychain read (and its own copies on write),
  the raw key-file bytes the session keeps, the inner random-stream keystream,
  and CommonCrypto/CryptoKit internals.
