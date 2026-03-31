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

### Project Setup

```bash
# Regenerate the Xcode project from project.yml
xcodegen generate

# Build the app target for simulator
xcodebuild build -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Run `xcodegen generate` whenever:
- `project.yml` changes
- files are added/removed from targets
- Xcode reports stale/missing test file references in `.xcodeproj`

### Common Test Commands

```bash
# Run one unit test class
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:KeeForgeTests/KDBXParserTests -quiet

# Run multiple unit test classes
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:KeeForgeTests/KDBXParserTests \
  -only-testing:KeeForgeTests/TOTPGeneratorTests -quiet

# Run one UI test class
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:KeeForgeUITests/UnlockFlowUITests -quiet
```

If simulator gets stuck with "preflight checks" error:
```bash
xcrun simctl shutdown all && xcrun simctl erase <UDID>
```

If `xcodebuild` cannot boot a simulator or reports missing runtimes/destinations:
```bash
xcodebuild -showdestinations -project KeeForge.xcodeproj -scheme KeeForge
```

## Testing

- Every feature and bug fix should include automated tests
- Unit tests cover logic and parsing; UI tests cover user-visible flows and regressions
- If a bug is found, write a regression test first when practical, then fix
- Prefer the smallest test scope that proves the behavior

### Test Targets

| Target | Type | Bundle ID |
|--------|------|-----------|
| KeeForgeTests | Unit tests | `com.keevault.app.tests` |
| KeeForgeUITests | UI tests (XCUITest) | `com.keevault.app.uitests` |

### Test Selection Rules

- **ALWAYS use `-only-testing:`** to run only the relevant test class(es)
- **NEVER run the full UI suite unless explicitly asked**
- For UI work, run one test class at a time and finish fixing that class before moving to the next
- If a source file contains multiple test classes, run each class separately by class name
- Prefer unit tests over UI tests unless the behavior is genuinely UI-driven
- Detailed UI test guidance lives in `KeeForgeUITests/README.md`

Examples:
```bash
# Parser changes
-only-testing:KeeForgeTests/KDBXParserTests

# Credential store changes
-only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests

# TOTP changes
-only-testing:KeeForgeTests/TOTPGeneratorTests

# One UI class
-only-testing:KeeForgeUITests/UnlockedDatabaseUITests
```

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
