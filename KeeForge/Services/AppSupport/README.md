# App Support Services

This folder holds app-scoped helpers that support UI behavior and secondary product surfaces.

## Main Files

- `SettingsService.swift` decides what is local-only versus App Group-shared with the extension.
- `StoreKitManager.swift` and `ReviewPromptService.swift` support monetization and review prompts.
- `AutoFillStatusService.swift` reports whether KeeForge is enabled as the system AutoFill provider, deep-links/one-tap-enables it via `ASSettingsHelper`, and owns the "enable AutoFill" tip dismissal flag. Main-app only; UI tests suppress the tip unless `UI_TEST_SHOW_AUTOFILL_TIP=1`.
- `ClipboardService.swift` and `HapticService.swift` wrap small device APIs used across the UI.
- `FaviconService.swift` fetches and caches site icons used in list and detail views.

## Change Carefully

- Even the lighter-weight helpers here can affect user-facing polish, test behavior, and extension-shared settings state.
