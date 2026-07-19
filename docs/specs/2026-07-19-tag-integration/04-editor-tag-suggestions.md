# Slice 04: Editor Tag Suggestions

> Parent: [`epic.md`](./epic.md) · Depends on: 01, 03

## Goal

Let users apply existing tags with one tap while editing an entry, instead of retyping them
from memory into the free-text field.

## Scope

**In:**

- In `EntryEditView`, below the existing tags text field, show the database's known tags as
  tappable suggestion chips; tapping one appends it to the entry's tags. The free-text field
  stays — suggestions are an accelerator, not a replacement.
- Suggestions are exact strings: a differently-cased variant is a separate suggestion, and
  choosing it adds that exact casing.
- The pool comes from slice 01's index (all distinct known tags, which after slice 03 means
  effective tags across the database), minus tags that would be redundant on this entry:
  its current own tags as typed in the field (live-updating as the user edits the text) and
  the tags it inherits from its ancestor groups. Because the pool derives from the
  recycled-excluding index, recycle-bin-only tags are never suggested — deliberate, not a
  bug.
- Applies to both create and edit flows, wherever `EntryEditView` is used today (including
  its AutoFill-save appearance only if that flow already shows the tags field — do not add
  the field to any flow that lacks it).
- When every known tag is already on the entry, or the database has no tags, the suggestion
  area disappears entirely (no empty husk).

**Out:**

- Any change to how tags are stored, normalized, or saved — the existing edit pipeline
  is untouched.
- Tag creation UI beyond the existing free-text field; rename/delete (out of the epic).
- Suggestion ranking beyond the standard tag sort (no popularity ordering, no fuzzy match).

## Implementation requirements

- Exclusion matching uses exact-string identity like everything else in the epic; typing
  `work` does not hide the `Work` suggestion.
- Tapping a suggestion feeds the same normalization path as typed text — the resulting
  payload must be identical to having typed the tag correctly (dedupe applies if the user
  already typed it).
- The suggestion strip must handle many long tags without breaking the form layout (wrap or
  scroll; implementer's choice, consistent with the detail screen's chip presentation).
- The pool is captured from the open database when the editor appears and does not need
  live updates from concurrent external changes (the editor is modal over a stable
  snapshot); it must, however, react to the user's own in-form edits.
- Read-only databases never reach this UI (no editor there); no separate gating needed
  beyond what exists.
- New strings (if any beyond the chips themselves, e.g. a section label) localized in `en`
  and `de`.

## Affected areas

- New: none required (implementer may extract a small suggestion-strip view).
- Modified: `KeeForge/Views/EntryEditView.swift`,
  `KeeForge/ViewModels/EntryEditViewModel.swift` (suggestion pool + exclusion),
  possibly `KeeForge/ViewModels/DatabaseViewModel.swift` (exposing the pool),
  `KeeForge/Resources/Localizable.xcstrings` (both locales).

## KeeForge bits

- **Targets:** `KeeForge` app target only, unless `EntryEditView`/`EntryEditViewModel` are
  compiled into the AutoFill targets today — keep membership exactly as it is; if shared,
  the change must remain extension-safe.
- **project.yml:** no changes unless a suggestion-strip view file is added; if so, add it to
  the owning target(s) and run `xcodegen generate`.
- **Accessibility identifiers:** new — the suggestion strip container and per-tag chips with
  a stable per-tag suffix, matching slice 02's convention. `entry-edit.tags-field` and all
  existing identifiers preserved.
- **CHANGELOG entry:** final epic entry, below.

## Testing

- **Unit:** `EntryEditViewModelTests.swift` — named scenarios: pool excludes tags already in
  the field and updates as the field text changes (add and remove); pool excludes inherited
  ancestor-group tags for the entry's location; case-variant tags remain suggested and
  insert exact casing; tapping a suggestion produces the same normalized payload as typing
  it; duplicate tap is a no-op; empty pool cases (no tags in database / all tags applied);
  recycle-bin-only tags absent.
  Run slice: `-only-testing:KeeForgeTests/EntryEditViewModelTests -only-testing:KeeForgeTests/LocalizationTests`
- **Integration / UI:** N/A — form interaction is covered at the view-model level; the
  existing edit-flow UI tests keep passing with identifiers preserved.
- **Manual:** edit an entry in a database with several tags and add one by tap; confirm the
  chip disappears from suggestions and appears on saving; create a new entry inside a
  tagged group and confirm the group's tags are not suggested; check layout with a dozen
  long tags.
- **Edge cases that apply:** case-variant suggestions, long/emoji tag names, all-tags-applied
  and zero-tag databases, entry nested under tagged groups, dedupe on tap-after-type.

## Exit criteria

- [ ] Unit tests above pass; `LocalizationTests` green in `en`/`de`.
- [ ] Manual checks done.
- [ ] Accessibility identifiers added; existing ones and the edit-flow UI tests untouched.
- [ ] No force unwraps; no secrets touched; no change to saved-payload semantics.
- [ ] `xcodegen generate` run if `project.yml` changed.
- [ ] CHANGELOG final entry replaces slice 03's.

## CHANGELOG entry

`- Added a tag browser: browse entries by tag (including tags inherited from groups), search by tag, and tag suggestions while editing.`
