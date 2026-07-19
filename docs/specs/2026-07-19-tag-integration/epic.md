# Epic: Tag Browser and Tag Integration

## Summary

Make tags a first-class way to organize and find entries, as requested in
[issue #11](https://github.com/KeeForge/KeeForge/issues/11): a tag browser reachable from the
database root (and the macOS sidebar), tag-aware search, read-only inheritance of KDBX 4.1
group tags, and existing-tag suggestions while editing. KeeForge already round-trips and
edits entry tags; today they are only visible as read-only chips on the entry detail screen,
which makes them "more or less inaccessible" for daily work.

## Clarified requirements

Initial defaults were drawn from the issue text plus competitor research; the four decisions
below marked *(confirmed)* were then answered interactively by the maintainer on 2026-07-19.

- **Q: What does "better tag integration" include?** *(confirmed)*
  **A:** Three things: (1) a tag browser — list of all tags with counts, tapping a tag shows
  its entries; (2) plain search matches tags; (3) the entry editor suggests existing tags.
  Database-wide tag rename/delete was considered and **explicitly dropped** from this epic
  (see Out of scope for the design notes future work should reuse).
- **Q: Where does the browser live?** *(confirmed)*
  **A:** iPhone/iPad: a single root-level "Tags" row in the group list pushing a tag list,
  then a filtered entry list (a Strongbox-style root tag-chip cloud was considered and
  rejected to keep the root list calm). macOS: a "Tags" section in the sidebar column
  (KeePassXC's pattern). Entry-detail tag chips become tappable shortcuts into the same
  filtered list.
- **Q: What about group tags (KDBX 4.1)?** *(confirmed)*
  **A:** **Read-only inheritance.** KeeForge parses group `<Tags>` into the model (today
  they survive only as opaque unknown XML), round-trips them byte-faithfully, and treats an
  entry as carrying its own tags plus every ancestor group's tags ("effective tags") for
  browsing, counts, and search. No group-tag editing, no creation, and therefore no
  KDBX 4.0→4.1 format-version bump logic — KeeForge never writes a group tag that wasn't in
  the source file.
- **Q: How deep does search integration go?** *(confirmed)*
  **A:** Plain search only: tags join title/username/URL/notes in the existing substring
  match. No `tag:` query syntax and no tag-filter chips in the search UI.
- **Q: Are `Work` and `work` the same tag?**
  **A:** No. Tag identity is exact-string and case-sensitive, matching KeePass 2.x,
  KeePassXC, Strongbox, and KeePassium. The tag list sorts case-insensitively
  (Finder-style, locale-aware) so near-duplicates sit next to each other, and search
  matching is case/diacritic-insensitive like the rest of KeeForge search. No automatic
  case merging.
- **Q: What is the delimiter policy?**
  **A:** Read splits on `,` and `;` (parser already does); the writer keeps emitting
  comma-joined tags (KeePass canonically writes `;` but all major implementations read
  both); edit-side normalization splits on `,`, `;`, and newline — adding `;` fixes a real
  bug where a typed `a;b` survives as one tag until the next reparse splits it. Separator
  characters can never end up inside a stored tag.
- **Q: How does the recycle bin interact with tags?**
  **A:** Recycled entries are excluded from the tag list, tag counts, and tag-filtered
  entry lists (both comparables exclude them from the list; KeePassXC's tag click still
  showing recycled entries is a long-standing complaint we avoid). Tags carried only inside
  the recycle bin — including via the recycle-bin group's own tags — never surface.
- **Q: AutoFill, rollout, flags?**
  **A:** AutoFill behavior is unchanged (shared model changes must stay extension-safe). No
  feature flag; the feature ships whole once slice 04 lands. Works identically for local and
  cloud databases; read-only databases get browsing and search but no editing surface.

## Competitor and reference findings

- KeePass 2.x stores entry tags as one string; it writes `;`-joined, reads both `,` and `;`,
  trims each tag, drops empties, and replaces separator characters inside a tag with `.`
  ([StrUtil.cs](https://github.com/dlech/KeePass2.x/blob/master/KeePassLib/Utility/StrUtil.cs)).
  Tag identity is case-sensitive throughout its pipeline. Group tags exist only in
  KDBX >= 4.1 and writing them from scratch forces a format-version bump — which this epic
  avoids by never creating them
  ([KDBX 4.1](https://keepass.info/help/kb/kdbx_4.1.html),
  [KdbxFile.Write.cs](https://github.com/dlech/KeePass2.x/blob/master/KeePassLib/Serialization/KdbxFile.Write.cs)).
  History snapshots carry their own tags.
- KeePassium models tags as `[String]` on entries and groups, resolves inheritance by
  walking parents with exact-string dedupe, reads `,`/`;` and writes commas
  ([Taggable.swift](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/db/kp2/Taggable.swift),
  [DatabaseItem.swift](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/db/DatabaseItem.swift)).
  It has no standalone tag browser — tags are reached via `tag:` search and smart groups —
  and its entry viewer shows own tags only, with inherited tags visible in the tag selector
  ([TagSelectorCoordinator.swift](https://github.com/keepassium/KeePassium/blob/master/KeePassium/database/tags/TagSelectorCoordinator.swift)).
- Strongbox's home screen shows a tag-chip cloud (top 15 by popularity) plus a "Tags" tile
  with a total count; both push the normal browse screen filtered by tag
  ([HomeView.swift](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox/DatabaseHomeView/HomeView.swift),
  [TagsCloudView.swift](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox/DatabaseHomeView/TagsCloudView.swift)).
  It keeps a tag→entry-UUID fast map, excludes recycled entries from it, and matches tags in
  plain search
  ([DatabaseModel.m](https://github.com/strongbox-password-safe/Strongbox/blob/master/model/DatabaseModel.m)).
  Its `Favorite` tag doubles as the favourites store and is hidden from tag UIs
  ([Constants.m](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox/Constants.m)).
- KeePassXC's sidebar panel lists saved searches plus every tag; clicking one runs a
  `tag:"…"` search across all groups
  ([TagModel.cpp](https://github.com/keepassxreboot/keepassxc/blob/develop/src/gui/tag/TagModel.cpp)).
  The tag list excludes recycled entries, but the click-through search does not — a known
  complaint ([issue #2297](https://github.com/keepassxreboot/keepassxc/issues/2297)). The
  entry editor uses a chip input with autocomplete from the database's tag list
  ([EditEntryWidget.cpp](https://github.com/keepassxreboot/keepassxc/blob/develop/src/gui/entry/EditEntryWidget.cpp));
  `Entry::setTags` splits on `,`/`;`/tab, trims, dedupes, sorts
  ([Entry.cpp](https://github.com/keepassxreboot/keepassxc/blob/develop/src/core/Entry.cpp)).
- Neither iOS comparable shows per-tag counts in its tag list, and neither surfaces
  group-tag inheritance in a browser; KeeForge showing counts over effective tags improves
  on both.

## Stable Core Impact

Touches `KeeForge/Models/Group.swift` and `KeeForge/Models/KDBXParser.swift` in slice 03 to
model group `<Tags>` (read-only): the element moves from opaque unknown-XML preservation to
a parsed field with the same empty-element semantics entries already have, and the
serializer re-emits exactly what was parsed. This is intentional format work in service of
inheritance; KeeForge never creates or modifies group tags, so no version-bump logic enters
the writer. Tests added: parser/serializer round-trip scenarios (including unknown-XML
sibling positioning and empty elements) plus `KDBXCompatibilityTests` coverage with the
KeePassXC artifact gate (see slice 03). `KDBXWriter.swift`, `Entry.swift`,
`DatabaseDraft.swift`, `KDBXCrypto.swift`, and `EncryptedValue.swift` are not modified.

## Slice plan

| # | Slice | File | Depends on |
|---|-------|------|------------|
| 01 | Tag normalization and search foundations | `01-tag-normalization-and-search.md` | — |
| 02 | Tag browser | `02-tag-browser.md` | 01 |
| 03 | Group-tag inheritance | `03-group-tag-inheritance.md` | 01, 02 |
| 04 | Editor tag suggestions | `04-editor-tag-suggestions.md` | 01, 03 |

The split follows the layering boundaries: slice 01 lands the shared tag vocabulary
(normalization rules, the tag index, tag-aware search) with unit tests and one small visible
win; slice 02 builds the browsing surface in both navigation shells on top of the index;
slice 03 makes the one stable-core change (group-tag parsing) and widens the index, browser,
and search from own tags to effective tags; slice 04 adds the small write-side accelerator,
whose suggestion pool and exclusion rules assume effective tags exist. Fewer slices would
force the stable-core parser work and the two-shell UI into one review.

## Cross-slice notes

- **Tag identity policy:** one canonical definition used by all slices — a tag is a trimmed,
  non-empty string that contains no `,` or `;`; identity is exact-string (case-sensitive);
  per-item lists are deduped preserving first occurrence; display sort is case-insensitive
  locale-aware (Finder-style); search matching folds case and diacritics. Slice 01 owns the
  implementation; later slices must not re-derive their own rules.
- **Effective tags:** an entry's effective tags are its own tags plus every ancestor group's
  tags, exact-string deduped. Slice 01's index is defined over effective tags but computes
  over own tags until slice 03 supplies group tags; browser, counts, search, and suggestion
  exclusions all use effective tags from then on. Entry-detail chips always show own tags
  only (KeePassium's choice; editing an entry edits exactly what its chips show).
- **Data model:** no new persisted state. The tag index (distinct tags, counts, tag→entries)
  is derived in `DatabaseViewModel` from the open database, excludes recycled entries via
  the existing recycle-bin ID sets, and is rebuilt wherever the search index is rebuilt
  today.
- **Navigation:** tag-filtered lists are a new `navigationDestination` on a dedicated
  Hashable tag-destination type (not a bare `String`, which could collide with future string
  destinations). Slice 02 introduces it; entry-detail chips and any later surfaces reuse it.
  Lock/close must clear it like existing destinations (`NavigationPath` reset plus the macOS
  sidebar selection).
- **Threading:** index building follows the existing `DatabaseViewModel` search-index
  pattern; no crypto or parsing is added to any hot path. Tags are plaintext KDBX metadata —
  nothing in this epic reads an `EncryptedValue`.
- **Security:** no new network calls, permissions, or secret handling. Read-only databases
  expose no write surface; browsing and search work everywhere.
- **Localization:** every new string lands in `en` and `de` in the main-app catalog;
  `swift scripts/normalize-xcstrings.swift` after programmatic edits; `LocalizationTests`
  must stay green.
- **CHANGELOG:** slices replace each other's entry progressively; the final entry, owned by
  slice 04, is:
  `- Added a tag browser: browse entries by tag (including tags inherited from groups), search by tag, and tag suggestions while editing.`

## Overall acceptance

- From a freshly opened database, a user can reach every tagged entry in at most three taps
  without typing (root → Tags → tag → entry), on iPhone, iPad, and macOS.
- Typing a tag's text into search finds entries carrying that tag directly or via an
  ancestor group.
- The tag list shows per-tag counts over effective tags, excludes recycle-bin-only tags,
  sorts case-insensitively, and updates immediately after any edit changes tags.
- A KDBX 4.1 database with group tags opens, browses by those tags, and — after any ordinary
  entry edit and save — reopens in KeePassXC with every group tag intact (compatibility
  gate). KeeForge never writes a group tag into a file that had none.
- Databases written by KeePass (`;`-separated), KeePassium, Strongbox, and KeePassXC browse
  correctly; `a;b` typed into KeeForge's tag field becomes two tags at save time, not on the
  next reparse.
- Editing an entry offers the database's existing tags as one-tap suggestions.

## Out of scope

- **Database-wide tag rename/delete** — dropped from this epic by maintainer decision.
  Design notes for whoever picks it up: `EntryEdit.updateEntry` payloads carry plaintext
  password/TOTP secrets and re-encrypt on apply, so bulk tag operations must NOT be built
  from full-payload updates; add a tags-only `EntryEdit` case in `DatabaseDraft` that copies
  the entry changing only tags/`hasTagsElement`/modification time plus a history snapshot,
  never touching an `EncryptedValue`. Rename/delete should also reach recycled entries, be
  staged as one draft with one save/backup, and never rewrite history snapshots.
- Group-tag editing or creation, and the KDBX 4.0→4.1 version-bump logic writing them from
  scratch would require.
- A `tag:` query syntax, saved searches, smart groups, or tag-filter chips in search UI.
- Bulk tagging via multi-select (neither iOS comparable has it).
- Tags in entry list rows/subtitles, tag colors, tag icons, or inherited-tag chips on the
  entry detail screen.
- Any AutoFill UI or ranking changes.
- A favorites feature or special semantics for reserved tags: Strongbox's `Favorite` /
  `Apple Watch` tags appear as ordinary tags in KeeForge, deliberately — hiding data that
  another app shows would confuse cross-app users.
- KDB / KeePass 1.x formats (unchanged read-only policy); KDBX 3.x group tags do not exist
  in that format and stay wherever its unknown-XML handling puts them.
