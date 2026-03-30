# AGENTS.md

Context for AI coding agents working on KeeForge.

## Overview

iOS KeePass password manager (KDBX 4.x, read-only in v1). Swift 6, SwiftUI, iOS 17+, MVVM with `@Observable`. Build system: XcodeGen (`project.yml` → `.xcodeproj`).

## Architecture

```
KeeForge/
├── App/
│   └── KeeForgeApp.swift          # App entry, scene lifecycle, auto-lock on background
├── Models/
│   ├── KDBXParser.swift           # KDBX 4.x binary format → XML → KPGroup/KPEntry tree
│   ├── KDBXCrypto.swift           # AES-256, ChaCha20, HMAC-SHA256, Argon2, gzip
│   ├── Group.swift                # KPGroup model (tree of groups + entries)
│   ├── Entry.swift                # KPEntry model (title, username, password, URLs, TOTP, passkey)
│   ├── PasskeyCredential.swift    # FIDO2 passkey model parsed from KPEX_PASSKEY_* fields
│   ├── EncryptedValue.swift       # AES-GCM wrapper for in-memory secret protection
│   └── TOTPGenerator.swift        # RFC 6238 TOTP generation
├── ViewModels/
│   ├── DatabaseViewModel.swift    # Main VM: unlock, lock, search, sort, state machine, backoff
│   └── TOTPViewModel.swift        # Live TOTP code + countdown timer
├── Views/
│   ├── UnlockView.swift           # Password entry + key file picker + Face ID + auto-unlock
│   ├── GroupListView.swift        # Group/entry navigation (excludes Recycle Bin)
│   ├── EntryDetailView.swift      # Entry detail: fields, TOTP, passkey section, timestamps
│   ├── EntryListView.swift        # Flat entry list within a group
│   ├── SearchView.swift           # Search results overlay
│   ├── FaviconView.swift          # Favicon image with fallback chain (cached → fetch → iconID)
│   ├── SettingsView.swift         # Settings page (security, display, about, feedback)
│   └── TipJarView.swift           # StoreKit 2 tip jar (3 tiers)
├── Services/
│   ├── BiometricService.swift     # Face ID / Touch ID availability + authentication
│   ├── KeychainService.swift      # Composite key storage with biometric access control
│   ├── SettingsService.swift      # UserDefaults persistence (some shared via App Group)
│   ├── SharedVaultStore.swift     # App Group shared storage (database bookmark)
│   ├── CredentialMatcher.swift    # URL matching for AutoFill
│   ├── CredentialIdentityStoreManager.swift # QuickType credential store
│   ├── ClipboardService.swift     # Copy with auto-expiry
│   ├── DocumentPickerService.swift # File bookmark management
│   ├── CoordinatedFileReader.swift  # Security-scoped coordinated file access
│   ├── FaviconService.swift        # Favicon fetch (DuckDuckGo) + disk cache with TTL
│   ├── KeyFileProcessor.swift     # Binary, hex, XML v1/v2, arbitrary file key processing
│   ├── ReviewPromptService.swift  # App Store review prompt logic
│   ├── ScreenProtectionService.swift # Blur overlay when screen is captured/recorded
│   ├── StoreKitManager.swift      # StoreKit 2 IAP manager (tip jar)
│   ├── PasskeyCrypto.swift        # ECDSA P-256 assertion signing for passkey auth
│   └── HapticService.swift        # Haptic feedback
├── Extensions/
│   └── NavigationConformances.swift
└── Resources/

AutoFillExtension/
├── CredentialProviderViewController.swift  # ASCredentialProviderViewController (password + passkey)
└── AutoFillSearchView.swift               # Search UI for AutoFill credential selection

KeeForgeTests/          # Unit tests
KeeForgeUITests/        # UI tests (XCUITest)
TestFixtures/           # Test databases and key files
```

## Data Flow

```
.kdbx file → KDBXParser.parse(data:compositeKey:sessionKey:)
  → Decrypts binary (AES/ChaCha20 + Argon2 key derivation)
  → Decompresses (gzip)
  → Parses XML → KPGroup tree (with recycleBinUUID on root)
  → Passwords & TOTP secrets re-encrypted with sessionKey as EncryptedValue (AES-GCM)
  → DatabaseViewModel stores rootGroup + sessionKey
  → Views decrypt on demand (copy, reveal, TOTP generation)
  → On lock: sessionKey nilled, EncryptedValues become undecryptable
```

## Key Patterns

- **State machine:** `DatabaseViewModel.State` = `.locked` → `.unlocking` → `.unlocked` / `.error(String)`
- **Lock cycle tracking:** `lockCycleID` increments on each lock, used to prevent auto-unlock retry loops
- **Exponential backoff:** `failedAttempts` counter with `lockoutDelay` = 0 for first 3 attempts, then 2s→4s→8s→16s→30s cap
- **Recycle Bin:** parsed from `<RecycleBinUUID>` in XML metadata, stored as `recycleBinUUID` on root `KPGroup`. Excluded from search, AutoFill, and group navigation
- **Composite keys:** `KDBXParser.deriveKey(password:keyFileData:)` — `SHA256(password_utf8) || processKeyFile(keyFileData)` → `SHA256(preKey)` → KDF
- **Settings storage:** Most settings in `UserDefaults.standard`. Settings shared with AutoFill extension (like `autoUnlockWithFaceID`) use `UserDefaults(suiteName: SharedVaultStore.appGroupID)`
- **App Group:** `group.com.keevault.shared` — shared between main app and AutoFill extension for database bookmark + shared settings + favicon cache
- **Favicons:** Opt-in via `SettingsService.showWebsiteIcons` (off by default). `FaviconService` fetches from DuckDuckGo, caches to App Group container (`favicons/` directory) with SHA256(domain) filenames and 7-day TTL
- **Screen protection:** `ScreenProtectionService` monitors `UIScreen.capturedDidChangeNotification` and shows a blur overlay window at `.alert + 1` level with lock icon
- **Passkeys:** `PasskeyCredential` model parsed from `KPEX_PASSKEY_*` custom fields. `PasskeyCrypto` handles ECDSA P-256 assertion signing. AutoFill extension responds to `ASPasskeyCredentialRequest`

## Conventions

- `@Observable`, not `ObservableObject`/`@Published`
- `NavigationStack` + `NavigationPath`, not `NavigationView`
- Swift 6 strict concurrency (`Sendable` correctness, `SWIFT_STRICT_CONCURRENCY_CHECKS = complete`)
- Crypto/parsing off main thread
- No force unwraps outside tests
- No external SPM dependencies (Argon2Swift is the sole exception)
- Accessibility identifiers for testable UI elements (see list below)

### Accessibility Identifiers

```
unlock.password.field       # Password SecureField
unlock.button               # Unlock action button
unlock.error.label          # Error message label
unlock.keyfile.row          # Key file selection row
unlock.keyfile.select       # Select key file button
unlock.keyfile.clear        # Clear key file button
unlock.choose-different     # Choose Different File button
lock.button                 # Lock database button
sort.menu                   # Sort menu in toolbar
settings.button             # Settings button
group.navlink               # Group navigation link
entry.navlink               # Entry navigation link
entry.password.reveal       # Password reveal/hide toggle
entry.copy.password         # Copy password
entry.copy.url              # Copy URL
entry.copy.totp             # Copy TOTP code
entry.copy.<field>          # Copy any field (label lowercased, spaces → underscores)
entry.url.open              # Open URL in browser
search.results.count        # Search result count (UI testing only)
search.no-results           # No search results view
```

## Adding a New Setting

1. Add key to `SettingsService.Key`
2. Add computed property in `SettingsService` (use `sharedDefaults` if AutoFill needs it)
3. Add `@State` in `SettingsView` + UI control + `.onChange` handler
4. Add tests in `SettingsServiceTests`
5. If AutoFill needs the setting, ensure `SettingsService.swift` is in AutoFill target sources (`project.yml`)

## Security

- **Lazy decrypt:** Passwords and TOTP secrets are stored as `EncryptedValue` (AES-GCM sealed data) in memory, not plaintext `String`. A per-session `SymmetricKey` is generated at unlock and passed through the parser. Secrets are only decrypted into transient local variables at the point of use (copy, reveal, AutoFill, TOTP generation). The session key is nilled on lock, making all `EncryptedValue`s undecryptable.
- `EncryptedValue.hasValue` allows checking emptiness without decrypting (e.g. `entry.hasPassword`)
- Composite key stored in Keychain with biometric access control
- Never store raw master password
- Auto-lock on background, clear sensitive state
- Clipboard auto-expires (configurable, default 30s, `.localOnly`)
- No analytics or telemetry. Network calls only for opt-in favicon fetching (domain only, no credentials)
- Face ID required to reveal/copy passwords
- Screen recording detection — blur overlay when `UIScreen.isCaptured` is true
- Exponential backoff on failed password attempts (2s→4s→8s→16s→30s cap)

## Stable Core (change only for real bugs)

- `KDBXParser.swift` — KDBX 4.x parsing, decryption, XML extraction
- `KDBXCrypto.swift` — AES, ChaCha20, HMAC, gzip, key derivation
- `Entry.swift`, `Group.swift` — data models
- `TOTPGenerator.swift` — RFC 6238

## Build & Test

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Build
xcodebuild build -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Run ONLY relevant unit tests (preferred — fast feedback)
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:KeeForgeTests/KDBXParserTests -quiet

# Run all unit tests (no UI tests)
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:KeeForgeTests -quiet
```

If simulator gets stuck with "preflight checks" error:
```bash
xcrun simctl shutdown all && xcrun simctl erase <UDID>
```

### ⚠️ Test Execution Rules

**ALWAYS use `-only-testing:` to run only the relevant test class(es).** The full test suite (especially UI tests) takes a very long time. Never run all tests unless explicitly asked.

Examples:
```bash
# Parser changes → run parser tests
-only-testing:KeeForgeTests/KDBXParserTests

# Credential store changes → run credential store tests  
-only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests

# TOTP changes → run TOTP tests
-only-testing:KeeForgeTests/TOTPGeneratorTests

# Multiple relevant test classes
-only-testing:KeeForgeTests/KDBXParserTests -only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests
```

**NEVER run UI tests (`KeeForgeUITests`) unless explicitly asked.** They require simulator boot + full app launch and take minutes.

## Testing

- Every feature and bug fix should include automated tests
- Unit tests for logic, UI tests for user-facing flows
- If a bug is found, write a regression test first, then fix
- Run only the relevant test class(es), not the full suite

### Test Targets

| Target | Type | Bundle ID |
|--------|------|-----------|
| KeeForgeTests | Unit tests | `com.keevault.app.tests` |
| KeeForgeUITests | UI tests (XCUITest) | `com.keevault.app.uitests` |

### Test Fixture

`TestFixtures/test.kdbx` (password: `testpassword123`) contains:
- **Root** group (top-level, no entries directly)
  - **Empty** group (0 entries)
  - **Social** group: Twitter (with 2 history entries), Discord (with TOTP), Offline Key, Public Profile
  - **Work** group: Email, GitHub (with TOTP)

`TestFixtures/demo.kdbx` (password: `password`) — richer demo database with TOTP entries, used for App Store screenshots.

Key file test fixtures: `test-binary.key`, `test-hex.key`, `test-v1.key`, `test-v2.keyx`, `test-arbitrary.key`, `demo-keyfile.kdbx` + `demo-keyfile.key`. Also `test-v3-backup.kdbx` (KDBX 4.x backup fixture).

**Note:** `test.kdbx` does NOT contain passkey entries or key-file-protected databases — those require separate fixtures (`demo-keyfile.kdbx` for key file testing).

**UI test gotcha:** The root group has only subgroups, no direct entries. `openAnyEntry()` must navigate into a non-empty subgroup (Social or Work) to find entries. The helper `findNonEmptyGroup()` in `KeeForgeUITestCase.swift` handles this by preferring groups whose label doesn't contain "0 entries".

### UI Test Base Class

`KeeForgeUITestCase` provides:
- `app` — pre-configured `XCUIApplication` with test.kdbx injected via launch environment
- `unlock(password:)` — type password and tap unlock
- `unlockSuccessfully()` — unlock with correct password and assert success
- `openAnyEntry()` — navigate groups to find and tap an entry
- `firstVisibleEntryLabel()` — get title of first visible entry

## Release Process (Xcode Cloud)

KeeForge uses Xcode Cloud for automated release builds.

### How it works

1. Bump version in `project.yml` (`MARKETING_VERSION`)
2. Update `CHANGELOG.md` with release notes
3. Commit and tag: `git tag v1.X.0 && git push origin v1.X.0`
4. Xcode Cloud picks up the tag → builds → runs all tests (unit + UI) → archives → uploads to TestFlight → submits for App Store review

### Setup

- **`ci_scripts/ci_post_clone.sh`** — runs after Xcode Cloud clones the repo. Installs XcodeGen and generates the `.xcodeproj`
- **Workflow trigger:** tag matching `v*` (configured in App Store Connect / Xcode)
- **Signing:** handled automatically by Xcode Cloud (cloud-managed certificates)
- **Scheme:** `KeeForge` (includes unit tests + UI tests)

### Manual release (fallback)

```bash
# Bump version
sed -i '' 's/MARKETING_VERSION: "X.Y.Z"/MARKETING_VERSION: "X.Y.Z"/' project.yml

# Build, test, archive locally
xcodegen generate
xcodebuild test -scheme KeeForge -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild archive -scheme KeeForge -archivePath build/KeeForge.xcarchive

# Upload via Xcode Organizer or xcrun altool
```

## CHANGELOG

**Always update `CHANGELOG.md` when committing a feature or bug fix.** Add a bullet to the `## Unreleased` section describing the change. Use past tense for fixes ("Fixed ...") and present tense for features ("Add ..."). Keep entries concise. Do NOT modify entries under released versions (v1.0.0, v1.1.0, etc.).
