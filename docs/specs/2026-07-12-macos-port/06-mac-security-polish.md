# Slice 06: Mac Security Polish

> Parent: [`epic.md`](./epic.md) · Depends on: 02

## Goal

Close the remaining macOS security and feature-parity gaps: layered screen privacy, attachment QuickLook, the review prompt, the favicon-cache exposure, and an honest security-deltas doc.

## Scope

**In:**
- Screen privacy: blur/cover-on-resign-active (deterministic) + a "Block screen capture" toggle (best-effort `NSWindow.sharingType = .none`, default on) on every secret-bearing window.
- Attachment preview on macOS (replaces the slice-01 `#if os(iOS)` gap).
- `ReviewPromptService` macOS branch.
- Favicon cache relocation out of the App Group container on macOS.
- `docs/` security note on macOS deltas + README marketing-copy update.
- Optional, strictly timeboxed: `NSHapticFeedbackManager`, `MenuBarExtra` quick search.

**Out:** distribution and signing (slice 07); iOS behavior changes (none in this slice); `mlock`/SecureBytes hardening (epic backlog).

## Affected areas

- Modified: `KeeForge/Services/Security/ScreenProtectionService.swift` — replace the slice-01 empty mac stub with the real design: observe app-active state for the blur cover; apply/remove `sharingType` per the toggle across all windows that can show vault content (main window, Settings shows no secrets — decide and document; future windows must inherit via a single choke point, not per-window call sites).
- Modified: `SettingsView.swift` + `SettingsService.swift` — "Block screen capture" toggle, default on, with honest helper text (best-effort on macOS 15+, where ScreenCaptureKit ignores `sharingType`; screenshots of the app will fail while enabled — that's the feature working).
- Modified: `KeeForge/Views/AttachmentQuickLookPreview.swift` — adopt SwiftUI's `.quickLookPreview(_:)` on macOS (12+); evaluate migrating iOS to the same modifier (single code path) and keep the `QLPreviewController` representable only if the modifier's UX falls short. `AttachmentPreviewFileStore` unchanged (clear-on-lock already covers macOS).
- Modified: `KeeForge/Services/AppSupport/ReviewPromptService.swift` — StoreKit `RequestReviewAction`/`AppStore.requestReview` on macOS (guard so it no-ops in the slice-07 Developer ID build).
- Modified: `KeeForge/Services/AppSupport/FaviconService.swift` — on macOS, store the favicon disk cache in the app's own sandbox container, NOT the App Group container (it's a plaintext domain fingerprint of the vault, user-world-readable on macOS 14). iOS keeps the group container (the AutoFill extension reads it there). If the mac AutoFill extension needs favicons, it renders without them or re-fetches — do not widen the group-container exposure.
- New: `docs/macos-security-notes.md` — the honest deltas: in-memory model unchanged; group-container readability on macOS 14; clipboard/Universal Clipboard ceiling; screen capture best-effort on 15+; attachment previews rely on FileVault (iOS Data Protection inert); non-T2 Intel hibernation caveat; what is not fixable at app level (AX/Screen-Recording-granted malware, admin memory dumps, Swift String zeroization).
- Modified: `README.md` — Highlights row for screen protection reworded to describe the per-platform behavior truthfully.

## KeeForge bits

- **Targets:** all modified services/views keep existing memberships + KeeForgeMac. `FaviconService.swift` is in the AutoFill allow-list — its mac cache-path branch must stay extension-safe. New doc: no target.
- **project.yml:** no changes expected. Run `xcodegen generate` only if a file is added/moved.
- **Accessibility identifiers:** new `settings.block-screen-capture.toggle`; existing attachment identifiers (`entry.attachments.*`) preserved through the QuickLook change — `EntryAttachmentsSmokeUITests` (iOS) must still pass if iOS migrates to the modifier.

## Testing

- **Unit:** `FaviconServiceTests.swift` (34 tests) — extend: mac cache path resolves inside the app sandbox container, not the group container; iOS path unchanged. `SettingsServiceTests.swift` — capture-block toggle round-trips, default on. `ReviewPromptServiceTests.swift` (10 tests) — pass on `KeeForgeMacTests` with the mac API branch.
  Run slice: `-only-testing:KeeForgeMacTests/FaviconServiceTests -only-testing:KeeForgeMacTests/SettingsServiceTests -only-testing:KeeForgeMacTests/ReviewPromptServiceTests`.
- **Integration / UI:** one mac smoke test: toggling block-screen-capture persists across relaunch. QuickLook open/close smoke on mac (and keep the iOS attachment smoke green).
- **Manual:**
  - ⇧⌘4 a vault window with the toggle on → window excluded/blacked out on macOS 14; on a macOS 15+ machine, verify and record the actual behavior (expected: capture succeeds — the honest-copy case).
  - Blur cover appears when the app loses focus and lifts on return, on both toggle states.
  - QuickLook preview of an image and a PDF attachment; preview files gone after lock.
  - Favicon cache location on disk verified on both platforms.
- **Edge cases that apply:** multiple windows (pop-out/Settings) under the toggle, toggle flipped while windows open (applies immediately), locked DB (blur irrelevant, attachments cleared), attachment preview open when lock fires.

## Exit criteria

- [ ] Unit + smoke tests above pass; iOS suite green.
- [ ] Manual checks done, incl. the recorded macOS 15+ capture behavior.
- [ ] No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] `xcodegen generate` if needed; `docs/README.md` lists the new security note; `KeeForge/Services/README.md` updated for the favicon cache split.
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- macOS: screen-privacy protections (blur on focus loss, optional screen-capture blocking), attachment Quick Look, and App Store review prompts.`
