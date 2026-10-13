# Components Views

**Scope:** small controls shared across feature folders: icons, password rows, the generator sheet, summary rows, tip cards, and the read-only indicator. Folder-wide UI rules are in `../AGENTS.md`.

## Invariants

- `PasswordDisplay.swift`, `PasswordInputRow.swift`, and `StandardIconView.swift` also compile into both AutoFill extension targets (`project.yml`). Keep them free of app-only types.
- `StandardIconView` is the single renderer for the KDBX standard icons, in the app and the extension. Custom database icons and favicons keep their own colors.
- `GroupIconView` renders group icons in both app shells: a decodable custom image takes precedence over the standard icon. The Mac sidebar supplies no custom image for the recycle bin.
- `PasswordInputRow(usesPasswordAutoFill: false)` is for a row that only looks like a password (a TOTP setup key). The flag drives both `textContentType` applications; leaving it on lets QuickType offer to replace the value with a generated password.
- A revealed password is never selectable; see "Secrets on screen" in `../AGENTS.md`.
- `PasswordGeneratorSheet` refuses to turn off the last character set, matching `PasswordGenerator`, which would silently re-enable lowercase. `password-generator.password` sits on the plaintext leaf only, not on the row's controls.
- `FaviconLoadModel` clears the previous image when the domain changes and ignores stale or cancelled responses, so a reused row never shows another entry's icon.
- `SettingsSummaryRow` is a label only. The caller wraps it in the `NavigationLink` and owns the identifier.
- `tipBannerCard()` carries no identifier; a container identifier would replace the buttons' own.
- `ReadOnlyIndicator` appears in entry detail on iOS only. On macOS the detail toolbar merges into the window toolbar, which already shows it.

## Tests

- `FaviconLoadModelTests`, `SettingsSummaryRowTests` (line limit at accessibility sizes).
- `GroupIconViewTests` renders custom images and standard fallbacks, including selected-row colors.

## See also

- `../AGENTS.md`, `../../../AutoFillExtension/AGENTS.md`
