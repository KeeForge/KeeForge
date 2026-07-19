# Slice 01: Tag Normalization and Search Foundations

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

Establish the single tag vocabulary the whole epic builds on — canonical normalization
rules, a recycled-aware tag index on `DatabaseViewModel` — and make plain search match tags,
the slice's user-visible win.

## Scope

**In:**

- One shared implementation of the epic's tag identity policy (trim, drop empties, no `,`
  or `;` inside a tag, exact-string identity, first-occurrence dedupe per entry).
- Fix the edit-side normalization delimiter gap: `EntryEditViewModel` currently splits typed
  tag text on `,` and newline only (`EntryEditViewModel.swift:230-235`), while the parser
  splits stored text on `,` and `;` (`KDBXParser.swift:1415-1427`). A typed `a;b` therefore
  saves as one tag and silently becomes two on the next reparse. Normalization must split on
  `,`, `;`, and newline, then trim, drop empties, and dedupe.
- A tag index derived in `DatabaseViewModel`: the distinct tags in the open database, a
  per-tag entry count, and per-tag entry lookup — excluding entries in the recycle bin
  (reuse the existing `recycleBinEntryIDs` mechanism). Rebuilt wherever the search caches are
  rebuilt today (open, edit apply, external refresh), never inside a SwiftUI `body`.
- Plain search matches tags: extend the per-entry searchable text
  (`DatabaseViewModel.searchText(for:)`, currently title/username/url/notes) with the
  entry's tags, using the same folding. Update the search-scope UI copy in `SearchView`
  ("search by title, username, URL, or notes") and its `de` translation to mention tags.

**Out:**

- Any new screens or navigation (slice 02).
- Group tags and inheritance: the index covers entries' own tags until slice 03 widens it to
  effective tags (own + ancestor groups'). Structure the index so that widening is a change
  to what feeds it, not a redesign.
- Editor tag suggestions (slice 04).
- Parser/writer changes: the parser already reads both separators; the writer keeps emitting
  comma-joined tags. No stable-core file changes in this slice.

## Implementation requirements

- The normalization implementation lives in `KeeForge/Models` so the same rules are
  available to the app, tests, and (later, if ever needed) the AutoFill targets. It must
  stay extension-safe: Foundation only, no UI imports, no main-actor requirement.
- Normalization must be pure and total: any input string (including only-whitespace,
  repeated separators, leading/trailing separators) yields a valid, possibly empty tag list.
  Interior spaces are legal tag content ("New York"). Unicode (diacritics, emoji, CJK) passes
  through unmodified — normalization never changes characters, only splits/trims/drops.
- Entries parsed from files written by other apps may carry exact duplicates or
  differently-cased near-duplicates; the index must count each entry once per distinct tag
  and keep `Work`/`work` as separate tags. Do not "fix" duplicates on read — on-disk data
  changes only when the user edits.
- History snapshots are never indexed or searched (current behavior — searchable text is
  built from live fields only; keep it that way).
- The index must be cheap enough for large databases: one pass over live entries per
  rebuild, no per-render work. Follow the existing pattern and threading model of the search
  cache; do not introduce new concurrency machinery.
- Tag order within an entry is user data (KeePass preserves it); the index may sort for
  display but must not reorder `Entry.tags`.

## Affected areas

- New: tag normalization + index support in `KeeForge/Models` and/or `DatabaseViewModel`
  (implementer's structural choice; one new file at most).
- Modified: `KeeForge/ViewModels/EntryEditViewModel.swift` (delimiter fix),
  `KeeForge/ViewModels/DatabaseViewModel.swift` (index + searchable text),
  `KeeForge/Views/SearchView.swift` copy, both locales in
  `KeeForge/Resources/Localizable.xcstrings`.

## KeeForge bits

- **Targets:** any new `KeeForge/Models` file joins every target that builds Models today
  (main app + both AutoFill targets — mirror existing membership in `project.yml`);
  view-model/view changes are `KeeForge` app target only.
- **project.yml:** no changes unless a new source file is added; if one is, mirror the
  sibling Models entries, then run `xcodegen generate`.
- **Accessibility identifiers:** none added; none removed (copy-only change in `SearchView`).
- **CHANGELOG entry:** see below; replaced by later slices.

## Testing

- **Unit:** `EntryEditViewModelTests.swift` — extend the existing normalization test:
  semicolon input `a;b` yields two tags; mixed `a, b;c\nd` yields four; ` ; ,, ` yields
  none; duplicate `a,a` yields one; `Work,work` yields two. Assert seeding an entry whose
  stored tags contain a comma-adjacent duplicate round-trips without loss.
- **Unit:** `DatabaseViewModelTests.swift` — named scenarios:
  - index lists distinct tags with correct counts for a database containing shared,
    unique, and differently-cased tags;
  - an entry in the recycle bin contributes nothing (tag carried only by a recycled entry
    is absent);
  - the index updates after `applyEntryEdit` adds/removes a tag, and after delete-to-recycle
    removes an entry;
  - search finds an entry by full and partial tag text, case- and diacritic-insensitively;
    a query matching only a history snapshot's old tag finds nothing;
  - entries with no tags and a database with zero tags produce an empty index without error.
  Run slice: `-only-testing:KeeForgeTests/EntryEditViewModelTests -only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/LocalizationTests`
- **Integration / UI:** N/A — no new UI surface; search UI behavior is covered by the view
  model tests.
- **Manual:** in a database with tagged entries, type a tag into search and see its entries;
  type `a;b` into the entry editor's tag field, save, reopen, and confirm two tags.
- **Edge cases that apply:** semicolon input, only-whitespace tags, duplicate and
  case-variant tags from foreign files, recycled-entry exclusion, zero-tag database, large
  database (index built once per change, not per keystroke).

## Exit criteria

- [ ] Unit tests above pass, including `LocalizationTests` for the updated search copy.
- [ ] Manual checks done.
- [ ] `Entry.tags` on-disk bytes unchanged for untouched entries (no read-time rewriting).
- [ ] No force unwraps; no secrets touched; index rebuilds off the render path.
- [ ] `xcodegen generate` run if `project.yml` changed.
- [ ] CHANGELOG entry written.

## CHANGELOG entry

`- Search now matches entry tags, and tags typed with semicolons are split correctly.`

(Replaced by slice 02's entry when it lands.)
