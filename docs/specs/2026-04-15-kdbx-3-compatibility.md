# KDBX 3.1 Compatibility — Implementation Plan

## Goal

Add **read/open compatibility for KDBX 3.1 databases** without destabilizing the existing KDBX 4.x parser and without committing KeeForge to legacy-format write support yet.

This plan is intentionally scoped to:
- **open / decrypt / parse KDBX 3.1 databases**
- preserve current **KDBX 4.x** behavior
- keep **write/save/export** focused on modern KDBX 4.x for now

## Recommendation

### KDF support
KeeForge should support the practical built-in KDF set used by KeePass-family apps:
- **AES-KDF**
- **Argon2d**
- **Argon2id**

That covers the official built-in KDFs that matter for mainstream compatibility.

Do **not** proactively implement arbitrary plugin/custom KDFs yet.
Instead:
- keep unsupported-KDF errors user-friendly
- surface unknown UUIDs clearly in logs / diagnostics
- optionally collect unknown KDF identifiers via opt-in error reporting if users choose to send diagnostics

### Older database formats
Recommended priority:
1. **KDBX 3.1 read/open support**
2. maybe later **KDBX 3.1 write/export**
3. **do not support KeePass 1.x `.kdb` yet**

KDBX 3.1 is still a realistic compatibility target. `.kdb` is much more legacy-heavy and lower value.

## Background

KeeForge currently targets **KDBX 4.x**. KDBX 3.1 differs in several meaningful ways:
- uses older outer header fields
- uses **AES-KDF** via `TransformSeed` + `TransformRounds`
- uses the older **hashed block stream** instead of the KDBX 4 HMAC block stream
- stores protected-field stream configuration differently
- stores binaries / attachments differently
- includes some XML / metadata differences from KDBX 4

So this is **not** a one-line compatibility toggle. It should be implemented as a deliberate parser split.

## Source References

Primary references:
- [KeePass KDBX Format Overview](https://keepass.info/help/kb/kdbx.html)
- [KeePass KDBX 4 Details](https://keepass.info/help/kb/kdbx_4.html)

These docs imply the practical format split:
- **KDBX 3.1**: AES-KDF + legacy header/block pipeline
- **KDBX 4.x**: VariantDictionary `KdfParameters`, extensible KDFs, HMAC-authenticated structure

## Product Decision

### What v1 should support
For the first KDBX 3.1 compatibility milestone, KeeForge should:
- open password-only **KDBX 3.1** databases
- support **AES-KDF** in both KDBX 3.1 and KDBX 4 contexts
- parse groups, entries, protected fields, history, and core metadata
- support common protected inner stream modes used in real databases
- preserve current KDBX 4 behavior

### What v1 should not promise yet
- KDBX 3.1 write/save
- KDBX 3.1 export
- KeePass 1.x `.kdb`
- arbitrary custom/plugin KDFs

## Parser Architecture Recommendation

Do **not** smear version checks throughout the current parser.

Instead, keep a clean high-level split:
- `parseKDBX4(...)`
- `parseKDBX3(...)`

with shared helpers for:
- XML mapping into app models
- AES-CBC decrypt
- protected field decryption helpers
- general entry/group parsing where possible

### Why this split matters
KDBX 3.1 vs 4.x differ in:
- header layout
- KDF metadata storage
- block stream format
- binary/attachment handling
- some metadata interpretation

A dedicated KDBX 3 path will be easier to reason about, test, and maintain.

## Implementation Plan

## Phase 1: Version Detection

**Modified file:** `KeeForge/Models/KDBXParser.swift`

Add explicit major/minor version dispatch:
- detect **KDBX 4.x** and route to existing flow
- detect **KDBX 3.1** and route to new compatibility flow
- reject unsupported legacy/unknown versions with a friendly error

Suggested shape:

```swift
static func parse(data: Data, password: String) throws -> Database {
    let version = try parseFileVersion(from: data)
    switch version {
    case .kdbx4(...):
        return try parseKDBX4(data: data, password: password)
    case .kdbx3_1:
        return try parseKDBX3(data: data, password: password)
    default:
        throw ParseError.unsupportedVersion(...)
    }
}
```

## Phase 2: KDBX 3.1 Outer Header Parsing

**Modified file:** `KeeForge/Models/KDBXParser.swift`

Implement KDBX 3.1 header parsing for the legacy fields, including at minimum:
- cipher ID
- compression flags
- master seed
- transform seed
- transform rounds
- encryption IV
- protected stream key
- stream start bytes
- inner random stream ID

### Important difference from KDBX 4
KDBX 3.1 uses:
- `TransformSeed`
- `TransformRounds`

instead of KDBX 4's:
- `KdfParameters` VariantDictionary

So KDBX 3.1 key derivation should use the old AES transform path directly from header fields.

## Phase 3: KDBX 3.1 Key Derivation

**Modified files:**
- `KeeForge/Models/KDBXParser.swift`
- `KeeForge/Models/KDBXCrypto.swift`

Use the already-added **AES-KDF** support as the crypto primitive, but wire it through the KDBX 3.1 header model.

Expected flow:
1. derive composite key from password / key file inputs as normal
2. apply KDBX 3.1 AES transform using `TransformSeed` + `TransformRounds`
3. combine with `MasterSeed`
4. derive final AES-CBC key material for database decryption

This should reuse the AES-KDF transform helper where possible.

## Phase 4: Legacy Block Stream Reader

**Modified file:** `KeeForge/Models/KDBXParser.swift`

KDBX 3.1 uses the older **hashed block stream**, not the KDBX 4 HMAC-protected block stream.

Add a separate block reader, for example:

```swift
private static func readHashedBlockStream(_ data: Data) throws -> Data
```

Responsibilities:
- iterate legacy blocks in sequence
- validate block hashes
- concatenate payload bytes
- stop on zero-length terminal block
- fail cleanly on corruption or truncated data

### Recommendation
Keep this separate from KDBX 4 block logic. Do not overload the KDBX 4 HMAC stream reader with a version flag unless it stays genuinely clean.

## Phase 5: Protected Field Stream Support

**Modified files:**
- `KeeForge/Models/KDBXParser.swift`
- `KeeForge/Models/KDBXCrypto.swift`

KDBX 3.1 stores protected field stream configuration in the outer header.

Need support for common inner random stream modes used in 3.1 databases:
- **Salsa20** (important)
- possibly **ArcFourVariant** (legacy / lower priority)

### Recommendation
- **Support Salsa20 in v1**
- if ArcFourVariant appears to be uncommon, return a clear unsupported error for now rather than adding risky legacy crypto immediately

This work is required to properly decrypt protected XML values like passwords and notes.

## Phase 6: XML / Metadata Compatibility Layer

**Modified file:** `KeeForge/Models/KDBXParser.swift`

Handle the important KDBX 3.1 XML and metadata differences, including:
- `HeaderHash` handling where relevant
- time / metadata normalization differences from KDBX 4
- binary / attachment metadata stored in XML instead of KDBX 4 inner header binary records

Recommendation:
- keep the app-facing `Database`, `Entry`, and `Group` model mapping shared where possible
- use a version-specific normalization step before mapping to app models

## Phase 7: Binary / Attachment Support

**Modified file:** `KeeForge/Models/KDBXParser.swift`

KDBX 3.1 stores binaries / attachments differently from KDBX 4.

For KDBX 3.1 support, implement reading of XML-based binaries so that:
- attachment references resolve correctly
- entry data remains faithful when opening older databases

### Scope option
If needed, this can be staged:
1. first milestone: open entries/groups/protected fields correctly
2. second milestone: complete attachment parity

But ideally, KDBX 3.1 open support should include attachments if the existing app UI already assumes they are available.

## Phase 8: Errors and User Messaging

**Modified files:**
- `KeeForge/Models/KDBXCrypto.swift`
- `KeeForge/Views/UnlockView.swift` (if needed)

Add clear unsupported / failure messages for:
- unsupported KDBX major version
- unsupported legacy inner random stream
- corrupted hashed block stream
- malformed legacy header

Examples:
- `This database uses an older KeePass format that KeeForge does not support yet.`
- `This database uses an unsupported protected-field stream.`
- `The database appears corrupted or incomplete.`

Avoid surfacing raw numeric IDs or UUIDs directly to normal users.

## Test Plan

### Unit / parser fixtures to add
Create KDBX 3.1 fixtures covering:
- KDBX 3.1 + AES-KDF + AES-CBC
- compression enabled
- compression disabled
- protected password fields
- nested groups
- history entries
- attachments / binaries
- malformed header
- wrong password case
- corrupted hashed block case

### Assertions
Add tests that verify:
- correct version dispatch into KDBX 3.1 path
- AES-KDF transform works in KDBX 3.1 context
- hashed block stream validation works
- protected fields decrypt correctly
- groups / entries / history parse correctly
- attachment references resolve correctly
- wrong password and corrupted-file failures are distinct and friendly

### Suggested test names
- `testKDBX31PasswordOnlyDatabaseOpens()`
- `testKDBX31CompressedDatabaseOpens()`
- `testKDBX31ProtectedFieldsDecrypt()`
- `testKDBX31HistoryEntriesParse()`
- `testKDBX31AttachmentsParse()`
- `testKDBX31WrongPasswordFailsCleanly()`
- `testKDBX31CorruptedHashedBlockFails()`
- `testUnsupportedLegacyInnerStreamShowsFriendlyError()`

## File-Level Impact

Likely files to change:
- `KeeForge/Models/KDBXParser.swift`
- `KeeForge/Models/KDBXCrypto.swift`
- `KeeForgeTests/KDBXParserTests.swift`

Possible new helper files if the parser split gets large enough:
- `KeeForge/Models/KDBX3Parser.swift`
- `KeeForge/Models/KDBX3Header.swift`
- `KeeForge/Models/KDBX3BlockStream.swift`

### Recommendation on structure
If KDBX 3 support grows beyond a few hundred lines, split it into dedicated files rather than turning `KDBXParser.swift` into a format graveyard.

## Scope / Milestones

### Milestone 1: KDBX 3.1 basic open
- version detection
- legacy header parsing
- AES-KDF via legacy transform fields
- hashed block stream
- Salsa20 protected fields
- entry/group parsing

### Milestone 2: KDBX 3.1 parity polish
- attachments / binaries
- better error messaging
- more fixture coverage
- edge-case metadata compatibility

### Deferred
- KDBX 3.1 write/export
- KeePass 1.x `.kdb`
- arbitrary custom/plugin KDFs
- ArcFourVariant support unless real-world samples justify it

## Estimated Effort

### Read/open only
**Moderate effort**

Expected size:
- roughly **2 to 4 focused implementation slices**
- more if full attachment parity or broad legacy fixture coverage is required in the first pass

### Read + write
**Meaningfully larger**

Why:
- requires old header writer path
- old hashed block stream writer
- attachment serialization compatibility
- stronger cross-app interoperability confidence

Recommendation: **do not include write support in the first KDBX 3.1 compatibility milestone**.

## Product Positioning

Suggested user-facing stance:

> KeeForge supports modern KeePass databases and legacy KDBX 3.1 read compatibility.

That gives users useful compatibility without promising full legacy-format round-trip behavior yet.

## Summary

Recommended roadmap:
1. keep KDF support at **AES-KDF + Argon2d + Argon2id**
2. do not proactively add custom/plugin KDF implementations
3. add **KDBX 3.1 read/open support** as a dedicated parser path
4. defer KDBX 3.1 write/export until there is clear user demand
5. ignore `.kdb` for now

This gives KeeForge the highest-value compatibility win without dragging the parser into unnecessary legacy complexity.
