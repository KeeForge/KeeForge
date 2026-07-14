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
  buffer is epic backlog, not shipped.
