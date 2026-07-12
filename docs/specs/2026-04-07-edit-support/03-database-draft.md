# Slice 03: DatabaseDraft + typed edit operations

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

Add a `DatabaseDraft` value that wraps an opened tree and lets callers apply typed `EntryEdit` operations (`createEntry`, `updateEntry`, `deleteEntry`) to produce a new tree without rewriting the parser. The draft tracks "is dirty", re-encrypts secrets via `EncryptedValue` on every mutation, and exposes its operation log so slice 07 can persist a Codable copy to App Group storage. No file I/O, no network, no UI — this slice is purely an in-memory model layer with deep test coverage.

## Scope

**In:**

- `EntryEdit` enum (Codable, Sendable, Equatable):
  - `createEntry(parentGroupID: UUID, draft: EntryDraftPayload)`
  - `updateEntry(entryID: UUID, draft: EntryDraftPayload)`
  - `deleteEntry(entryID: UUID, sendToRecycleBin: Bool)`
- `EntryDraftPayload` value type with the editable fields (title, username, password (plaintext at edit time), url, notes, customFields, tags, totpConfig, lastModificationTime). Plaintext password is held only inside this transient payload, never persisted to disk in cleartext.
- `DatabaseDraft` value type:
  - `init(rootGroup: KPGroup, meta: KPMeta, sessionKey: SymmetricKey)`
  - `apply(_ edit: EntryEdit) throws -> DatabaseDraft` — returns a new draft with the edit applied
  - `var rootGroup: KPGroup { get }`, `var meta: KPMeta { get }` — current state
  - `var pendingEdits: [EntryEdit]` — log of edits applied since `init`
  - `var isDirty: Bool { pendingEdits.isNotEmpty }`
  - `func discardingEdits() -> DatabaseDraft` — returns a fresh draft over the original tree
- Recycle bin handling: deleting an entry with `sendToRecycleBin: true` moves it under `meta.recycleBinUUID`'s group if one exists; otherwise creates the recycle bin group lazily (this is the *one* allowed group mutation in v1, since users can't make it any other way).
- `lastModificationTime` is set to `.now` on every create/update.
- Re-encrypt the password through `EncryptedValue.encrypt(_:using: sessionKey)` so the resulting `KPEntry.password` is consistent with everything else in memory.
- Preserve the entry's `unknownXML` sidecar across `updateEntry` (so KeePassXC custom data attached to an entry survives an edit).

**Out:**

- Encrypting the draft to bytes — slice 02 already provides the writer; slice 04 wires it.
- Persisting the draft to disk — slice 04 (local) and slice 07 (extension queue).
- Group operations beyond lazy recycle bin creation.
- Any UI surface — slices 06 and 07.
- Conflict detection — slices 04, 05.

## Affected areas

- **New:** `KeeForge/Models/DatabaseDraft.swift`, `KeeForge/Models/EntryEdit.swift`.
- **Modified:** `KeeForge/Models/Group.swift` — add a small helper for "replace child group with a new version" given the immutable structure. Pure addition; existing call sites unchanged.
- **Modified:** `KeeForge/Models/Entry.swift` — preserve the `unknownXML` sidecar through update operations. Already added in slice 01.
- **New tests:** `KeeForgeTests/DatabaseDraftTests.swift`.

## KeeForge bits

- **Targets:** `DatabaseDraft.swift` and `EntryEdit.swift` belong to **both** `KeeForge` and `KeeForgeAutoFill` via the existing `KeeForge/Models` glob.
- **project.yml:**
  - No changes — glob paths cover the new files.
  - `Run xcodegen generate` is not needed.
- **Accessibility identifiers:** N/A — no view layer.

## Testing

- **Unit:** `KeeForgeTests/DatabaseDraftTests.swift`
  - `test_createEntry_addsEntryToParentGroup_setsTimestamps` — apply `createEntry`; assert the new entry is in the parent group, has a non-nil `creationTime` and `lastModificationTime`, and the rest of the tree is byte-equal to the original.
  - `test_createEntry_intoRoot_succeeds` — root group is a valid `parentGroupID`.
  - `test_updateEntry_updatesFields_preservesUnknownXML` — start from a fixture entry that has `unknownXML` populated by slice 01. Apply `updateEntry` changing only the title. Assert the resulting entry's `unknownXML` is byte-equal to the original.
  - `test_updateEntry_setsLastModificationTime` — assert `lastModificationTime` strictly increases.
  - `test_updateEntry_reEncryptsPassword_underSessionKey` — assert the resulting `EncryptedValue` decrypts (under the session key) to the new plaintext, and that the sealed bytes are different from the previous version.
  - `test_deleteEntry_softDelete_movesToRecycleBin` — apply `deleteEntry` with `sendToRecycleBin: true` on a tree that has a recycle bin. Assert the entry is now under the recycle bin group and is no longer in the original parent.
  - `test_deleteEntry_softDelete_lazilyCreatesRecycleBin` — apply on a tree with no recycle bin. Assert a recycle bin group is created at the root, `meta.recycleBinUUID` is updated, and the entry is moved into it.
  - `test_deleteEntry_hardDelete_removesEntry` — `sendToRecycleBin: false` removes the entry entirely; recycle bin is untouched.
  - `test_pendingEdits_recordsEveryAppliedOp_inOrder` — apply create, update, delete; assert `pendingEdits` is `[create, update, delete]`.
  - `test_isDirty_falseInitially_trueAfterFirstApply` — invariant check.
  - `test_discardingEdits_returnsFreshDraftOverOriginal` — assert `pendingEdits` is empty and the tree equals the original.
  - `test_entryEdit_codableRoundTrip` — encode/decode every variant of `EntryEdit` via `JSONEncoder`/`JSONDecoder`; assert equality. (Slice 07 will rely on this.)
  - `test_apply_unknownParentGroupID_throws` — error case; the draft remains unchanged.
  - `test_apply_unknownEntryID_onUpdate_throws` — error case.
  - Run slice: `xcodebuild test -only-testing:KeeForgeTests/DatabaseDraftTests`.
- **Integration / UI:** N/A.
- **Manual:** N/A — pure model.
- **Edge cases that apply:**
  - Apply hundreds of edits in sequence (no quadratic blowup; the test asserts wall time remains under 1s for 1000 ops).
  - Apply an edit, discard, apply another edit; assert state is correct.
  - Custom fields containing protected values (e.g. KP2A `KPEX_PASSKEY_PRIVATE_KEY_PEM`) — must round-trip through update.

## Exit criteria

- [ ] All `DatabaseDraftTests` pass.
- [ ] No force unwraps.
- [ ] `EntryEdit` and `EntryDraftPayload` are `Sendable`; `DatabaseDraft` is a value type and `Sendable`.
- [ ] Plaintext password is never stored on `KPEntry` itself — only inside the transient `EntryDraftPayload` until the draft is applied.
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Internal: Added DatabaseDraft layer that lets the app stage entry edits in memory before saving.`
