# Views Folder

This folder contains the SwiftUI screens for both the database-list flow and the unlocked-database flow.

## Screen Map

- `DatabaseListView.swift`, `DatabaseRowView.swift`, the in-file `DatabaseDetailsView`, and `CloudFileBrowserView.swift` own database picking, cloud browsing UI, rename/remove actions, read-only toggles and badges, pending-upload badges/conflict copy, "Push pending changes" actions, settings entry points, and the Dropbox write-scope reconnect banner shown after the cloud-save upgrade.
- `UnlockView.swift` owns password/key-file entry and biometric affordances for one database.
- `GroupListView.swift`, `EntryListView.swift`, `EntryDetailView.swift`, and `SearchView.swift` own post-unlock navigation, entry creation/deletion affordances, and the global read-only + unsaved-change surfaces shown while a database is open.
- `EntryEditView.swift`, `PasswordGeneratorSheet.swift`, and `SaveConflictAlert.swift` own entry form editing, password generation, discard confirmation, and the save-conflict alert choices surfaced from `DatabaseViewModel`.
- `SettingsView.swift`, `AcknowledgmentsView.swift`, and `TipJarView.swift` own secondary settings and support surfaces.
- `FaviconView.swift` is a reusable async image wrapper used by list and detail UIs.

## UI Rules

- Keep business logic in view models and services; views should compose state, trigger intents, and manage local presentation state only.
- Preserve existing accessibility identifiers on major controls. If you add a new flow that needs automation, add identifiers as part of the feature instead of relying on visible labels.
- The database list now exposes `database-row.pending-uploads-badge` and `database-row.push-pending-action`; keep those stable unless the matching tests are updated with the change.
- Keep entry-form state local to `EntryEditViewModel`, but keep draft/save orchestration, conflict handling, and lock/discard decisions in `../ViewModels/DatabaseViewModel.swift`.
- When changing navigation or sheet structure, rerun the smallest affected UI test class from `../../KeeForgeUITests/README.md`.
- If a view starts needing substantial async or state logic, prefer extracting a helper type or moving the logic into `../ViewModels` rather than growing one monolithic view file.
