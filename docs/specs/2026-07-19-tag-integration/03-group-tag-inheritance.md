# Slice 03: Group-Tag Inheritance

> Parent: [`epic.md`](./epic.md) · Depends on: 01, 02

## Goal

Parse KDBX 4.1 group tags read-only and widen the tag index, browser, and search from
entries' own tags to effective tags (own plus every ancestor group's), without ever writing
a group tag that wasn't in the source file.

## Scope

**In:**

- **Model (stable core):** `KPGroup` gains a parsed tag list with the same shape entries
  have — a `[String]` plus the has-element flag that lets an empty `<Tags></Tags>` element
  round-trip. Groups are otherwise untouched.
- **Parser (stable core):** group `<Tags>` becomes a known child (today it falls into
  `unknownXML`), split with the identical rules used for entries (`,`/`;`, trim, drop
  empties). The known-child registration must keep unknown-XML sibling positioning stable
  for groups that carry both `<Tags>` and unrecognized elements.
- **Serializer:** emit a group's tags exactly where and how entry tags are emitted
  (comma-joined, empty element preserved when the flag is set, omitted entirely when the
  source had none). Because tags are never added or edited at the group level, output is
  read-what-you-wrote faithful and no KDBX version-bump logic is needed or allowed.
- **Effective tags:** the slice 01 index now aggregates each live entry's own tags plus all
  ancestor groups' tags, exact-string deduped. Browser list, counts, tag-filtered entry
  lists, and the search text all switch to effective tags with no UI changes (slice 02 was
  written not to assume own-tags-only). Entry-detail chips keep showing own tags only.
- **Recycle bin:** unchanged policy, now with a second dimension — recycled entries stay
  excluded even if a tagged ancestor made them match, and tags introduced only by the
  recycle-bin group (or groups inside it) never surface.
- **Compatibility coverage:** per `AGENTS.md`, parser/serializer behavior changed, so
  `KDBXCompatibilitySupport` grows group-tag scenarios and the KeePassXC artifact gate must
  pass on databases containing group tags.

**Out:**

- Group-tag editing, creation, or deletion; any group editor UI.
- Showing group tags on group rows or an "inherited" section in entry detail.
- Any change to `KDBXWriter`'s header/version logic, `DatabaseDraft`, or the KDBX 3.x
  parser (group tags don't exist in 3.x; anything nonstandard stays in unknown XML there).

## Implementation requirements

- Parsing reuses slice 01's normalization implementation — no second splitting routine.
- Preservation invariants, each of which needs a test: a group with tags saves back with
  the same tags after an unrelated entry edit; an empty group `<Tags>` element survives; a
  group with no tags element gains none; a KDBX 4.0 file that nonstandardly contains group
  tags round-trips them unchanged (preservation, not validation, is the contract); a group
  carrying both tags and an unknown sibling element keeps that sibling byte-identical and
  in position.
- Inheritance walks the existing tree — root-group tags apply to every live entry; nested
  groups accumulate ancestors' tags; a group and its subgroup sharing a tag counts each
  entry once. There is no cycle risk in a tree, but deep nesting (KeePass allows arbitrary
  depth) must not recurse per-entry — resolve per-group during the single index pass.
- History snapshots are unaffected: their own tags stay unindexed, and group-tag changes
  made by other apps never alter KeeForge history.
- The model change is shared with both AutoFill targets automatically (all of
  `KeeForge/Models` is shared); the extension's behavior must not change — `CredentialMatcher`
  and AutoFill search stay tag-blind.
- A checked-in fixture containing group tags is required (created with an app that can
  author them, e.g. KeePassium, or hand-built and re-encrypted; document creator, settings,
  credentials, and content in `TestFixtures/README.md`, and wire the resource through
  `project.yml`).

## Affected areas

- New: a KDBX 4.1 group-tags test fixture.
- Modified: `KeeForge/Models/Group.swift`, `KeeForge/Models/KDBXParser.swift` (stable
  core — see epic justification), `KeeForge/Models/KDBXXMLSerializer.swift`,
  `KeeForge/ViewModels/DatabaseViewModel.swift` (effective-tag aggregation),
  `KeeForgeTests/KDBXCompatibilitySupport.swift`, `TestFixtures/README.md`.

## KeeForge bits

- **Targets:** all modified `KeeForge/Models` files keep their existing membership (main
  app + both AutoFill targets); view-model changes are `KeeForge` app target only; the
  fixture is a `KeeForgeTests` resource.
- **project.yml:** add the fixture to `KeeForgeTests` resources; run `xcodegen generate`.
- **Accessibility identifiers:** N/A — no view-layer changes (browser screens are reused
  as-is).
- **CHANGELOG entry:** see below; replaces slice 02's, replaced by slice 04's.

## Testing

- **Unit:** `KDBXParserTests.swift` / `KDBXRoundTripTests.swift` — named scenarios: parse
  the fixture and assert each group's tags; every preservation invariant listed above
  (tags survive unrelated edits, empty element, absent element, 4.0 nonstandard file,
  unknown-sibling positioning).
- **Unit:** `DatabaseViewModelTests.swift` — effective-tag scenarios: entry under a tagged
  group appears in that tag's browser list and count; nested accumulation; root-group tag
  reaches all live entries; group+entry sharing a tag counts once; case-variant group vs
  entry tags stay distinct; recycled entry under a tagged group excluded; tag existing only
  on the recycle-bin group absent; search finds an entry via an ancestor group's tag; a
  history-only tag still finds nothing.
- **Compatibility:** `KDBXCompatibilityTests.swift` — a database with group tags passes the
  edit-mutation matrix and the KeePassXC artifact gate with all group tags intact; a
  KeeForge-saved database never gains a `<Tags>` element on any group that lacked one.
  Run slice: `-only-testing:KeeForgeTests/KDBXParserTests -only-testing:KeeForgeTests/KDBXRoundTripTests -only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/KDBXCompatibilityTests`
- **Integration / UI:** N/A — no new UI; slice 02's UI test keeps covering the browser.
- **Manual:** create a group-tagged database in KeePassium or KeePassXC, open it in
  KeeForge, and confirm its entries appear under the group's tag in the browser and via
  search; edit an unrelated entry, save, reopen in the other app, and confirm group tags
  are untouched.
- **Edge cases that apply:** deep nesting, root-group tags, empty `<Tags>` on a group,
  nonstandard 4.0 group tags, unknown-XML siblings, recycle-bin group tags, case-variant
  collisions between group and entry tags, large trees (single-pass resolution).

## Exit criteria

- [ ] All unit and compatibility tests above pass; the KeePassXC artifact gate is green.
- [ ] Manual cross-app checks done.
- [ ] Stable-core change limited to read-only group-tag modeling/parsing; no version-bump
      or group-tag write path exists.
- [ ] No force unwraps; no secrets touched; parsing stays off the main thread; index
      resolution is single-pass.
- [ ] Both AutoFill targets compile unchanged in behavior.
- [ ] `project.yml` updated for the fixture and `xcodegen generate` run.
- [ ] CHANGELOG entry replaces slice 02's.

## CHANGELOG entry

`- Added a tag browser: browse all tags with entry counts — including tags inherited from groups — jump to a tag from any entry's detail screen, and search by tag.`

(Replaced by slice 04's final entry when it lands.)
