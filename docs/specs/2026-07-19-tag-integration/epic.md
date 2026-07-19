# Epic: Tag Browser and Tag Integration

## Summary

Make tags a first-class way to organize and find entries, as requested in
[issue #11](https://github.com/KeeForge/KeeForge/issues/11): a tag browser reachable from the
database root (and the macOS sidebar), tag-aware search, existing-tag suggestions while
editing, and database-wide tag rename/delete. KeeForge already round-trips and edits entry
tags; today they are only visible as read-only chips on the entry detail screen, which makes
them "more or less inaccessible" for daily work.

## Clarified requirements

This spec was produced from the issue text plus competitor research, without an interactive
clarification round. The answers below are the chosen defaults; changing an answer requires a
matching edit to the affected slices.

- **Q: What does "better tag integration" include?**
  **A:** Four things: (1) a tag browser — list of all tags with counts, tapping a tag shows
  its entries; (2) plain search matches tags; (3) the entry editor suggests existing tags;
  (4) database-wide tag rename and delete. Entry tags only; group tags stay out of scope.
- **Q: Where does the browser live?**
  **A:** iPhone/iPad: a root-level "Tags" row in the group list pushing a tag list, then a
  filtered entry list (Strongbox's pattern, reusing the existing browse screens). macOS: a
  "Tags" section in the sidebar column (KeePassXC's pattern). Entry-detail tag chips become
  tappable shortcuts into the same filtered list.
- **Q: Are `Work` and `work` the same tag?**
  **A:** No. Tag identity is exact-string and case-sensitive, matching KeePass 2.x,
  KeePassXC, Strongbox, and KeePassium. The tag list sorts case-insensitively
  (Finder-style, locale-aware) so near-duplicates sit next to each other, and search matching
  is case/diacritic-insensitive like the rest of KeeForge search. No automatic case merging.
- **Q: What is the delimiter policy?**
  **A:** Read splits on `,` and `;` (parser already does); the writer keeps emitting
  comma-joined tags (KeePass canonically writes `;` but all major implementations read both);
  edit-side normalization splits on `,`, `;`, and newline — adding `;` fixes a real bug where
  a typed `a;b` survives as one tag until the next reparse splits it. Separator characters
  can never end up inside a stored tag.
- **Q: How does the recycle bin interact with tags?**
  **A:** Recycled entries are excluded from the tag list, tag counts, and tag-filtered entry
  lists (both comparables exclude them from the list; KeePassXC's tag click still showing
  recycled entries is a long-standing complaint we avoid). Rename/delete, however, also
  update recycled entries so a restored entry comes back consistent and a deleted tag is
  really gone.
- **Q: Do tag operations rewrite history snapshots?**
  **A:** Never. Rename/delete mutate live entries through the normal draft path, which
  appends a history snapshot per modified entry; old tag strings remain visible in history,
  matching KeePass, KeePassium, Strongbox, and KeePassXC.
- **Q: May bulk tag operations touch decrypted secrets?**
  **A:** No. `EntryEdit.updateEntry` payloads carry plaintext password/TOTP secrets and
  re-encrypt on apply, so a rename across N entries would decrypt N passwords. Instead a new
  tags-only draft edit changes tags, `hasTagsElement`, and the modification time while
  leaving every `EncryptedValue` untouched. This is the epic's one stable-core change.
- **Q: AutoFill, rollout, flags?**
  **A:** AutoFill behavior is unchanged (shared model changes must stay extension-safe). No
  feature flag; the feature ships whole once slice 03 lands. Works identically for local and
  cloud databases; read-only databases get browsing and search but no editing or management.

## Competitor and reference findings

- KeePass 2.x stores entry tags as one string; it writes `;`-joined, reads both `,` and `;`,
  trims each tag, drops empties, and replaces separator characters inside a tag with `.`
  ([StrUtil.cs](https://github.com/dlech/KeePass2.x/blob/master/KeePassLib/Utility/StrUtil.cs)).
  Tag identity is case-sensitive throughout its pipeline. Group tags exist only in
  KDBX >= 4.1 and writing them forces a format-version bump
  ([KDBX 4.1](https://keepass.info/help/kb/kdbx_4.1.html),
  [KdbxFile.Write.cs](https://github.com/dlech/KeePass2.x/blob/master/KeePassLib/Serialization/KdbxFile.Write.cs)).
  History snapshots carry their own tags.
- Strongbox's home screen shows a tag-chip cloud (top 15 by popularity) plus a "Tags" tile
  with a total count; both push the normal browse screen filtered by tag
  ([HomeView.swift](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox/DatabaseHomeView/HomeView.swift),
  [TagsCloudView.swift](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox/DatabaseHomeView/TagsCloudView.swift)).
  It keeps a tag→entry-UUID fast map, excludes recycled entries from it, matches tags in
  plain search, and offers tag rename/delete
  ([DatabaseModel.m](https://github.com/strongbox-password-safe/Strongbox/blob/master/model/DatabaseModel.m)).
  Its `Favorite` tag doubles as the favourites store and is hidden from tag UIs
  ([Constants.m](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox/Constants.m)).
- KeePassXC's sidebar panel lists saved searches plus every tag; clicking one runs a
  `tag:"…"` search across all groups
  ([TagModel.cpp](https://github.com/keepassxreboot/keepassxc/blob/develop/src/gui/tag/TagModel.cpp)).
  The tag list excludes recycled entries, but the click-through search does not — a known
  complaint ([issue #2297](https://github.com/keepassxreboot/keepassxc/issues/2297)). The
  entry editor uses a chip input with autocomplete from the database's tag list; the sidebar
  offers "Remove Tag" from all entries (including recycled) but no rename
  ([TagView.cpp](https://github.com/keepassxreboot/keepassxc/blob/develop/src/gui/tag/TagView.cpp)).
  `Entry::setTags` splits on `,`/`;`/tab, trims, dedupes, sorts
  ([Entry.cpp](https://github.com/keepassxreboot/keepassxc/blob/develop/src/core/Entry.cpp)).
- KeePassium models tags as `[String]` on entries and groups with parent-walk inheritance,
  reads `,`/`;` and writes commas
  ([Taggable.swift](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/db/kp2/Taggable.swift)).
  It has no standalone tag browser — tags are reached via `tag:` search and smart groups —
  but its tag selector shows selected/inherited/all-with-counts sections and it ships
  database-wide rename/delete
  ([TagSelectorCoordinator.swift](https://github.com/keepassium/KeePassium/blob/master/KeePassium/database/tags/TagSelectorCoordinator.swift),
  [CHANGELOG](https://github.com/keepassium/KeePassium/blob/master/CHANGELOG.md)).
- Neither iOS comparable shows per-tag counts in its tag list; KeeForge showing counts is a
  cheap, visible improvement on both.

## Stable Core Impact

Touches `KeeForge/Models/DatabaseDraft.swift` (and the non-core `EntryEdit.swift`) in slice
03 to add a tags-only entry edit, because the existing `updateEntry` path requires plaintext
secrets in the payload and a bulk metadata operation must not decrypt them. The edit copies
the original entry, changing only tags, `hasTagsElement`, modification time, and appending
the standard history snapshot. Tests added: `DatabaseDraftTests` preservation and history
scenarios plus `KDBXCompatibilityTests` round-trips (see slice 03). `KDBXParser.swift`,
`KDBXWriter.swift`, `Entry.swift`, and `Group.swift` are not modified.

## Slice plan

| # | Slice | File | Depends on |
|---|-------|------|------------|
| 01 | Tag normalization and search foundations | `01-tag-normalization-and-search.md` | — |
| 02 | Tag browser | `02-tag-browser.md` | 01 |
| 03 | Tag editing and management | `03-tag-editing-and-management.md` | 01, 02 |

The split follows the layering boundaries: slice 01 lands the shared tag vocabulary
(normalization rules, the tag index, tag-aware search) with unit tests and one small visible
win; slice 02 builds the read-only browsing surface in both navigation shells on top of the
index; slice 03 adds the write-side features, which need the index (suggestions), the browser
(management entry points), and the stable-core draft change. Fewer slices would force the
stable-core edit and the two-shell UI into one review; more would split UI from its only
consumer.

## Cross-slice notes

- **Tag identity policy:** one canonical definition used by all slices — a tag is a trimmed,
  non-empty string that contains no `,` or `;`; identity is exact-string (case-sensitive);
  per-entry lists are deduped preserving first occurrence; display sort is
  case-insensitive locale-aware (Finder-style); search matching folds case and diacritics.
  Slice 01 owns the implementation; slices 02/03 must not re-derive their own rules.
- **Data model:** no new persisted state. The tag index (distinct tags, counts, tag→entries)
  is derived in `DatabaseViewModel` from the open database, excludes recycled entries via the
  existing recycle-bin ID sets, and is rebuilt wherever the search index is rebuilt today.
- **Navigation:** tag-filtered lists are a new `navigationDestination` on a dedicated
  Hashable tag-destination type (not a bare `String`, which could collide with future string
  destinations). Slice 02 introduces it; entry-detail chips and any later surfaces reuse it.
  Lock/close must clear it like existing destinations (`NavigationPath` reset plus the macOS
  sidebar selection).
- **Threading:** index building follows the existing `DatabaseViewModel` search-index
  pattern; no crypto or parsing is added to any hot path. Tags are plaintext KDBX metadata —
  no `EncryptedValue` reads anywhere in this epic except none at all (slice 03's draft edit
  explicitly avoids them).
- **Security:** no new network calls, permissions, or secret handling. Rename/delete stage
  through a single working draft and the existing `save()` pipeline (SHA-512 conflict check,
  timestamped backup, AutoFill cache refresh). Read-only databases expose no write surface.
- **Localization:** every new string lands in `en` and `de` in the main-app catalog;
  `swift scripts/normalize-xcstrings.swift` after programmatic edits; `LocalizationTests`
  must stay green.
- **CHANGELOG:** slices replace each other's entry progressively; the final entry, owned by
  slice 03, is:
  `- Added a tag browser: browse entries by tag, search by tag, tag suggestions while editing, and database-wide tag rename and delete.`

## Overall acceptance

- From a freshly opened database, a user can reach every tagged entry in at most three taps
  without typing (root → Tags → tag → entry), on iPhone, iPad, and macOS.
- Typing a tag's text into search finds entries carrying that tag.
- The tag list shows per-tag counts, excludes recycle-bin-only tags, sorts case-insensitively,
  and updates immediately after any edit changes tags.
- Renaming or deleting a tag updates every carrying entry (including recycled ones) in one
  save with one backup, appends normal history snapshots, never rewrites existing history,
  and never decrypts a password, TOTP secret, or passkey.
- A database edited by tag operations reopens correctly in KeePassXC with the expected tags
  (compatibility gate).
- Databases written by KeePass (`;`-separated), KeePassium, Strongbox, and KeePassXC browse
  correctly; `a;b` typed into KeeForge's tag field becomes two tags at save time, not on the
  next reparse.

## Out of scope

- Group tags (KDBX 4.1): not modeled, not shown, not inherited; they keep round-tripping
  verbatim through the existing unknown-XML preservation. A future epic can add
  KeePassium-style inheritance plus the required format-version bump logic.
- A `tag:` query syntax, saved searches, or smart groups (KeeForge search has no query
  language; plain search covering tags meets the issue's need).
- Bulk tagging via multi-select (neither iOS comparable has it).
- Tags in entry list rows/subtitles, tag colors, or tag icons.
- Any AutoFill UI or ranking changes.
- A favorites feature or special semantics for reserved tags: Strongbox's `Favorite` /
  `Apple Watch` tags appear as ordinary tags in KeeForge, deliberately — hiding data that
  another app shows would confuse cross-app users.
- KDB / KeePass 1.x formats (unchanged read-only policy).
