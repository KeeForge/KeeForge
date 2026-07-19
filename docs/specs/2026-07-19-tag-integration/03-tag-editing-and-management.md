# Slice 03: Tag Editing and Management

> Parent: [`epic.md`](./epic.md) · Depends on: 01, 02

## Goal

Close the write side: existing-tag suggestions while editing an entry, and database-wide tag
rename and delete from the tag browser — without ever decrypting a secret.

## Scope

**In:**

- **Editor suggestions:** in `EntryEditView`, below the existing free-text tags field, show
  the database's existing tags (from slice 01's index) that the entry doesn't already carry;
  tapping one appends it. Free-text entry stays; suggestions are an accelerator, not a
  replacement. Suggestions are exact strings — a differently-cased variant is a separate
  suggestion, and choosing it adds that exact casing.
- **Tags-only draft edit (stable core):** a new `EntryEdit` case for replacing an entry's
  tag list, applied by `DatabaseDraft` by copying the original entry with only `tags`,
  `hasTagsElement`, and `lastModificationTime` changed, plus the standard trimmed history
  snapshot of the pre-edit state. Every other property — the encrypted password, TOTP
  config, passkey, custom fields and their protection keys, attachments, icon, times,
  unknown XML — is carried over untouched. No `EncryptedValue` is decrypted or re-encrypted.
  `hasTagsElement` keeps its existing semantics: once true, an emptied tag list still writes
  an empty `<Tags>` element.
- **Rename:** from the tag list screen (context menu and swipe action), prompt for a new
  name. Validation: normalize per slice 01; reject empty results and input containing `,`
  or `;` with a clear message; treat an unchanged name as cancel. Renaming to an existing
  tag is a merge — the confirmation copy must say so and show both names. Case-only renames
  (`work` → `Work`) are real renames, not no-ops. The rename applies to every carrying
  entry, including entries in the recycle bin, inserting the new name at the old name's
  position per entry and deduping if the entry already carried the target.
- **Delete:** from the same menus, with a confirmation dialog naming the tag and the number
  of affected entries. Removes the exact tag string from every carrying entry, including
  recycled ones.
- **Atomicity:** rename/delete build one working draft (chained tags-only edits over all
  affected entries), then one `save()` — one SHA-512 conflict check, one backup, one
  AutoFill cache refresh. Any per-entry failure aborts the whole operation with no partial
  write. The tag index and open screens refresh after the save like any other edit.
- **Read-only databases:** suggestions appear only where editing is already possible;
  rename/delete affordances are absent in read-only mode (KDBX 3.1 et al.).

**Out:**

- Rewriting tags inside history snapshots (never — epic decision; old names remain visible
  in entry history).
- Bulk tagging of multi-selected entries; tag creation from the tag list (tags exist only
  by being on an entry — an unused tag cannot exist in KDBX).
- Merge-conflict UX beyond the existing save pipeline's behavior.

## Implementation requirements

- The tags-only edit is the only new write primitive; rename and delete are orchestrated in
  `DatabaseViewModel` as sequences of that edit against a single working draft (the
  established `makeWorkingDraft().apply(…)` chain), not as a new bulk draft operation.
- The orchestration must look up carriers via the database tree (all entries, including
  recycled — slice 01's index excludes recycled entries, so it must not be the source of
  truth for rename/delete targets).
- Modification-time semantics match a normal edit; entries not carrying the tag are
  untouched (no timestamp churn, no history growth).
- Suggestion list: sorted like the tag browser, excludes tags already on the entry
  (live-updating as the user adds/removes), and — being derived from the recycled-excluding
  index — will simply not suggest recycle-bin-only tags. That asymmetry with rename/delete
  reach is deliberate and must be covered by a test, not "fixed".
- Deleting the last tag of an entry that had a `<Tags>` element keeps the empty element
  (existing round-trip behavior, already regression-tested).
- Per `AGENTS.md`, changed edit operations require compatibility coverage: extend
  `KDBXCompatibilitySupport`'s mutation matrix with tag rename (including a merge) and tag
  delete, asserting KeePassXC opens the result with the expected tags via the existing
  artifact gate.
- Dialog copy, menu labels, and validation messages localized in `en` and `de`.

## Affected areas

- New: none required (implementer may add a small view for the suggestion chips).
- Modified: `KeeForge/Models/EntryEdit.swift`, `KeeForge/Models/DatabaseDraft.swift`
  (stable core — see epic justification), `KeeForge/ViewModels/DatabaseViewModel.swift`
  (orchestration), `KeeForge/ViewModels/EntryEditViewModel.swift` (suggestions),
  `KeeForge/Views/EntryEditView.swift`, the slice 02 tag list screen (menus/dialogs),
  `KeeForge/Resources/Localizable.xcstrings`, `KeeForgeTests/KDBXCompatibilitySupport.swift`.

## KeeForge bits

- **Targets:** `EntryEdit.swift` / `DatabaseDraft.swift` are shared — membership spans the
  main app and both AutoFill targets exactly as today (no membership changes; keep the new
  case extension-safe). All UI/view-model changes are `KeeForge` app target only.
- **project.yml:** no changes unless a suggestion-chip view file is added; if so, add it to
  the `KeeForge` target and run `xcodegen generate`.
- **Accessibility identifiers:** new — suggestion chips (stable per-tag suffix, matching
  slice 02's convention), rename/delete menu items, and the rename prompt's text field and
  confirm buttons. `entry-edit.tags-field` and all slice 02 identifiers preserved.
- **CHANGELOG entry:** final epic entry, below.

## Testing

- **Unit:** `DatabaseDraftTests.swift` — named scenarios for the tags-only edit: password
  ciphertext bytes identical before/after (assert on the stored `EncryptedValue`, proving
  no re-encryption); passkey, TOTP, custom-field protection keys, attachments, and unknown
  XML preserved; history gains exactly one snapshot holding the pre-edit tags and respects
  the existing trim limits; `hasTagsElement` retained when emptying; editing a missing
  entry ID throws; recycled entries are editable through it.
- **Unit:** `DatabaseViewModelTests.swift` — rename across live + recycled carriers in one
  draft/save; rename-to-existing merges without duplicates and collapses counts; case-only
  rename; delete removes the tag everywhere and the browser index reflects it; a failing
  entry aborts atomically leaving the database unchanged; read-only databases expose no
  rename/delete.
- **Unit:** `EntryEditViewModelTests.swift` — suggestions exclude already-carried tags,
  update as tags are added/removed, use exact casing, and exclude recycle-bin-only tags.
- **Compatibility:** `KDBXCompatibilityTests.swift` via `KDBXCompatibilitySupport.swift` —
  rename, merge-rename, and delete mutations round-trip and pass the KeePassXC artifact
  gate.
  Run slice: `-only-testing:KeeForgeTests/DatabaseDraftTests -only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/EntryEditViewModelTests -only-testing:KeeForgeTests/KDBXCompatibilityTests -only-testing:KeeForgeTests/LocalizationTests`
- **Integration / UI:** N/A — dialogs and menus are covered by unit tests plus manual; the
  slice 02 UI test keeps covering navigation.
- **Manual:** rename a tag carried by live + recycled entries and verify both changed and
  history kept the old name; merge two case-variant tags; delete a tag and confirm the
  empty `<Tags>` element survives in another app; verify one backup file per operation;
  confirm a KDBX 3.1 database shows no management UI.
- **Edge cases that apply:** merge dedupe, case-only rename, recycled carriers, separator
  characters in rename input, unchanged-name cancel, large databases (hundreds of carriers
  in one draft), locked DB mid-dialog (lock wins; dialog state discarded), save conflict via
  the existing pipeline.

## Exit criteria

- [ ] All unit, compatibility, and localization tests above pass.
- [ ] Manual checks done, including the cross-app verification.
- [ ] Stable-core change is limited to the tags-only edit; no secret is decrypted anywhere
      in rename/delete (proven by the ciphertext-identity test).
- [ ] No force unwraps; heavy work off main; one save/backup per operation.
- [ ] Accessibility identifiers added; existing ones untouched.
- [ ] `xcodegen generate` run if `project.yml` changed.
- [ ] CHANGELOG final entry replaces slice 02's.

## CHANGELOG entry

`- Added a tag browser: browse entries by tag, search by tag, tag suggestions while editing, and database-wide tag rename and delete.`
