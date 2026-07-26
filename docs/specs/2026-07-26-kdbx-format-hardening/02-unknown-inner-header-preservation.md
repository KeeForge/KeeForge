# Slice 02: Preserve Unknown KDBX4 Inner-Header Fields

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

A KDBX4 file containing inner-header fields KeeForge doesn't recognize survives a KeeForge save with those fields intact, mirroring the outer header's existing `unknownOuterHeaderFields` behavior.

## Scope

**In:**
- `KDBXParser` retains unknown inner-header fields (any type ID other than 0x00/0x01/0x02/0x03) as raw (id, payload) pairs in original relative order, instead of skipping them. Carried on the parsed model alongside the existing outer-header equivalent.
- `KDBXWriter` re-emits them byte-exact on save. **Ordering contract (decided):** after the inner random stream ID and key fields, before the first binary-pool entry, preserving the unknown fields' relative order among themselves. Document the contract in a comment where they are re-emitted, including the rationale (spec defines no ordering semantics; KeePassXC ignores unknown inner-header IDs entirely).
- A checked-in fixture generator producing `TestFixtures/compatibility/unknown-inner-header.kdbx`: a normal KDBX4 database with one or more spliced unknown inner-header fields (a high ID like 0x7F with a recognizable payload; include one zero-length unknown field). The existing `generate_foreign_cipher_fixtures.py` shows the pykeepass low-level header-mutation technique, including the Construct `RawCopy` cache gotcha; the inner header is inside the encrypted payload, so the generator must mutate the parsed inner-header container before save. If pykeepass proves unable to splice inner-header items, fall back to a small standalone script that decrypts/re-encrypts the payload — and if that is disproportionate, stop and report rather than shipping a fixture whose provenance is KeeForge itself (that would defeat the purpose).
- Wire the fixture into the compatibility smoke matrix and the external gate (artifacts 21 → 22): extend the fail-closed expectation tables in `KDBXCompatibilitySupport`, the `expectedArtifactIDs` bookkeeping, and the descriptor-count assertion. The gate then proves KeePassXC still opens a KeeForge-rewritten file that carries an unknown inner-header field and can read a known entry password from it.
- README updates per repo rules: `TestFixtures/README.md` (fixture, password, generator), `KeeForgeTests/README.md` compatibility story if wording changes, `KeeForge/Models/README.md` parser/writer guidance line.

**Out:** preservation of unknown fields' positions relative to binary-pool entries (decided against — see epic Q&A); any outer-header change; KDBX3 (read-only, no writer).

## Affected areas

- Modified: `KeeForge/Models/KDBXParser.swift`, `KeeForge/Models/KDBXWriter.swift`, `KeeForgeTests/KDBXWriterTests.swift`, `KeeForgeTests/KDBXCompatibilitySupport.swift`, `KeeForgeTests/KDBXCompatibilityTests.swift`, `project.yml` (fixture resources), READMEs above.
- New: `TestFixtures/compatibility/unknown-inner-header.kdbx` + its generator script.

## KeeForge bits

- **Targets:** parser/writer are shared across all four app/extension targets (extension-safe, no new imports). Fixture bundles into `KeeForgeTests` + `KeeForgeMacTests` (explicit resource entries in `project.yml`, matching the foreign-cipher fixtures).
- **project.yml:** add the new fixture to both unit-test targets' resources. Run `xcodegen generate`.
- **Accessibility identifiers:** N/A — no view code.

## Testing

- **Unit:** `KDBXWriterTests.swift` — container round-trip of the fixture asserts every unknown inner-header field survives byte-exact (id, payload, relative order) per the ordering contract; a write of a database with *no* unknown fields emits none (no accidental injection); zero-length unknown payload survives; multiple unknown fields keep relative order. `KDBXParserTests.swift` — parsing the fixture succeeds and entry content/protected values are unaffected by the presence of unknown fields.
  Run slice: `-only-testing:KeeForgeTests/KDBXParserTests -only-testing:KeeForgeTests/KDBXWriterTests -only-testing:KeeForgeTests/KDBXCompatibilityTests`
- **Integration:** local gate run must pass at 22 artifacts, with the new fixture's smoke-created and fixture-authored passwords externally verified by keepassxc-cli.
- **Manual:** open the fixture in the app, edit an entry, save, reopen — content intact; open the KeeForge-saved copy in KeePassXC desktop once.
- **Edge cases that apply:** attachment add/remove on a database carrying unknown inner-header fields (pool changes must not disturb them); unknown field spliced *between* binary entries in the source file (normalized to before-the-pool on save, per contract); large unknown payload.

## Exit criteria

- [ ] Unit tests above pass on iOS and macOS test targets.
- [ ] Local compatibility gate passes at 22 artifacts including the new fixture.
- [ ] Fixture provenance is non-KeeForge (generator script checked in and documented).
- [ ] Manual checks done, including the KeePassXC desktop open.
- [ ] No force unwraps; heavy work off main; `xcodegen generate` run for the fixture wiring.

## CHANGELOG entry

`- KeeForge now preserves unknown KDBX4 inner-header fields when saving, protecting data written by future KeePass format extensions` (this slice owns the epic's entry).
