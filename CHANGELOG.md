# Changelog

## Unreleased

### Changes
- Split app settings into separate Security, AutoFill, Display, and About pages while keeping Tip Jar prominent on the main settings screen, and add a privacy toggle to hide last-opened usage stats from the locked database list
- Move Send Feedback to the main Settings page, place About at the bottom, and tighten database/app settings helper copy

### Fixes
- Keep password/key-file unlock failures visible during lockout backoff and restore the unlock error accessibility hooks used by UI tests
- Stabilize entry-creation UI coverage by validating new entries after a lock/reopen cycle and hardening list scrolling against stale simulator snapshots
- Reduce in-app feedback uploads to the typed message plus visible error details, removing dedicated contact fields and automatic app/device metadata collection

## v1.8.2 (2026-04-20)

### New Features
- Add adaptive iPad layout support with a persistent sidebar, regular-width vault workspace, and a non-modal iPhone vault flow
- Add an in-app feedback form that can be opened from Settings and database-open failure screens without requiring GitHub or email

### Fixes
- Improve database-open failure handling by separating expected password/key-file errors from unexpected file, format, cloud, and biometric failures
- Add copyable sanitized error details and safer feedback payloads for database-open issues without including vault contents, passwords, key files, or raw database files
- Restore database list row sizing to match v1.8.1, including the selected-row highlight footprint on both iPhone and iPad layouts
- Respect the configured auto-lock timeout across app switching by making immediate background locking optional and applying elapsed timeout checks when returning from the background

## v1.8.1 (2026-04-16)

### New Features
- Add KDBX 3.1 read/open compatibility for password-only databases, including legacy AES-KDF headers, hashed block streams, and Salsa20 protected fields

### Fixes
- Toggling read-only in Database Settings now updates the current view immediately
- Fix unlocked vault displaying a wrapper "Root" group instead of showing database contents directly
- Fix read-only ribbon and unsaved-changes banner accessibility identifiers for UI test visibility
- Fix settings navigation from the unlocked database view (gear button → Database Settings → App Settings)
- Prevent adding the same local database file twice; opening an already-added file via Files/AirDrop now reliably opens the existing entry

### Changes
- Replace the yellow read-only banner with a lock icon in the navigation toolbar so the indicator stays visible across groups and entry details
- Unify Quick Launch and Read Only badge styling in the database list
- Use a check mark toggle for Quick Launch in the database context menu to match the Read-only toggle

## v1.8.0 (2026-04-12)

### New Features
- **Entry editing** — create, edit, and delete entries directly in the app with built-in password generation, autosave, save-conflict resolution, and read-only mode
- **AutoFill credential creation** — save new credentials and generate strong passwords directly from the AutoFill extension, with offline-safe queueing for Dropbox-backed databases
- **Database settings** — tap the settings button in the unlocked view to manage nickname, read-only mode, key file, metadata, and cloud sync

### Editing Details
- Changes autosave immediately — no manual save button; a progress overlay shows while the database is being written
- Full entry history is preserved on every edit, so previous passwords and fields can be reviewed
- Passwords are visible by default in the editor with a toggle to hide them
- Deleting an entry already in the Recycle Bin permanently erases it
- No data loss: unknown XML elements and third-party KeePass fields are preserved when saving
- Automatic timestamped backups before each save, with detection of external changes to prevent overwrites
- Saving works correctly for databases stored in Files folders like Downloads
- Dropbox-backed databases can be saved back to Dropbox with conflict detection
- Field labels stay visible while typing, and password styling is consistent across the app

### Fixes
- New entries from AutoFill are placed under the correct root group instead of a hidden internal group
- Recycle Bin is created under the correct root group
- Group entry counts update immediately after edits
- Dropbox icon renders correctly in dark mode
- Provider-specific cloud sync status shown during unlock
- Fixed Xcode Cloud CI bootstrap for clean machines

### Changes
- Improved AutoFill new-credential screen with labeled fields and toolbar buttons
- Saved AutoFill credentials queue in the shared App Group cache and are cleared on reinstall
- Simplified entry editor by removing custom fields and one-time password sections
- Added SwiftyDropbox to the Acknowledgments screen

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
