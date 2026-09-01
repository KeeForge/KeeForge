# Components Views

Reusable controls shared across the feature folders.

## Screen Map

- `FaviconView.swift` renders an entry's icon: a custom `Meta/CustomIcons` image, a cached/fetched favicon, or the standard-icon glyph fallback. The fallback's colour is keyed to `backgroundProminence` — accent normally, white when it sits on a selected row's accent fill, which is the one case `.tint` would otherwise render accent-on-accent.
- `PasswordInputRow.swift` owns editable password entry controls shared by master-password creation and entry editing; `usesPasswordAutoFill` (default on) drives both `textContentType` applications — the row's own and `passwordInputStyle(contentType:)`'s — so a row holding a non-password can turn password AutoFill off entirely. `PasswordDisplay.swift` owns read-only password reveal/display rows plus strength indicators. `EntryDetailView.swift`'s `ProtectedFieldRow` masks custom fields whose key is in `KPEntry.protectedStringKeys`, gates reveal and copy behind device-owner authentication, and is shared with the history viewer; identifiers `entry.copy.<normalized-key>` / `entry-history.copy.<normalized-key>` and `entry.protected-field.<normalized-key>.reveal` / `entry-history.protected-field.<normalized-key>.reveal`.
- `ReadOnlyIndicator.swift` is the toolbar status for a database that cannot be edited, shared by the compact group list, the entry detail (iOS only — macOS states it once in the window toolbar the workspace owns), and the macOS workspace toolbar. Identifier `database.read-only-indicator`.

Shared UI shells and the folder-wide UI rules live in `../README.md`.
