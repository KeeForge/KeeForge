# Views Folder

This folder contains the SwiftUI screens for both supported app UIs: the compact iPhone-style flow and the regular-width iPad workspace. Most feature screens are shared across those presentations, so view changes should account for both shells rather than assuming a single navigation structure.

## Supported UI Shells

- Compact UI: iPhone-sized layouts push from the database list into one active unlock or database session at a time.
- Regular-width UI: iPad layouts keep the database list visible while the selected unlock or database session renders in a dedicated detail workspace.
- Treat both shells as first-class product surfaces. If a feature adds navigation, chrome, editing, or status UI, verify how it lands in both presentations.

## Screen Map

- `DatabaseListView.swift`, `DatabaseRowView.swift`, the in-file `DatabaseDetailsView`, and `CloudFileBrowserView.swift` own database picking, cloud browsing UI, rename/remove actions, read-only toggles and badges, pending-upload badges/conflict copy, "Push pending changes" actions, and settings entry points. `CloudFileBrowserView.swift` presents `WebDAVConnectView` in place of hosted OAuth for providers that use a manual connection form.
- `WebDAVConnectView.swift` owns the manual WebDAV connect sheet (server address, username, password with `PasswordInputRow`, advanced unencrypted-HTTP opt-in, inline error, Connect/Cancel), backed by `WebDAVConnectViewModel`.
- `DatabaseCreationView.swift` owns local and cloud database creation, including master-key input, key-file selection, destination choice, and handoff to Files export or provider folder picking.
- `UnlockView.swift` owns password/key-file entry and biometric affordances for one database.
- `GroupListView.swift`, `EntryListView.swift`, `EntryDetailView.swift`, and `SearchView.swift` own post-unlock navigation, entry/group creation and deletion affordances, detail presentation, and the global read-only + unsaved-change surfaces shown while a database is open.
- `AttachmentsSection.swift` (used by `EntryDetailView.swift`) owns the read-only entry-attachment list: paperclip rows resolved lazily via `DatabaseViewModel.attachmentData(for:)`, byte-size formatting, dangling-ref rows disabled and marked unavailable, and QuickLook preview/share backed by `AttachmentPreviewFileStore` temp files. `AttachmentQuickLookPreview.swift` is the `QLPreviewController` SwiftUI wrapper it presents in a sheet.
- `EntryEditView.swift`, `PasswordGeneratorSheet.swift`, and `SaveConflictAlert.swift` own entry form editing, password generation, discard confirmation, and the save-conflict alert choices surfaced from `DatabaseViewModel`.
- `PasswordInputRow.swift` owns editable password entry controls shared by master-password creation and entry editing; `PasswordDisplay.swift` owns read-only password reveal/display rows plus strength indicators.
- `SettingsView.swift`, `AcknowledgmentsView.swift`, and `TipJarView.swift` own secondary settings and support surfaces.
- `FaviconView.swift` is a reusable async image wrapper used by list and detail UIs.

## UI Rules

- Keep business logic in view models and services; views should compose state, trigger intents, and manage local presentation state only.
- Keep compact and regular-width layouts behaviorally aligned. If a screen gains iPad-specific presentation, prefer sharing the same core row/detail/editor views instead of forking the feature, and call out any intentional divergence in the local docs.
- Preserve existing accessibility identifiers on major controls. If you add a new flow that needs automation, add identifiers as part of the feature instead of relying on visible labels.
- The database list now exposes `database-row.pending-uploads-badge` and `database-row.push-pending-action`; keep those stable unless the matching tests are updated with the change.
- Entry detail exposes `entry.attachment.<index>` (per-row button, e.g. `entry.attachment.0`) and `entry.attachment.share` for the read-only attachments list; keep those stable unless the matching tests are updated with the change. Tests enumerate rows via the `entry.attachment.<index>` prefix rather than a shared row identifier, since SwiftUI collapses each row into one accessibility element.
- Keep entry-form state local to `EntryEditViewModel`, but keep draft/save orchestration, conflict handling, and lock/discard decisions in `../ViewModels/DatabaseViewModel.swift`.
- When changing navigation, split-view behavior, or sheet structure, rerun the smallest affected UI test class from `../../KeeForgeUITests/README.md`.
- If a view starts needing substantial async or state logic, prefer extracting a helper type or moving the logic into `../ViewModels` rather than growing one monolithic view file.
