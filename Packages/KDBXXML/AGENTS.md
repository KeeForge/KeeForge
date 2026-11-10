# KDBXXML

**Scope:** the KeePass database XML (`<KeePassFile>`) as a standalone Swift package: reading the decrypted payload into a typed `KDBXDocument`, writing one back, the protected-value mask, the KDBX value encodings, and preserving every element it does not model. The container around the XML is `../KDBXKit`; what the strings mean (standard fields, TOTP, passkeys), session-key sealing, and KeeForge's model are in `../../KeeForge/Models/` (`KDBXParser`, `KDBXWriter`).

## Invariants

- No KeeForge types, no UI frameworks, no app policy, no user-facing text, no logging. The package depends on Foundation and on KDBXKit only for `KDBXInnerStream`. Errors are plain enums; the app's text for them is in `../../KeeForge/Models/KDBXXML+Localization.swift`, so a new case needs a message there in every shipped locale.
- Round-trip: an element the document does not type is kept verbatim in the owner's `OpaqueXMLNodes`, at the count of typed siblings before it, and written back there. A foreign payload read, written, and read again is equal, and a second write is byte-identical (`RoundTripTests`).
- One decision per element. The reader gives every element a role from its parent's role when it opens (`DocumentReader.role`), and when it closes, the container's `take` either stores it as typed data and counts it, or records it as a fragment. Nothing else counts positions, so parsing and positioning cannot disagree. An element outside its container (an `<Entry>` in `<CustomData>`, a `<LastModificationTime>` in a `CustomData` item) is a leaf, never typed.
- An element is typed only when its value reads. An unreadable optional value (`EnableSearching`, a `Times` date, a `Meta` setting, a `Binary` without a numeric `Ref`) stays a fragment, so it survives. Elements the writer always emits (`UUID`, `Name`, `IconID`, `IsExpanded`) are typed with a default instead.
- The writer emits typed children in a fixed KeePass order and counts them the same way. A typed child replaces any direct fragment of the same name in its container (`Children.supersede`); repeatable elements (`Entry`, `Group`, `String`, `Binary`) are never replaced.
- Protected values are one keystream in document order, opaque ones included. The reader unmasks every `Protected="True"` value as it closes; the writer masks each typed field and each fragment value only when it emits it, never while building a child ahead of the fragments before it. An unreadable protected value fails the read (`invalidProtectedValue`) rather than desync every later value. Plaintext that is not UTF-8 reads with replacement characters, as in KeePassXC.
- Fragments are canonical (see `OpaqueXMLNodes`): paired tags, sorted double-quoted attributes, `& < > CR` escaped. The writer's protected-value scan and the typed views rely on it; code that splices fragments must produce it. Comments are dropped and CDATA becomes text.
- `Group.customIconUUID`, `Entry.customIconUUID`, `expiryTime`, `expires`, and `Meta.customIcons` are views computed from fragments. They are never stored, so they cannot disagree with what is written.
- The writer validates everything it emits against XML 1.0 `Char` (`validate(text:)`), protected values excepted because they are base64 on disk.

## Protected plaintext

- `Field.value` and fragment text hold protected values as plaintext `String`s on purpose. Reading makes several short-lived unwiped copies per value (the XOR output, its `String`, the escaped and rendered leaf) and the document keeps one until it is released; writing makes a few more. A wiping byte type or caller-supplied seal/unseal closures would remove these copies but not the exposure: the decrypted payload `KDBXContainer.read` returns, and its decompression copies, hold the inner-stream key next to every masked value and are freed unwiped; the app keeps protected custom fields and `otp` as plaintext `String`s for the whole session; and open and save run while the session is unlocked, where the threat model already assumes memory inspection wins.
- Change this only as one step with the rest: KDBXKit wipes its payload buffers and inner-stream state, and the app seals every protected field. The package's part is then an opaque protected value backed by wiping bytes (raw bytes, so non-UTF-8 plaintext round-trips too), not closures: it keeps `KDBXDocument` a plain `Hashable`, `Sendable` value with no generic sealed type, and a closure only narrows the window while unlocked, which buys nothing. KeePassium and Strongbox both unmask into plaintext strings and keep them while the database is open; KeePassium wipes its decrypted XML and unmask buffers, which buys little once each value is an unwipeable `String`.

## Public surface

- `KDBXDocument` with `read(xml:innerStreamID:innerStreamKey:)`, `serialized(innerStream:innerStreamKey:)`, and `validate(text:)`; its nested value types `Meta`, `Root`, `Group`, `Entry`, `Times`, `Field`, `BinaryReference`, `DeletedObject`, `InheritableBool`, `CustomIcon`; `ReadError` and `WriteError`.
- `OpaqueXMLNodes` and its `Node`, which the app edits to splice preserved elements.
- `UUID.kdbxBase64String`, `Date.kdbxBase64String`, `Date(kdbxBase64String:)`, `Date.kdbxStoredDate`: the single encoders for the writer and the app's spliced fragments.
- The reader, writer, text escaping, and the text forms of `InheritableBool`, dates (ISO 8601 included), and UUIDs stay internal. Widen the surface only for a caller that needs it.
- Callers pass the stream ID or algorithm and key, never a stream, so a stream can never be reused mid-way. KDBX 4 saves use ChaCha20.

## Tests

- `Tests/KDBXXMLTests` covers the package with `@testable import KDBXXML`. Prefer known answers: `FixtureReadTests` reads payloads KeePassXC and pykeepass wrote (`Tests/KDBXXMLTests/Fixtures/README.md`) and checks values from `../../TestFixtures/README.md`; `ValueEncodingTests` checks dates against the .NET epoch and KeePassXC output. Writer tests compare exact XML.
- `scripts/coverage.sh` runs the suite and fails below its line, region, and function floors (all 100%). Swift has no branch records, so region coverage is the branch measure. Raise coverage by testing; do not lower a floor or exclude code to land a change. Code that cannot run is removed, not excluded.
- CI runs the script in the `macos-unit-tests` job (`../../.github/workflows/tests.yml`). Locally, run it under the repo Xcode lock.
- App tests get the package's symbols from the host app, as with KDBXKit. They cover what the app adds: the mapping in `KDBXParser`/`KDBXWriter` (`KDBXParserTests`, `KDBXRoundTripTests`, `ChaCha20Tests`), draft edits that splice fragments, and the KeePassXC gate in `KDBXCompatibilityTests`.
