# Slice 01: Lossless XML round-trip

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

Make `KDBXParser` capture every XML element it currently doesn't model into an opaque sidecar, and add a `KDBXXMLSerializer` that re-emits the parsed tree as KDBX-compatible XML. After this slice, parse → serialize → parse on every TestFixture produces a tree equal to the original — including elements that the rest of the app has no concept of (custom data, attachments, custom icons, KP2A fields, history beyond what we read, etc.).

This slice ships no user-visible behavior. It is foundational for slice 02 (the encrypted writer) and slice 04 (save).

## Background reading

The technique to crib is **Strongbox's** `lazyUnmanagedChildElements`/`unknownHeaders` approach in `model/keepass/BaseXmlDomainObjectHandler.m` (specifically the `writeUnmanagedChildren` re-emit and `Kdbx4Database.m` lines 116–193 for the call site). Strongbox attaches a list of opaque XML element snapshots to every domain object and re-emits them in the same position on write. KeePassium's writer (`KeePassiumLib/db/kp2/Database2.swift:817–879`) deliberately does *not* preserve unknowns — and that design choice has caused multiple "data lost after editing on iOS" reports filed against them. We follow Strongbox's approach for cross-tool durability.

## Scope

**In:**

- Walk `KDBXXMLParser` and identify every element/attribute it currently consumes vs every element/attribute it currently silently drops. The current parser builds a structured representation; we need to add an "unknown nodes" sidecar that captures everything it skipped.
- Add an `OpaqueXMLNodes` value type (Sendable, Hashable) that holds the verbatim XML for child nodes the structured parser did not consume. Attach one to `KPEntry`, `KPGroup`, and a new `KPMeta` value (currently meta is parsed inline).
- Add a `KDBXXMLSerializer` that takes the parsed tree (root `KPGroup` + `KPMeta`) plus the per-session inner-stream key and produces XML bytes byte-compatible enough that re-parsing yields an equal tree.
- Re-encrypt protected values when serializing using the same inner ChaCha20 stream the parser uses for decrypting them — symmetric to the existing read path.
- Identity tests across every fixture under `TestFixtures/`.

**Out:**

- The KDBX outer-format writer (header + HMAC blocks + outer cipher). That is slice 02.
- Any mutation of the tree. The serializer takes whatever tree it is given, including a tree that came straight from the parser.
- Any UI or save action.

## Affected areas

Rough orientation, not exhaustive.

- **New:** `KeeForge/Models/KDBXXMLSerializer.swift`. `KeeForge/Models/OpaqueXMLNodes.swift` (the sidecar value type and its serialization helpers).
- **Modified:** `KeeForge/Models/KDBXParser.swift` — instrument `KDBXXMLParser` to record any XML element/attribute the structured branches don't consume into an `OpaqueXMLNodes` for the current entry/group/meta. Add a `KPMeta` struct and return it alongside the root group from `parse(...)`. Existing call sites that take only `KPGroup` get a thin overload that discards `KPMeta`, so slice 01 alone doesn't ripple through the app.
- **Modified:** `KeeForge/Models/Entry.swift` — add `unknownXML: OpaqueXMLNodes` (defaults to empty). Existing initializers stay source-compatible.
- **Modified:** `KeeForge/Models/Group.swift` — same.
- **New tests:** `KeeForgeTests/KDBXRoundTripTests.swift`.

The structured parser currently lives at `KeeForge/Models/KDBXParser.swift:545–...` (`KDBXXMLParser`). The cleanest instrumentation point is wherever an element is encountered without a known handler — record the element subtree verbatim, attached to the current building entry/group/meta. The verbatim form must include attributes and any nested unknown elements.

## KeeForge bits

- **Targets:** all new files belong to **both** `KeeForge` and `KeeForgeAutoFill` (the parser and models are already shared via `KeeForge/Models` glob; `KDBXXMLSerializer.swift` and `OpaqueXMLNodes.swift` join the same path and are picked up automatically).
- **project.yml:**
  - No changes (`KeeForge/Models` is already a glob path on both targets).
  - `Run xcodegen generate` is not needed for this slice.
- **Accessibility identifiers:** N/A — this slice has no view layer.

## Testing

Concrete scenarios.

- **Unit:** `KeeForgeTests/KDBXRoundTripTests.swift`
  - `test_parseSerializeParse_test_kdbx_returnsEqualTree` — parse `TestFixtures/test.kdbx`, serialize via `KDBXXMLSerializer`, re-parse the XML, assert the resulting tree (root group, all entries, custom fields, TOTP, passkey fields, recycle bin UUID) equals the original.
  - `test_parseSerializeParse_demo_kdbx_returnsEqualTree` — same for `TestFixtures/demo.kdbx`.
  - `test_parseSerializeParse_demoKeyfile_kdbx_returnsEqualTree` — same for `TestFixtures/demo-keyfile.kdbx`.
  - `test_unknownNodes_areCapturedAndReEmitted` — pick a fixture that contains a custom data element or KeePassXC custom icon (verify by hex-grep first; if none, add a small fixture under `TestFixtures/round-trip/`). Assert that the captured `unknownXML` is non-empty after parse and that serializing it back produces the same element tree.
  - `test_protectedValues_reEncryptedDeterministically_roundTrip` — assert that protected values survive a parse → serialize → parse cycle, where the inner stream key and the entry's `password` `EncryptedValue` decrypt to the same plaintext.
  - `test_serializerEmitsValidXML_isUTF8WithBOM` — assert the serializer emits the same XML preamble shape as KeePassXC (BOM + `<?xml version="1.0" encoding="utf-8" standalone="yes"?>`); compare the first bytes against a captured golden.
  - Run slice: `xcodebuild test -only-testing:KeeForgeTests/KDBXRoundTripTests`.
- **Integration / UI:** N/A — no app surface in this slice.
- **Manual:** N/A.
- **Edge cases that apply:**
  - A database that uses ChaCha20 inner-stream encryption (already exercised by `test.kdbx`).
  - A database with no protected values at all.
  - A database with empty groups, with empty custom fields, with `<History>` elements containing multiple historical revisions per entry.
  - A database whose root group has an attached `recycleBinUUID` — must round-trip into `KPMeta`.
  - Files where the parser previously encountered an unknown element and silently skipped — these were the original motivation for this slice.

## Exit criteria

- [ ] All round-trip unit tests pass on every fixture under `TestFixtures/`.
- [ ] No force unwraps in new code.
- [ ] Existing parser tests under `KeeForgeTests/KDBXParserTests.swift` still pass without modification (the new `KPMeta` return is exposed via an overload, so old call sites are unaffected).
- [ ] All serializer + parser work runs off the main actor; no `@MainActor` annotations on new types.
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Internal: KDBX parser now captures unknown XML elements verbatim, paving the way for lossless edits.`
