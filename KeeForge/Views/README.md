# Views Folder

This folder contains the SwiftUI screens for all supported app UIs: the compact iPhone-style flow, the regular-width iPad workspace, and the macOS app. Most feature screens are shared across those presentations, so account for every shell rather than assuming a single navigation structure.

## Supported UI Shells

- Compact UI: iPhone-sized layouts push from the database list into one active unlock or database session at a time.
- Regular-width UI: iPad layouts keep the database list visible while the selected unlock or database session renders in a dedicated detail workspace.
- macOS app: the `KeeForgeMac` target compiles this entire folder and always uses the regular (split-view) layout; it has its own `KeeForgeMacTests` and `KeeForgeMacUITests` targets.
- Treat all three shells as first-class product surfaces. If a feature adds navigation, chrome, editing, or status UI, verify how it lands in each presentation.

## Folder Map

Each subfolder owns one feature area and carries its own screen map.

| Folder | Owns |
| --- | --- |
| `DatabaseList/` | Database picking, creation, per-database settings, master-key changes, export to Files |
| `Unlock/` | Password and key-file entry, biometric affordances |
| `Group/` | Post-unlock group navigation, group editor, group icon and move-destination pickers |
| `Entry/` | Entry detail, editing, history, attachments, icon selection, shared row actions |
| `SearchAndTags/` | Search results and the tag browser |
| `TOTP/` | QR scanning and the incoming `otpauth://` destination picker |
| `Cloud/` | Cloud provider file browsing and the manual WebDAV connect form |
| `Settings/` | App settings, release education, support surfaces, DEBUG-only developer tooling |
| `Components/` | Reusable controls shared across the feature folders |

## UI Rules

- Keep business logic in view models and services; views should compose state, trigger intents, and manage local presentation state only.
- Keep compact and regular-width layouts behaviorally aligned. If a screen gains iPad-specific presentation, prefer sharing the same core row/detail/editor views instead of forking the feature, and call out any intentional divergence in the local docs.
- Preserve existing accessibility identifiers on major controls, for both suites — `KeeForgeMacUITests` reuses the same identifiers as `KeeForgeUITests`. If a new flow needs automation, add identifiers as part of the feature instead of relying on visible labels. Identifier *stability* is not element-type stability: the macOS vault columns are `List(selection:)` rows, so `group.navlink` / `entry.navlink` land on cells there and on buttons on iOS. Mac tests must query them with `descendants(matching: .any)` (`MacUITestCase.rowQuery`), never `app.buttons`.
- Any `Form` shown in a macOS sheet needs `.macGroupedForm()`, not just the two editors above: the default `.columns` style does not scroll, so a form taller than its sheet overflows instead, and the rows past the sheet's top and bottom edges are clipped where no click can reach them — only Tab gets there. The sheeted forms are `EntryEditView`, `GroupEditView`, `DatabaseDetailsView`, `MasterKeyChangeView`, `WebDAVConnectView`, and `FeedbackComposerView`; a new one joins that list. Rows in a grouped form also need `.macFormFieldStyle()` on their text fields (grouped draws them borderless) and `.macLabelsHidden()` wherever a caption above the row — or the section header — already names the field.
- Icon-only controls carry both an `accessibilityLabel` and `.macHelp(...)` (the macOS-only tooltip shim in `../Extensions/PlatformCompat.swift`), passing the same text. Do not reach for plain `.help()`: on iOS it becomes the VoiceOver hint and would change what an already-labelled control reads out.
- Stable identifiers with no current UI-test references — still part of the identifier surface `AGENTS.md` requires preserving, so keep them stable and add coverage when touching their flows: `database-row.pending-uploads-badge` and `database-row.push-pending-action` (database list), `entry-row.expired` (red warning indicator in group and search lists), `entry-detail.expired-warning` and `entry-detail.expiry` (expired entries and enabled expiration timestamps in entry detail), and `autofill.entry.expired` (AutoFill's interactive picker, expired credentials requiring explicit selection). Folder captions (`entry-row.folder`), group exclusion (`group-row.autofill-exclusion-context` / `group-row.autofill-excluded`), and the group icon picker (`group-row.change-icon-context`, `group-icon-picker.cancel`, `group-icon-picker.icon.<iconID>`) have focused UI coverage.
- The group editor's identifier surface, shared by both shells (the iOS/iPad row menu and the macOS sidebar row menu use the same `group-row.edit-context`): `group-row.edit-context` (context-menu entry point), `group-edit.name-field`, `group-edit.icon-button`, `group-edit.tags` / `group-edit.tag.<normalized-tag>` (applied pills, `TagAccessibility` suffixes), `group-edit.tags-field`, `group-edit.tag-suggestions` / `group-edit.tag-suggestion.<normalized-tag>`, `group-edit.notes-field`, `group-edit.keyboard-done`, `group-edit.autofill-toggle`, `group-edit.cancel`, `group-edit.save`, and `group-edit.saving-overlay`. `GroupEditUITests` drives the entry point, name, icon, applied/typed tags, notes, AutoFill toggle, cancel, and save controls; the suggestion strip and transient saving overlay have no direct test references. Keep all identifiers stable.
- A `ForEach` with `.onMove` has to produce one concrete row type. Branching with `if`/`else` inside its body gives the list two row types to reconcile, and a drag reorder then repaints the old order until something unrelated invalidates the list — the database list's `DatabaseRowChrome` moves that branch into a `ViewModifier` for exactly this reason.
- Entry detail's header title carries `entry-detail.title` (a leaf `Text`), which is how the macOS keyboard-navigation tests read which entry the detail column is showing. Keep it stable.
- Entry detail exposes `entry.attachment.<index>` (per-row button, e.g. `entry.attachment.0`) and `entry.attachment.share` for the read-only attachments list; keep those stable unless the matching tests are updated with the change. Tests enumerate rows via the `entry.attachment.<index>` prefix rather than a shared row identifier, since SwiftUI collapses each row into one accessibility element.
- Keep entry-form state local to `EntryEditViewModel`, but keep draft/save orchestration, conflict handling, and lock/discard decisions in `../ViewModels/DatabaseViewModel.swift`.
- When changing navigation, split-view behavior, or sheet structure, rerun the smallest affected UI test class from `../../KeeForgeUITests/README.md`.
- If a view starts needing substantial async or state logic, prefer extracting a helper type or moving the logic into `../ViewModels` rather than growing one monolithic view file.
