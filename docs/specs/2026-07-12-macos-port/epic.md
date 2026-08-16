# Epic: Native macOS App

## Summary

Ship KeeForge as a native macOS app (SwiftUI multiplatform, macOS 14+) sharing the existing iOS codebase through `#if os()` seams — not Mac Catalyst, not a separate AppKit codebase. Closes the "Major gap" vs. Strongbox/KeePassium identified in `docs/analysis/2026-04-18-competitive-gap-analysis.md` and the unstarted ROADMAP item.

Why this approach: only 13 of ~70 app source files touch UIKit (mostly 1–5 line touches); all Views are pure SwiftUI on `NavigationStack`/`NavigationSplitView`; the entire Models layer, WebDAV stack, ViewModels, and all three SPM dependencies (Argon2Swift, SwiftyDropbox, MSAL) compile for macOS today. Catalyst's value is reusing UIKit code, which KeeForge barely has — and KeePassium's Catalyst experience ("80% in days, the remaining 20% took 3+ years and 127 betas") is the cautionary tale. A separate AppKit app (Strongbox's model) doubles UI maintenance forever.

Full scoping context (portability audit, competitor research, security review) is summarized per-slice; effort estimate for the whole epic is 28–49 person-days.

## Clarified requirements

- **Q:** Minimum macOS version?
  **A:** macOS 14 (Sonoma) — the API generation matching the iOS 17 floor (`@Observable`, passkey-capable AutoFill providers).
- **Q:** Should the macOS AutoFill extension ship in v1 or as a fast-follow?
  **A:** In v1.
- **Q:** Distribution channel?
  **A:** Mac App Store **and** notarized Developer ID direct download. Both builds stay sandboxed. Bundle ID `com.keevault.app` is shared with iOS for universal purchase.
- **Q:** Screen-capture protection stance (iOS's `UIScreen.isCaptured` shield has no macOS equivalent)?
  **A:** User asked what competitors do. Research: Strongbox ships an opt-in "Block screenshots" toggle via `NSWindow.sharingType`; KeePassium has no capture protection and locks on Mac screen-lock instead; Bitwarden blocks by default; on macOS 15+ ScreenCaptureKit ignores `sharingType` (legacy). Decision: layered — deterministic lock-on-screen-lock/sleep + blur-on-resign-active, plus a best-effort "Block screen capture" toggle (default on), documented honestly.
- **Q:** Does the in-memory encryption model survive the port?
  **A:** Yes, unchanged — `EncryptedValue`/session-key code is pure Foundation/CryptoKit. A dedicated security review added port-critical items now baked into slices: Hardened Runtime from day one (slice 01), the reveal-auth fix for non-Touch-ID Macs (slice 02), App Group container guardrails (slices 01/06), and honest clipboard-regression documentation (slice 02).

## Stable Core Impact

`None.` The Models layer (`KDBXParser.swift`, `KDBXWriter.swift`, `KDBXCrypto.swift`, `DatabaseDraft.swift`, `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, `TOTPGenerator.swift`) is already platform-neutral and compiles for macOS with zero changes. All `#if os()` seams live in Services, ViewModels, Views, App, and AutoFillExtension. Any slice that discovers it needs a stable-core change must stop and re-justify here first.

## Slice plan

| # | Slice | File | Depends on |
|---|-------|------|------------|
| 01 | macOS target scaffolding + compile + unit tests green | `01-macos-target-scaffolding.md` | — |
| 02 | Core Mac UX (commands, settings, lock lifecycle, view polish) | `02-core-mac-ux.md` | 01 |
| 03 | Cloud OAuth on desktop (Dropbox + OneDrive) | `03-cloud-oauth-desktop.md` | 01 |
| 04 | CredentialProvider refactor (iOS-only, no Mac dependency) | `04-credential-provider-refactor.md` | — |
| 05 | macOS AutoFill extension | `05-macos-autofill-extension.md` | 01, 04 |
| 06 | Mac security polish (screen privacy, QuickLook, favicon cache) | `06-mac-security-polish.md` | 02 |
| 07 | Distribution (MAS + Developer ID + Sparkle) | `07-distribution.md` | 02 (all for release) |

Why this split: each slice compiles and tests on its own. 01 retires the fork-in-the-road risks (provisioning, sandbox, keychain) before any UI work. 04 lands on iOS alone, verified by the ~100 existing AutoFill unit tests, and can run in parallel with 01–03. 07 is pure release engineering. Fewer slices would couple the AutoFill refactor to Mac work it doesn't need; more would split things that always land together (e.g., commands + settings + lock lifecycle are one coherent "Mac app shell" review).

## Cross-slice notes

- **Platform seams:** prefer one shared `PlatformCompat.swift` shim (slice 01) over scattering raw `#if os()` in views; raw conditionals are fine in Services where behavior genuinely diverges.
- **Targets:** new `KeeForgeMac`, `KeeForgeMacTests`, `KeeForgeMacAutoFill`, `KeeForgeMacUITests` — separate explicit XcodeGen targets, NOT `supportedDestinations` (keeps the shipping iOS target, schemes, Xcode Cloud, and the `release` skill byte-identical). Bundle IDs: `com.keevault.app` / `com.keevault.app.autofill` shared with iOS.
- **Hardened Runtime:** `ENABLE_HARDENED_RUNTIME: YES` on both Mac product targets from slice 01, with zero `com.apple.security.cs.*` exception entitlements — ever. Sparkle 2 (SPM), MSAL, and SwiftyDropbox need none.
- **App Group:** `group.com.keevault.shared` is user-world-readable on macOS 14 (unlike iOS). Standing guardrail: only encrypted KDBX bytes, bookmarks, and filenames may be written there — never key material.
- **iOS stays green:** every slice must leave `KeeForgeTests` passing and the iOS app behavior unchanged (except the reveal-auth back-port in slice 02, which is an intentional iOS security improvement).
- **Session secrets:** all new code paths that read decrypted secrets go through `EncryptedValue` + the session key, same as iOS. No new plaintext retention.

## Out of scope

- Mac Catalyst or a separate AppKit codebase (decided against).
- `mlock`/zeroizing `SecureBytes`-style buffer type (KeePassium parity) — backlog; the session-key model already leads the field.
- Native-messaging browser extension for Chrome/Firefox (Strongbox/KeePassXC pattern) and SSH agent — future epics if ever.
- `MenuBarExtra` quick search, dock menu, Services menu — optional delighters, only if slice 06's timebox allows.
- macOS 26-only visual adoption (Liquid Glass tuning) beyond what a recompile provides.
- Camera/QR TOTP provisioning (doesn't exist on iOS either).
