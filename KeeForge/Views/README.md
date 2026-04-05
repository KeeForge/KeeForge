# Views Folder

This folder contains the SwiftUI screens for both the database-list flow and the unlocked-database flow.

## Screen Map

- `DatabaseListView.swift`, `DatabaseRowView.swift`, and `CloudFileBrowserView.swift` own database picking, cloud browsing, rename/remove actions, and settings entry points.
- `UnlockView.swift` owns password/key-file entry and biometric affordances for one database.
- `GroupListView.swift`, `EntryListView.swift`, `EntryDetailView.swift`, and `SearchView.swift` own post-unlock navigation.
- `SettingsView.swift`, `AcknowledgmentsView.swift`, and `TipJarView.swift` own secondary settings and support surfaces.
- `FaviconView.swift` is a reusable async image wrapper used by list and detail UIs.

## UI Rules

- Keep business logic in view models and services; views should compose state, trigger intents, and manage local presentation state only.
- Preserve existing accessibility identifiers on major controls. If you add a new flow that needs automation, add identifiers as part of the feature instead of relying on visible labels.
- When changing navigation or sheet structure, rerun the smallest affected UI test class from `../../KeeForgeUITests/README.md`.
- If a view starts needing substantial async or state logic, prefer extracting a helper type or moving the logic into a view model rather than growing one monolithic view file.
