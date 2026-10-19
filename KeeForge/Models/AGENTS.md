# Models

**Scope:** the KDBX core (parse, write, crypto, merge, draft edits) and the value types the app and both AutoFill extensions share. The most security-sensitive folder in the repo. Foundation/CryptoKit only: no UIKit/AppKit, no `@MainActor`; callers run parsing, KDF, and merge off the main actor.

## Ownership

The root `AGENTS.md` lists the stable-core files and when they may change. Most invariants are explained at their site; read the type's header comment before editing it. What is easy to get wrong:

- `KDBXXMLSerializer` owns all XML emission; `KDBXWriter` owns framing, header, and key derivation. Nothing else builds KDBX bytes.
- `DatabaseDraft` is the only way to change a tree. `KPGroup` is a reference type: copy through `deepCopy()` before staging a change.
- A structured field is one the serializer writes from the model. Everything else is replayed from `unknownXML` at its recorded insertion index, and its model property is a read-only display copy: an entry's `customIconUUID`, `expiryTime` / `expires`, and all of `Meta/CustomIcons`. Edit those by splicing the preserved XML (`EntryExpiryXML`, `CustomIconXML`, the draft's icon edits) and update the display copy in the same edit.
- `EntryHistoryTrimmer` is the one `HistoryMaxItems` / `HistoryMaxSize` policy, shared by the draft and the merger so they cannot disagree about which versions survive.
- `TagNormalizer` is edit-side only. Parsed `tags` are never deduped, reordered, or rewritten on read; the parser has its own dedupe-free split.
- `KDBXUUIDEncoding` and `KDBXDateEncoding` are the single encoders behind both the serializer and the spliced fragments.

## Invariants

### Round-trip

- Unknown XML, protected fields, history, the binary pool, custom icons, and unknown outer/inner header fields survive a save byte-exact. An unrelated edit must not change a foreign database.
- Element positions are load-bearing. Opaque insertion indices count known children in KeePass's element order, so the serializer must emit each structured element at that position.
- A structured element counts as known only under the exact conditions its parse handler accepted it. Keep the handler's guards and `recordOpaqueXML` identical, or every opaque fragment after it shifts.
- Optional elements are three-state (`<EnableSearching>`, group `<Tags>` / `<Notes>`, `locationChanged`): absent stays absent. Never invent an element the source did not have.
- When an edit makes a preserved element structured, drop the preserved copy (`removeDirectChildren(named:)`) so the writer never emits a duplicate that outranks it.
- Every `KPGroup` construction site forwards `tags`, `hasTagsElement`, `notes`, `hasNotesElement`, or the fields vanish on the next unrelated edit. `GroupScalars` in the compatibility support pins this.
- Imported group names and `String` / `Binary` keys keep their whitespace. Only authoring trims.
- Unknown inner-header fields are re-emitted in their original relative order before the pool, not at their old offsets among pool entries. Deliberate: KDBX 4 defines no ordering and KeePassXC skips unknown IDs.
- `EntryHistoryTrimmer` chooses survivors by recency but keeps storage order. KeePass appends history oldest-first and this app prepends, so choosing by position drops a foreign file's newest versions and sorting rewrites its bytes.

### Format and limits

- Read supports KDBX 3.1 and 4.x; write is KDBX 4 only with the ChaCha20 inner stream. 3.1 sources are read-only and the writer throws `unsupportedSourceFormat`.
- The header minor version is `max(required, existing)`, never a downgrade. Only a group `<Tags>` element requires 4.1. Do not write another 4.1-only element (custom-icon `<Name>` / `<LastModificationTime>` included) without accepting that silent format upgrade.
- Every save rotates master seed, IV, inner stream key, and KDF salt; only KDF cost parameters carry over.
- `KDBXCrypto.maxDecompressedSize` is 256 MiB. `gunzip` refuses output over it, so the writer throws `payloadTooLarge` for a compressed payload over it rather than write a file it could not reopen. Uncompressed payloads have no limit on either side.
- Every parse and write takes an explicit `KDFExecutionPolicy`: `.mainApp` in the apps, `.autoFillExtension` in the extensions. They differ only in peak memory (4 GiB vs 512 MiB); total work (64 GiB) and parallelism (256) are identical so one context never refuses a vault the other opens.
- KDF parameters run exactly as stored or are rejected, never clamped. Format-invalid values throw `kdfParameterOutOfRange`; over-budget values throw `kdfResourceLimitExceeded`.
- The serializer rejects XML 1.0-invalid scalars in everything it emits, as the final write barrier. Authoring also runs `KDBXXMLSerializer.validateText` before staging, so rejected text never enters the draft or a history snapshot.
- Twofish uses strict PKCS#7 validation. Do not add permissive padding recovery without a sanitized interoperability fixture that proves it is needed.

### Secrets

- Native KeePass TOTP uses `TimeOtp-Secret`, `-Hex`, `-Base32`, or `-Base64` in that precedence order. `TOTPConfig.keePassSecretField` keeps the active field and `decodedSecret` keeps the effective bytes for non-Base32 secrets. An unchanged draft preserves that field; a new secret is written as Base32.
- `TimeOtp-Algorithm` uses KeePass's `HMAC-SHA-*` names. `TOTPAlgorithm.rawValue` remains the short `otpauth` and KeeOTP token. The serializer writes `keePassName`; the parser also accepts the short names that earlier KeeForge versions wrote.
- Secrets stay sealed as `EncryptedValue` under the session key until the point of use. `EncryptedValue` re-seals with a fresh nonce, so equal secrets never have equal ciphertext: compare plaintext.
- The passkey private key PEM is diverted out of `customFields` into `KPEntry.passkeyPrivateKey` at parse time and re-emitted by the serializer at its original sorted custom-field position. It is decrypted only at signing time.
- `EntryDraftPayload.protectedCustomFieldKeys` decides which created custom fields serialize `Protected=True`. AutoFill passkey registration relies on it for the `KPEX_PASSKEY_*` fields.
- The composite key travels as a `SymmetricKey`. Transient key material in `Data` or arrays is wiped with `SecureWipe`, and only buffers this code created and uniquely owns (a shared buffer copies on mutation, so the wipe misses the original).
- Pre-size multi-append key buffers with `Data(capacity:)`, or a reallocation leaves the earlier bytes unwiped.
- `FieldReferenceResolver` is read-side only (display, copy, AutoFill fill). Never run it on an edit, save, or export path: a resolved value written back replaces the reference with its target. Unresolvable references stay literal, as in KeePass.
- A password import preview holds plaintext; keep it only while the import screen is open. Files over `PasswordImport.maximumFileSize` (16 MiB) are refused before parsing.

### Draft edits

- Recycling stores the standard optional `<PreviousParentGroup>` reference in opaque XML; like KeePass it does not force a 4.1 header. Recovery reparents only from the recycle subtree to a destination outside it, preserving fields, subtree contents, and modification times. Recovery permits duplicate sibling names to avoid renaming restored data.
- Only a reparent writes `LocationChanged`: move, and recycle (which is a move). New objects get `locationChanged == creationTime`. `LastModificationTime` does not change on a move.
- `<EnableSearching>` gates both `KPGroup.autoFillEntries` and the search corpus in `DatabaseViewModel`, resolved in the same inheritance order. Change both together. Browsing and the tag browser use `allEntries`.
- Choosing a standard icon removes the `<CustomIconUUID>` element as well as the display copy: a custom icon outranks `<IconID>` in KeePass and would hide the choice.
- `addEntryCustomIcon` splices into the preserved `<CustomIcons>` fragment and never rebuilds it. A fragment it cannot splice fails the edit; rebuilding from decoded icons would drop data this app does not model.
- `EntryDraftPayload.attachments` and `.expiry` are `nil` for "leave alone", so a caller that never shows them (AutoFill) cannot drop or rewrite them. An expiry equal to the current one is a no-op.
- The binary pool is append-only: refs are never renumbered and entries never removed, so a removed attachment's bytes stay for history. New files reuse an identical pool entry or append with the `0x01` flag KeePassXC writes. Dangling refs resolve to `nil`.
- An append is refused if it would take an index a dangling ref already names (`attachmentWouldClaimMissingReference`), or take the pool past `maxDecompressedSize` whatever the compression, since compression can be enabled later (`attachmentsTooLarge`).
- `restoreEntryVersion` takes user-visible fields and expiry XML from the snapshot; `id`, `creationTime`, location, other `unknownXML`, and `customIconUUID` stay with the live entry.
- `creatingEntries(_:inGroup:)` must leave the same tree and `pendingEdits` as one `.createEntry` per draft in order.

### Merge

- `KDBXMerger` mirrors KeePass 2.x Synchronize / KeePassXC: UUID matching across the tree, newest `LastModificationTime` wins per entry with the loser pushed to history, `LocationChanged` decides moves, tombstones are unioned with timestamp-gated deletion and edit-after-delete resurrection.
- Both sides must be parsed with the same session key. The result aliases neither input.
- It declines rather than guesses. The only blocker is a diverged binary pool that something references, because the merged tree is written with the local pool and refs are never renumbered.
- A local pool that only extends the remote's is not divergence, unless a remote ref (history included) points into the extension.
- Merging the same remote twice is a no-op. Summary counters are deltas against local, and a losing version is pushed only when an equal snapshot is not already in history.

### Interoperability choices

- YubiKey challenge-response follows KeePassXC: the challenge is the KDF salt PKCS#7-padded to 64 bytes and the key is `SHA256(preKey || SHA256(response))`. KDBX 4 only (3.1 folds the response in after the KDF); a KDBX 4 file with the legacy AES-KDF UUID is accepted because KeePassXC writes it.
- `PasskeyCredential` reads KeePassXC `KPEX_PASSKEY_*` fields with ordered fallback to the legacy Strongbox / older KeePassXC names.
- `OTPAuthURI` keeps the trimmed input verbatim in `rawURI` for the protected `otp` field KeePassXC reads.
- `ApplePasswordsCSVImporter` rejects a CSV with any column it does not know, so no column is dropped unseen.

## Tests

Classes in `../../KeeForgeTests/` are named `<Type>Tests`. Non-obvious mappings:

- Any change to parse/write behaviour, draft edits, protected fields, or unknown XML also updates `KDBXCompatibilityTests` and `Support/KDBXCompatibilitySupport.swift`; see `../AGENTS.md`. Those tests emit the artifacts the external `keepassxc-cli` gate consumes.
- Writer and serializer: `KDBXWriterTests`, `KDBXRoundTripTests`. Merge: `KDBXMergerTests` plus `KDBXMergerOracleTests` (KeePassXC reference fixtures).
- `ChallengeResponseKeyTests` covers `HardwareKey.swift`; `AttachmentTests` covers `BinaryPool` and the draft's attachment edits; `PasskeyCredentialTests` and `PasskeyCryptoTests` are in `PasskeyTests.swift`.
- Fixtures that pin format behaviour are described in `../../TestFixtures/README.md`.

## See also

- `../AGENTS.md`: when a change must update the compatibility tests
- `../ViewModels/AGENTS.md`, `../Services/AGENTS.md`: session, save paths, and callers of the draft and merger
- `../../AutoFillExtension/AGENTS.md`: the extension that shares these sources
- `../../docs/README.md`, `../../docs/threat-model.md`, `../../Vendor/KeeForgeTwofish/README.md`, `../../ci_scripts/AGENTS.md`
