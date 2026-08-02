# KeeForge Roadmap

KeeForge aims to be the native, open-source KeePass app for Apple platforms: fast AutoFill, dependable editing, and safe synchronization with KeePassXC—without accounts, telemetry, subscriptions, or a hosted vault.

Roadmap items are grouped by product area without an implied delivery order or timeline.

## Sync status, recovery, and resilience

- [x] Show disconnected, stale, unavailable, pending-upload, and conflict states on vault rows and in database details.
- [ ] Show transient saved, uploading, synchronized, and retrying states for every vault.
- [ ] Add a local sync journal showing recent saves, uploads, downloads, conflicts, and backups.
- [x] Create timestamped backups before saves and prove that they reopen with the original credentials.
- [ ] Make timestamped backups easy to inspect and restore in the app.
- [x] Retry recoverable Dropbox and OneDrive failures automatically, with calm and actionable error messages.
- [ ] Add equivalent retry behavior for recoverable WebDAV failures.
- [x] Test races among in-app edits, AutoFill-created credentials, desktop edits, offline operation, and provider latency.
- [x] Ensure queued AutoFill uploads cannot silently overwrite a newer remote vault.

## Security evidence and project trust

- [ ] Publish a security center with the threat model, trust boundaries, and responsible-disclosure process.
- [x] Publish audit reports with their date, scope, tested revision, report, and remediation status.
- [ ] Document cryptographic architecture and the provenance of each primitive.
- [x] Document local data storage, including Keychain items, security-scoped bookmarks, caches, temporary attachments, and backups.
- [x] Document the AutoFill extension boundary and app-group data flow.
- [ ] Publish a network-endpoint inventory.
- [ ] Document release-signing and independently verifiable build metadata; pursue reproducible builds where practical.
- [ ] Generate and review an SBOM and locked dependency inventory.
- [ ] Add fuzzing for KDBX parsing, XML parsing, decompression, and malformed key files.
- [x] Document support expectations and contribution paths.
- [ ] Explain project sustainability and continuity planning.
- [x] Offer optional supporter funding that never restricts ordinary access to users' vault data.

## AutoFill activation and diagnosis

- [x] Detect whether KeeForge is enabled as an AutoFill credential provider and guide users to the correct system setting.
- [ ] Optimize onboarding for the first successful credential fill, not merely the first opened vault.
- [ ] Provide a safe test flow for verifying AutoFill setup.
- [ ] Explain how QuickType suggestions are derived from URLs and app identifiers.
- [ ] Diagnose why an expected credential was not suggested.
- [x] Explain that AutoFill uses a locally cached copy of cloud vaults.
- [ ] Surface the cached AutoFill copy's freshness and pending updates.
- [x] Offer biometric quick unlock after the first successful master-password unlock.
- [ ] Provide an optional, local-only diagnostics report that users can deliberately share.

## Custom fields and database browsing

- [ ] Expose arbitrary custom-field creation, editing, and deletion in the entry editor.
- [ ] Allow custom fields to switch between protected and unprotected values.
- [ ] Preserve source custom-field ordering during round trips.
- [x] Preserve unknown entry metadata and custom fields during round trips.
- [ ] Audit database-row layout and rendering performance with large vaults on compact and regular-width devices.

## Accessibility and localization

- [ ] Complete a VoiceOver audit of setup, unlock, browsing, editing, conflict recovery, and AutoFill flows.
- [ ] Support Dynamic Type at accessibility sizes without clipping or loss of function.
- [ ] Support Increased Contrast and Reduce Motion.
- [ ] Ensure no state is communicated by color alone.
- [ ] Add accessible password-character reading options.
- [ ] Add automated accessibility checks to CI where practical.
- [ ] Add Simplified Chinese localization.
- [ ] Establish a community translation and review workflow.
- [ ] Add hardware-keyboard navigation for iPad.
- [x] Add hardware-keyboard navigation and app commands for Mac.
- [x] Add French localization.
- [x] Add Spanish localization.
- [ ] Add Japanese localization.
- [ ] Add Traditional Chinese localization.
- [x] Add release checks for untranslated strings and format-specifier drift.
- [ ] Add release checks for layout-breaking localized strings.

## Three-way, entry-level sync merge

- [ ] Use the last synchronized vault as the merge base.
- [ ] Merge independent entry and group changes automatically when safe.
- [ ] Resolve conflicts at entry or field level instead of choosing an entire file.
- [ ] Preview what will change before applying a resolution.
- [ ] Preserve both sides when a conflict cannot be resolved safely.
- [ ] Make every merge recoverable through backups and the sync journal.
- [ ] Add deterministic tests for concurrent edits, moves, deletions, history, attachments, and unknown fields.

## Attachments

- [ ] Add attachments from Files, Photos, and other supported system sources.
- [ ] Replace, rename, and delete attachments.
- [x] Export and share attachments.
- [x] Preserve attachment metadata, binary references, and pool contents across save operations.
- [ ] Preserve attachment metadata and binary references across merge operations.
- [x] Support attachment synchronization across storage providers.
- [ ] Warn clearly before operations that may substantially increase vault size.

## Entry history and tags

- [x] Add an entry-history viewer.
- [ ] Compare a historical revision with the current entry.
- [x] Restore a full historical revision while retaining the replaced state when database history settings allow it.
- [ ] Restore selected fields from a historical revision.
- [x] Complete tag integration: browser, search, group-tag inheritance, and editor suggestions.

## Offline vault health

- [ ] Detect duplicate and reused passwords.
- [ ] Identify weak or short passwords with transparent criteria.
- [x] Warn about expired entries in browsing, entry details, and AutoFill selection.
- [ ] Add a vault-wide report for expired entries and entries missing useful usernames or URLs.
- [ ] Validate TOTP and passkey records.
- [ ] Flag weak KDF parameters and old KDBX versions.
- [ ] Surface oversized attachments and missing history or recycle-bin protections.
- [ ] Keep all checks offline by default.
- [ ] Add an explicitly enabled breached-password check using k-anonymity, clearly separated from offline checks.

## Storage providers

- [ ] Add Google Drive support.
- [ ] Add support for additional storage providers using the same sync-safety guarantees.
- [ ] Add a provider-contract test suite applied uniformly to Dropbox, OneDrive, and WebDAV.

## YubiKey challenge-response

- [ ] Support common KeeChallenge/YubiKey challenge-response configurations.
- [ ] Document compatible connection types and platform limitations.
- [ ] Design setup, fallback, backup, and recovery warnings to minimize lockout risk.
- [ ] Add interoperability fixtures for vaults created by major KeePass clients.

## Domain matching and credential selection

- [x] Use Public Suffix List-aware domain matching.
- [ ] Add exact-host and parent-domain controls.
- [ ] Improve associated-domain and app-identifier matching.
- [ ] Support per-entry subdomain allow and deny rules.
- [x] Support multiple URLs per entry through `KP2A_URL_*` custom fields.
- [ ] Rank multiple matching URLs per entry.
- [ ] Add opt-in equivalence rules for regional or related domains.
- [ ] Search URLs, usernames, tags, custom fields, and aliases consistently.
- [x] Avoid suggesting expired credentials unless the user explicitly selects the stored identity.
- [x] Separate exact matches from interactive-only sibling-subdomain matches.
- [ ] Explain the match reason for each suggested entry.
- [ ] Diagnose malformed URLs and overly broad matches.

## KeePass interoperability program

- [x] Publish sanitized compatibility fixtures with regeneration instructions.
- [ ] Publish a client-by-client test matrix covering KeePassXC, KeePass 2.x, Strongbox, KeePassium, and Keepass2Android.
- [x] Cover KDBX 3.1 and 4.x; AES, ChaCha20, and Twofish; and AES-KDF, Argon2d, and Argon2id.
- [x] Cover custom fields, custom icons, passkeys, TOTP, history, recycle bins, attachments, and unknown extensions.
- [ ] Test files produced by older versions and commonly used plugins.
- [x] Run parse → modify → save → reopen tests and an external KeePassXC opener gate for every release.
- [ ] Publish results and known limitations.
- [x] Maintain the guarantee that unsupported headers, XML, and metadata are preserved whenever safely possible.

## Advanced editing and database management

- [ ] Add passkey creation, including the remaining interoperability, write-path, and recovery requirements.
- [x] Display preserved custom icons and opt-in website favicons.
- [ ] Add custom-icon import and selection plus per-entry favicon management.
- [ ] Move, copy, and duplicate entries and groups with full metadata preservation.
- [ ] Add expiration and reminder management.
- [x] Configure generated-password length, character sets, and ambiguous-character exclusion.
- [ ] Add reusable advanced password-generator recipes and per-entry generation history.
- [ ] Add Auto-Type-style field mappings where iOS offers an equivalent mechanism.
- [x] Display the database encryption algorithm and KDF in Database Details.
- [ ] Expose database encryption algorithm and KDF tuning with safe defaults and clear warnings.
- [ ] Add carefully designed import and export tools.

## Apple platform expansion

- [ ] Complete and release the native macOS app.
- [ ] Publish a GitHub release for the macOS app.
- [ ] Deliver a full keyboard-first macOS experience rather than only feature parity with iOS.
- [ ] Document an enterprise/MDM distribution decision and its impact on the consumer app.

## Delivered foundations

These completed items remain important foundations for the work above.

### Synchronization and platforms

- [x] OneDrive support.
- [x] WebDAV support.
- [x] iPad-native layout.

### Database and AutoFill capabilities

- [x] Create new databases directly in the app.
- [x] Browse, preview, and share attachments in read-only mode.

### Interface

- [x] Consistent password presentation with strength indication.
- [x] Settings folders and grouped subpages.
- [x] Option to hide metadata in database rows.

### Localization

- [x] Internationalization infrastructure across the app.
- [x] German localization.

Feature requests and contributions are welcome. Please include the user problem, affected platform and storage provider, interoperability expectations, and any sample KDBX fixture that can be shared safely.
