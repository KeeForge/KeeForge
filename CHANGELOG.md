# Changelog

### TODO (v2 roadmap)
- [ ] Passkey creation (Phase 3 — requires KDBX write support)
- [ ] Editing support (create/modify entries)
- [ ] Cloud drive integration (WebDAV, Google Drive, OneDrive, Dropbox)
- [ ] iPad-native layout
- [ ] Sync / attachments

## Unreleased
- Add TOTP one-time code AutoFill support (iOS 18+) — verification codes from TOTP entries now appear in the QuickType bar alongside passwords and passkeys
- Fixed "KDF parameter out of range" error when opening databases created with KeePassXC 2.7.12+ that use high Argon2 iterations or parallelism values

## v1.5.0 (2026-03-10)

### New Features
- **Passkey AutoFill** — passkeys stored in KDBX (KeePassXC format) now appear in the iOS QuickType bar and AutoFill sheet. Tap to authenticate with Face ID, just like passwords. Works with any website that supports WebAuthn/FIDO2 passkey sign-in.
- Fixed Tip Jar product loading

### Fixes
- Fixed "Choose Different File" button not opening file picker
- Fixed Face ID auto-triggering immediately after manual lock
- Fixed AutoFill for cloud-hosted databases (Google Drive, OneDrive, Dropbox) by caching the selected `.kdbx` in the App Group shared container
- Fixed QuickType AutoFill identities being left stale after refreshing the shared database cache while unlocked
- Hidden credential ID from passkey detail view (shows relying party + username only)
- Fixed Google Drive `.kdbx` files being grayed out in the database picker by keeping a generic item fallback for cloud providers
- Show database picker validation failures as alerts on the unlock screen
- Listen for `Transaction.updates` at launch to ensure StoreKit transactions are always finished

## v1.4.1 (2026-03-09)

Rejected


## v1.4.0 (2026-03-08)

### New Features
- **Key file support** — unlock databases with password + key file (composite key). Supports all KeePass key file formats: binary, hex, XML v1.0 (`.key`), XML v2.0 (`.keyx`), and arbitrary files
- **Tip Jar** — three tip tiers via StoreKit 2 consumable IAPs in the About section
- **Feedback button** — links to GitHub Issues from the About section
- **Entry timestamps** — created and modified dates shown in entry detail view
- **Sort direction** — ascending/descending toggle for all sort orders

### Security
- Exponential backoff after failed password attempts (2s→4s→8s→16s→30s cap)
- Screen recording detection — blurs vault content when `UIScreen.isCaptured` is true
- QuickType AutoFill now enabled by default for new users

### Fixes
- Fixed backoff error message — now shows "Too many failed attempts. Try again in Xs." immediately instead of raw crypto error
- Sort direction toggle added to list view toolbar (was only in Settings)
- Fixed "Choose Different File" button not opening file picker (two `.fileImporter` modifiers on same view)
- Fixed Face ID auto-triggering immediately after manual lock
- Fixed cloud drive files (Google Drive, OneDrive, Dropbox) grayed out in document picker
- Fixed key file picker not opening (consolidated to single file importer)
- Fixed favicon provider label (Google → DuckDuckGo)
- Tip Jar shows "not available" instead of infinite spinner when products aren't configured
- Fixed demo.kdbx TOTP entries (bare base32 → proper `otpauth://` URIs)
- App Store screenshot test: reveals colored password + scrolls to show TOTP

### Known Issues
- AutoFill extension cannot access databases opened from cloud drives (Google Drive, OneDrive, Dropbox). Use local files for AutoFill.

## v1.3.0 (2026-03-03)

### New Features
- **QuickType AutoFill** — credential suggestions appear in the keyboard bar in Safari. Tap to autofill with Face ID, no full AutoFill popup needed. Toggle in Settings → Quick AutoFill.

### Fixes
- Fixed QuickType domain extraction — www-stripping, subdomain collapsing, multi-part TLD support (e.g. `login.facebook.com` → `facebook.com`, `bbc.co.uk` handled correctly)
- Fixed AutoFill Face ID timing — biometric now deferred until view is presented, resolving "User interaction required" error on QuickType tap
- Increased tap targets for view/copy/open URL buttons in entry detail (44pt minimum per Apple HIG)

### Security
- Hardened KDBX parser: `DataReader` now throws on truncated data instead of silently truncating
- Bounded Argon2 KDF parameters (iterations, memory, parallelism) to prevent resource exhaustion from malicious files
- Validated variant-map value lengths before decoding
- Passwords and TOTP secrets stored as AES-GCM `EncryptedValue` in memory (lazy decrypt on demand)
- Switched favicon provider from Google to DuckDuckGo (privacy)
- Private/internal domains filtered from favicon fetching

### Changes
- Renamed from KeeVault to KeeForge (display name, all internal references, folders, scheme, module name)
- License changed to GPLv3

## v1.2.0 (2026-02-26)

### New Features
- Opt-in website favicon support with disk cache (DuckDuckGo, SHA256 cache keys, 7-day TTL)
- "Download Website Favicons" toggle in Settings (off by default) with "Clear Favicon Cache" action
- Auto Face ID unlock on app open (opt-in setting in Security)
- Auto Face ID unlock in AutoFill extension (shared via App Group)
- Auto-lock inactivity timer (resets on user interaction, configurable in Settings)
- List sorting by title, created date, or modified date (persisted)
- Multiple URLs per entry via KP2A_URL custom fields (display + AutoFill matching)
- Exclude Recycle Bin from search, AutoFill, and group navigation

### Security
- Clipboard now uses `.localOnly` — passwords no longer sync via Universal Clipboard
- Constant-time HMAC/hash comparison (timing side-channel mitigation)
- Decompression bomb protection (256MB limit)
- Favicon cache written with `NSFileProtectionComplete`
- AutoFill extension clears parsed entries from memory after use
- Removed "Never" from clipboard clear timeout options
- Production logging gated behind `#if DEBUG`
- Negative block size validation in KDBX parser

### Fixes
- Fixed duplicate lock button in root view
- Fixed AutoFill subtitle missing in iOS Settings
- Fixed Face ID unlock not appearing on device (improved keychain existence check)
- Fixed keychain account key to use filename instead of full path
- Fixed 3 failing UI tests (navigation helpers now prefer non-empty groups)

### UI
- Renamed "Show Website Icons" → "Download Website Favicons"
- Renamed "Clipboard Timeout" → "Clipboard Clear Timeout"
- Renamed "Sort Order" → "Default Sort Order"
- Lock button in group list toolbar
- Removed debug state label from unlock screen
- Removed GitHub Repository link from Settings

### Infrastructure
- GitHub Actions CI workflow (build + unit tests)
- Auto-lock unit tests + enriched test fixture (7 entries, nested groups, unicode, edge cases)

## v1.1.0 (2026-02-22)

- Fixed inner stream decryption — passwords now display correctly
- Fixed TOTP parsing from `otp://` custom property
- Replaced vendored argon2 C code with Argon2Swift SPM package
- Fixed search — no longer dismisses on typing, works on all pages
- Fixed duplicate entries from History elements leaking into results
- Face ID required to reveal/copy passwords
- No lock shield flash during biometric authentication
- Fixed launch screen placeholder icon
- Resolved Xcode warnings (concurrency, deprecations)

## v1.0.0 (2026-02-17)

- KDBX 4.x read & decrypt
- Group/entry browsing with navigation
- Search across all entries
- TOTP display & copy
- Face ID database unlock
- AutoFill credential provider extension
- Initial App Store release
