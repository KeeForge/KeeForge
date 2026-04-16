# App Support Services

This folder holds app-scoped helpers that support UI behavior and secondary product surfaces.

## Main Files

- `SettingsService.swift` decides what is local-only versus App Group-shared with the extension.
- `StoreKitManager.swift` and `ReviewPromptService.swift` support monetization and review prompts.
- `ClipboardService.swift` and `HapticService.swift` wrap small device APIs used across the UI.
- `FaviconService.swift` fetches and caches site icons used in list and detail views.

## Change Carefully

- Even the lighter-weight helpers here can affect user-facing polish, test behavior, and extension-shared settings state.
