# Key File Support — Implementation Plan

## Background

KeePass supports **composite keys** — a master key derived from multiple components:
1. **Password** (what you know)
2. **Key file** (what you have)
3. Windows User Account (not applicable to iOS)

Currently KeeForge only supports password-only unlock. This plan adds key file support.

## KeePass Key File Spec

### Composite Key Derivation (KDBX 4.x)

The composite key is built by concatenating SHA-256 hashes of each component:

```
composite_key = SHA256(password_utf8) || SHA256(key_file_content)
```

Then the final pre-key is:
```
pre_key = SHA256(composite_key)
```

This pre-key feeds into the KDF (Argon2 or AES-KDF) as before.

**Important:** The order is `SHA256(password) || processKeyFile(keyFileData)`. If only a key file is used (no password), it's just `processKeyFile(keyFileData)`. If only a password, it's just `SHA256(password)`. The final result is always SHA256'd again.

### Key File Formats (4 types, tried in order)

1. **32 bytes exactly** → Use raw bytes as 256-bit key (binary format)
2. **64 hex chars exactly** (0-9, A-F, ASCII, one line) → Decode hex to 32 bytes
3. **XML format** (`.keyx` / `.key`) → Parse XML, extract key data
4. **Anything else** → SHA-256 hash of entire file contents (arbitrary file as key)

### XML Key File Formats

#### Version 1.0 (KeePass 2.x legacy `.key`)
```xml
<?xml version="1.0" encoding="utf-8"?>
<KeyFile>
  <Meta>
    <Version>1.0</Version>
  </Meta>
  <Key>
    <Data>BASE64_ENCODED_32_BYTES</Data>
  </Key>
</KeyFile>
```
- `<Data>` contains base64-encoded 32-byte key

#### Version 2.0 (KeePass 2.51+ `.keyx`)
```xml
<?xml version="1.0" encoding="utf-8"?>
<KeyFile>
  <Meta>
    <Version>2.0</Version>
  </Meta>
  <Key>
    <Data Hash="FIRST_4_BYTES_OF_SHA256_AS_HEX">
      HEX_ENCODED_32_BYTES
    </Data>
  </Key>
</KeyFile>
```
- `<Data>` contains hex-encoded 32-byte key (whitespace allowed, stripped before parsing)
- `Hash` attribute = first 4 bytes of SHA-256(key_bytes), hex-encoded, for integrity check
- More robust against encoding/newline corruption

### Reference: KeePassium Implementation

From `KeyHelper.swift`:
```swift
func processKeyFile(keyFileData: SecureBytes) -> SecureBytes {
    // 1. Exactly 32 bytes → raw binary key
    if keyFileData.count == 32 { return keyFileData }
    
    // 2. Exactly 64 bytes → try ASCII hex decode
    if keyFileData.count == 64 {
        if let key = keyFileData.interpretedAsASCIIHexString() { return key }
    }
    
    // 3. Try XML parse
    if let key = processXmlKeyFile(keyFileData) { return key }
    
    // 4. Fallback: SHA-256 of entire file
    return keyFileData.sha256
}
```

From `KeyHelper2.swift` (KDBX 4.x composite key):
```swift
func combineComponents(passwordData: SecureBytes, keyFileData: SecureBytes) -> SecureBytes {
    var preKey = empty
    if hasPassword { preKey = concat(preKey, SHA256(passwordData)) }
    if hasKeyFile  { preKey = concat(preKey, processKeyFile(keyFileData)) }
    return preKey
}

func getKey(fromCombinedComponents combined: SecureBytes) -> SecureBytes {
    return SHA256(combined)  // Final SHA-256 of concatenated hashes
}
```

## Implementation Plan

### Phase 1: Key File Parser (`KeyFileProcessor.swift`)

**New file:** `KeeForge/Services/KeyFileProcessor.swift`

```swift
struct KeyFileProcessor {
    /// Process key file data into a 32-byte key
    static func processKeyFile(_ data: Data) throws -> Data
    
    // Internal: try each format in order
    static func tryBinaryFormat(_ data: Data) -> Data?      // 32 bytes exact
    static func tryHexFormat(_ data: Data) -> Data?          // 64 hex chars
    static func tryXMLFormat(_ data: Data) throws -> Data?   // XML v1.0 or v2.0
    static func hashFallback(_ data: Data) -> Data           // SHA-256 of file
}
```

- Use Foundation `XMLParser` (no dependencies) for XML key files
- Validate v2.0 hash attribute if present
- Return 32-byte `Data` in all cases

### Phase 2: Update KDBX Parser Composite Key

**Modified file:** `KeeForge/Models/KDBXParser.swift`

Current: `deriveKey(password:)` takes only password string
Change to: `deriveKey(password:keyFileData:)` takes optional key file data

```
Current flow:
  SHA256(SHA256(password_utf8)) → KDF → master key

New flow:
  preKey = []
  if password: preKey += SHA256(password_utf8)
  if keyFile:  preKey += KeyFileProcessor.processKeyFile(keyFileData)
  SHA256(preKey) → KDF → master key
```

### Phase 3: Unlock View UI

**Modified file:** `KeeForge/Views/UnlockView.swift`

Add below the password field:
- **"Key File" row** — shows "None" or selected filename
- **Tap to select** → iOS document picker (`.key`, `.keyx`, or any file)
- **Clear button** (x) to remove selected key file
- Key file data stored in `@State var keyFileData: Data?`

The key file selection should use `UIDocumentPickerViewController` with UTTypes:
- `public.item` (allow any file — KeePass supports arbitrary files as key files)

### Phase 4: Key File in AutoFill Extension

**Modified file:** `AutoFillExtension/CredentialProviderViewController.swift`

- Store selected key file path as a bookmark in `UserDefaults` (app group shared)
- When AutoFill triggers, read key file from bookmarked URL
- Pass to parser alongside password

### Phase 5: Persistence

- Remember last used key file path per database (keyed by database filename)
- Store as security-scoped bookmark in `UserDefaults` (shared app group)
- On unlock, resolve bookmark → read file → pass to parser
- If bookmark stale, prompt user to re-select

### Testing

1. **Unit tests:**
   - `KeyFileProcessorTests.swift` — test all 4 formats (binary, hex, XML v1, XML v2)
   - Test composite key derivation with password+keyfile, keyfile-only, password-only
   
2. **Test fixtures:**
   - Create test `.key` (XML v1), `.keyx` (XML v2), binary key file, hex key file
   - Create `demo-keyfile.kdbx` with password "demo" + key file

3. **Integration test:**
   - Unlock `demo-keyfile.kdbx` with both password and key file
   - Verify entries are readable

## Scope for v1.4.0

**In scope:** Phases 1-3 + testing (core key file support in main app)
**Deferred:** Phase 4-5 (AutoFill + persistence) — can ship in v1.4.1

## Estimated Effort

- Phase 1 (parser): ~2 hours
- Phase 2 (KDBX integration): ~1 hour  
- Phase 3 (UI): ~2 hours
- Testing: ~2 hours
- **Total: ~7 hours** — good candidate for a Claude Code agent session

## References

- [KeePass Key File Docs](https://keepass.info/help/base/keys.html)
- [KDBX4 Format (Wladimir Palant)](https://palant.info/2023/03/29/documenting-keepass-kdbx4-file-format/)
- [KeePassium KeyHelper2.swift](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/db/kp2/KeyHelper2.swift)
- [KeePassium KeyHelper.swift](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/db/KeyHelper.swift)
