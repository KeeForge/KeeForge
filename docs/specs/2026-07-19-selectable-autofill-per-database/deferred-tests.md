# Deferred Tests: Selectable AutoFill Per Database

> **Why this file exists.** The epic was implemented in a Linux environment with no Apple
> toolchain, so no tests could be written or run alongside the code. This document is the
> pick-up list for a follow-up session on a Mac: every test each slice requires, written
> against the *actual* implementation (real type names, real seams), plus the toolchain
> steps that could not run on Linux.
>
> **How to pick this up.** Work slice by slice, smallest test slice first, using the exact
> `-only-testing:` commands given. When a section's tests are green, check its box in the
> checklist below.

## Toolchain follow-ups (run once, before/while writing tests)

- [ ] `xcodegen generate` — only needed if any new source/test files are added while writing
      the tests below (no new source files were added by the implementation itself).
- [ ] `swift scripts/normalize-xcstrings.swift` — the implementation edited
      `.xcstrings` catalogs as plain JSON; Linux cannot reproduce Xcode's
      `localizedStandardCompare` key order, so the catalogs must be normalized on a Mac and
      the diff re-committed. Then run `-only-testing:KeeForgeTests/LocalizationTests`.
- [ ] Full build of all targets (`KeeForge`, `KeeForgeAutoFill`, `KeeForgeMacAutoFill`) —
      the implementation was written without a compiler; fix any first-build breakage before
      starting on tests.
- [ ] `-only-testing:KeeForgeTests/AppGroupGuardrailTests` — the registry gained a plain
      bool field; guardrail must stay green.

## Slice checklist

- [ ] Slice 01 — AutoFill-enabled flag and publication gating
- [ ] Slice 02 — Database-tagged credential identities
- [ ] Slice 03 — Extension identity-to-database resolution
- [ ] Slice 04 — Multi-database aggregation and targeted removal
- [ ] Slice 05 — Settings UI and Clear AutoFill Entries
- [ ] Slice 06 — Extension database switcher
- [ ] Manual test pass (aggregated from the slice sections; device + mac extension)

---

## Slice 01: AutoFill-enabled flag and publication gating

_To be filled by the slice 01 implementation._

---

## Slice 02: Database-tagged credential identities

_To be filled by the slice 02 implementation._

---

## Slice 03: Extension identity-to-database resolution

_To be filled by the slice 03 implementation._

---

## Slice 04: Multi-database aggregation and targeted removal

_To be filled by the slice 04 implementation._

---

## Slice 05: Settings UI and Clear AutoFill Entries

_To be filled by the slice 05 implementation._

---

## Slice 06: Extension database switcher

_To be filled by the slice 06 implementation._
