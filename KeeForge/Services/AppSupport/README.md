# App Support Services

This folder holds app-scoped helpers that support UI behavior and secondary product surfaces.

## Main Files

- `SettingsService.swift` decides what is local-only versus App Group-shared with the extension. It also owns `MacLockPolicy` and documents how the iOS lock-on-background default maps to the macOS screen-lock/sleep/screensaver/session-resign triggers.
- `MacLockMonitor.swift` (KeeForgeMac target only) observes the system notifications that make up the macOS auto-lock guarantee (distributed screen-lock/screensaver, workspace sleep/session-resign, app deactivation under the strict policy) and drives the existing lock/became-active paths. Notification centers are injected for unit testing (`KeeForgeTests/MacLockMonitorTests.swift`).
- `StoreKitManager.swift` and `ReviewPromptService.swift` support monetization and review prompts.
- `AutoFillStatusService.swift` reports whether KeeForge is enabled as the system AutoFill provider, deep-links/one-tap-enables it via `ASSettingsHelper`, and owns the "enable AutoFill" tip dismissal flag. Main-app only; UI tests suppress the tip unless `UI_TEST_SHOW_AUTOFILL_TIP=1`.
- `ClipboardService.swift` and `HapticService.swift` wrap small device APIs used across the UI. On macOS the clipboard applies the `org.nspasteboard.ConcealedType` marker, a changeCount-guarded clear timer, and clear-on-lock; there is no Universal Clipboard exclusion on macOS (documented in Settings).
- `FaviconService.swift` fetches and caches site icons used in list and detail views. The favicon cache is a plaintext per-domain fingerprint of the vault, so its disk location is platform-split: **iOS** keeps it in the App Group container (the AutoFill extension reads it there), while **macOS** stores it in the app's own sandbox container (Application Support), because the App Group container is world-readable to the user's other processes on macOS 14. The mac cache-path branch must stay extension-safe (`FaviconService` is in the AutoFill allow-list). See `../../../docs/macos-security-notes.md`.
- `ReviewPromptService.swift` gates the App Store review prompt. iOS keeps the scene-based `SKStoreReviewController` path; macOS has no scene-based entry point, so the app injects SwiftUI's `RequestReviewAction` via `requestReviewHandler` (`SKStoreReviewController.requestReview()` is deprecated on macOS 15). `isAppStoreBuild` is the hook slice 07's Developer ID build flips to no-op the prompt.

## Change Carefully

- Even the lighter-weight helpers here can affect user-facing polish, test behavior, and extension-shared settings state.
