# Changelog

### TODO
- [ ] Support more cloud sync providers: Google Drive, OneDrive, WebDAV, etc.
- [ ] iPad-native layout
- [ ] Passkey creation (Phase 3 — requires KDBX write support)
- [ ] Sync / attachments

## Unreleased

### New Features
- Add main-app entry editing with create, edit, delete, password generation, save-conflict resolution, and read-only editing safeguards
- Added: Save new credentials and generate strong passwords directly from AutoFill, with offline-safe queueing for Dropbox-backed databases.

### Fixes
- Remove the baked white background from the Dropbox provider glyph so it renders cleanly in dark mode
- Show provider-specific cloud sync status during unlock, and add focused unlock coverage for cloud sync success, fallback, and failure paths
- Fix Xcode Cloud post-clone bootstrap so clean CI machines no longer require a developer team xcconfig value just to generate the project
- Add persistent field labels to the entry edit basics section so filled-in rows remain identifiable while editing
- Internal: KDBX parser now captures unknown XML elements verbatim, paving the way for lossless edits
- Internal: KDBX writer can now produce KDBX 4.x files (AES-256-CBC and ChaCha20-Poly1305) for use by upcoming edit features
- Internal: Added DatabaseDraft layer that lets the app stage entry edits in memory before saving.
- Internal: Added a local-file save pipeline with atomic write, automatic backups, and out-of-band-change detection.
- Internal: Dropbox-backed databases can now be saved back to Dropbox with optimistic-concurrency conflict detection.

### Changes
- Pending AutoFill uploads now live in the shared App Group cache/queue and are cleared if the app is uninstalled or reinstalled.
- Add SwiftyDropbox to the Acknowledgments screen.
- Simplify the entry edit screen by removing the custom fields and one-time password sections.

## v1.7.0 (2026-04-05)

### New Features
- Add read-only Dropbox cloud sync with OAuth account linking, native cloud browsing, shared cached copies for AutoFill, and cloud status indicators in the database list and settings

### Fixes
- Simplify database list rows by using source icons instead of separate Dropbox and biometric badges, and fix oversized whitespace in Dropbox cloud-sync details

### Changes
- Split developer-specific build identifiers into a gitignored local xcconfig and move generated git metadata into a separate build-time config file
- Bootstrap a simulator-only local build config in GitHub Actions so CI no longer requires developer-specific identifiers

## v1.6.0 (2026-04-03)

### New Features
- Add a multi-database home screen that replaces the single-file launch screen with a database list, per-database unlock flow, add/remove/reorder actions, quick launch, nicknames, and key file association management
- Add migration from the legacy single-database bookmark/cache/keychain model to persisted per-database references with UUID-keyed shared cache files and lazy biometric key migration
- Support opening .kdbx files from other apps (Files, Mail, AirDrop, etc.) with UTType support for KeePassium, Strongbox, MiniKeePass, and more
- Add open source acknowledgments screen in Settings showing Argon2Swift and Argon2 license texts

### Fixes
- Improve privacy shield: show only app icon and name over blur instead of misleading "KeeForge Locked" text, trigger on background only (not inactive) to avoid flashing during Face ID or Control Center, and fix BiometricService auth-in-progress flag
- Fixed false "File unavailable" warnings for cloud-backed databases, restored the Add Database picker flow, and replaced the old unlock flash on launch with a dedicated opening screen
- Fixed multi-database file picker selections being dropped after dismissal before the chosen database or key file could be processed
- Fixed newly added databases failing to unlock with "The file couldn’t be opened because it doesn’t exist" by capturing bookmarks while document access is active and falling back to the cached copy when needed

### Changes
- Restyle the database unlock flow as a native sheet with plain system background instead of a full-screen page with blue gradient
- Update AutoFill to keep one active source database at a time by tracking the last successfully unlocked database across the app and extension
- Clarified quick launch behavior versus global Face ID auto-unlock, improved database detail/settings copy, and split Quick AutoFill into its own settings section
- Move Tip Jar above About in Settings
- Extract SecurityScopedBookmarkManager for cleaner bookmark handling
- Remove .kdb support from file type declarations, keep only .kdbx

## v1.5.1 (2026-03-31)

### New Features
- Add TOTP one-time code AutoFill support (iOS 18+) — verification codes from TOTP entries now appear in the QuickType bar alongside passwords and passkeys

### Fixes
- Fixed AutoFill credential lookup falling back to slow matching every time by parsing stable UUIDs from KDBX entry XML instead of generating random UUIDs on each parse
- Fixed AutoFill key icon flow showing all entries instead of filtering to the current site; replaced non-scrollable alert picker with scrollable search view and pre-filled domain search
- Fixed "KDF parameter out of range" error when opening databases created with KeePassXC 2.7.12+ that use high Argon2 iterations or parallelism values

### Changes
- Consolidated UI tests: merged 6 post-unlock test classes into a single `UnlockedDatabaseUITests` class with one unlock flow, reducing simulator + Argon2 overhead

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
