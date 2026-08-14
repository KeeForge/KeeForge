# KeeForge Roadmap

KeeForge aims to be the native, open-source KeePass app for Apple platforms: fast AutoFill, dependable editing, and safe synchronization with KeePassXC—without accounts, telemetry, subscriptions, or a hosted vault.

Roadmap items are grouped first by intent and then by product area, without an implied delivery order or timeline. Within each list, outstanding items come first and completed items are kept at the end for reference.

## Security and trust

### Security evidence and transparency

- [ ] Publish a security center with the threat model, trust boundaries, and responsible-disclosure process.
- [ ] Document cryptographic architecture and the provenance of each primitive.
- [ ] Publish a network-endpoint inventory.
- [ ] Document release-signing and independently verifiable build metadata; pursue reproducible builds where practical.
- [ ] Generate and review an SBOM and locked dependency inventory.
- [ ] Add fuzzing for KDBX parsing, XML parsing, decompression, and malformed key files.
- [x] Publish audit reports with their date, scope, tested revision, report, and remediation status.
- [x] Document local data storage, including Keychain items, security-scoped bookmarks, caches, temporary attachments, and backups.
- [x] Document the AutoFill extension boundary and app-group data flow.

### Offline vault health

- [ ] Detect duplicate and reused passwords.
- [ ] Identify weak or short passwords with transparent criteria.
- [ ] Add a vault-wide report for expired entries and entries missing useful usernames or URLs.
- [ ] Validate TOTP and passkey records.
- [ ] Flag weak KDF parameters and old KDBX versions.
- [ ] Surface oversized attachments and missing history or recycle-bin protections.
- [ ] Keep all checks offline by default.
- [ ] Add an explicitly enabled breached-password check using k-anonymity, clearly separated from offline checks.
- [x] Warn about expired entries in browsing, entry details, and AutoFill selection.

### YubiKey challenge-response

- [ ] Support common KeeChallenge/YubiKey challenge-response configurations.
- [ ] Document compatible connection types and platform limitations.
- [ ] Design setup, fallback, backup, and recovery warnings to minimize lockout risk.
- [ ] Add interoperability fixtures for vaults created by major KeePass clients.

### Project stewardship

- [ ] Explain project sustainability and continuity planning.
- [x] Document support expectations and contribution paths.
- [x] Offer optional supporter funding that never restricts ordinary access to users' vault data.

## Reliability and data safety

### Sync status, recovery, and resilience

- [ ] Show transient saved, uploading, synchronized, and retrying states for every vault.
- [ ] Add a local sync journal showing recent saves, uploads, downloads, conflicts, and backups.
- [ ] Make timestamped backups easy to inspect and restore in the app.
- [ ] Add equivalent retry behavior for recoverable WebDAV failures.
- [x] Show disconnected, stale, unavailable, pending-upload, and conflict states on vault rows and in database details.
- [x] Create timestamped backups before saves and prove that they reopen with the original credentials.
- [x] Retry recoverable Dropbox and OneDrive failures automatically, with calm and actionable error messages.
- [x] Test races among in-app edits, AutoFill-created credentials, desktop edits, offline operation, and provider latency.
- [x] Ensure queued AutoFill uploads cannot silently overwrite a newer remote vault.

### Three-way, entry-level sync merge

- [ ] Use the last synchronized vault as the merge base.
- [ ] Merge independent entry and group changes automatically when safe.
- [ ] Resolve conflicts at entry or field level instead of choosing an entire file.
- [ ] Preview what will change before applying a resolution.
- [ ] Preserve both sides when a conflict cannot be resolved safely.
- [ ] Make every merge recoverable through backups and the sync journal.
- [ ] Add deterministic tests for concurrent edits, moves, deletions, history, attachments, and unknown fields.

## Compatibility and interoperability

### KeePass interoperability program

- [ ] Publish a client-by-client test matrix covering KeePassXC, KeePass 2.x, Strongbox, KeePassium, and Keepass2Android.
- [ ] Test files produced by older versions and commonly used plugins.
- [ ] Publish results and known limitations.
- [x] Publish sanitized compatibility fixtures with regeneration instructions.
- [x] Cover KDBX 3.1 and 4.x; AES, ChaCha20, and Twofish; and AES-KDF, Argon2d, and Argon2id.
- [x] Cover custom fields, custom icons, passkeys, TOTP, history, recycle bins, attachments, and unknown extensions.
- [x] Run parse → modify → save → reopen tests and an external KeePassXC opener gate for every release.
- [x] Maintain the guarantee that unsupported headers, XML, and metadata are preserved whenever safely possible.

### Round-trip data preservation

- [ ] Preserve source custom-field ordering during round trips.
- [ ] Preserve attachment metadata and binary references across merge operations.
- [x] Preserve unknown entry metadata and custom fields during round trips.
- [x] Preserve attachment metadata, binary references, and pool contents across save operations.

## Feature set

### AutoFill activation and diagnosis

- [ ] Optimize onboarding for the first successful credential fill, not merely the first opened vault.
- [ ] Provide a safe test flow for verifying AutoFill setup.
- [ ] Explain how QuickType suggestions are derived from URLs and app identifiers.
- [ ] Diagnose why an expected credential was not suggested.
- [ ] Surface the cached AutoFill copy's freshness and pending updates.
- [ ] Provide an optional, local-only diagnostics report that users can deliberately share.
- [x] Detect whether KeeForge is enabled as an AutoFill credential provider and guide users to the correct system setting.
- [x] Explain that AutoFill uses a locally cached copy of cloud vaults.
- [x] Offer biometric quick unlock after the first successful master-password unlock.

### Domain matching and credential selection

- [ ] Add exact-host and parent-domain controls.
- [ ] Improve associated-domain and app-identifier matching.
- [ ] Support per-entry subdomain allow and deny rules.
- [ ] Rank multiple matching URLs per entry.
- [ ] Add opt-in equivalence rules for regional or related domains.
- [ ] Search URLs, usernames, tags, custom fields, and aliases consistently.
- [ ] Explain the match reason for each suggested entry.
- [ ] Diagnose malformed URLs and overly broad matches.
- [x] Use Public Suffix List-aware domain matching.
- [x] Support multiple URLs per entry through `KP2A_URL_*` custom fields.
- [x] Avoid suggesting expired credentials unless the user explicitly selects the stored identity.
- [x] Separate exact matches from interactive-only sibling-subdomain matches.

### Entry editing and custom fields

- [ ] Expose arbitrary custom-field creation, editing, and deletion in the entry editor.
- [ ] Allow custom fields to switch between protected and unprotected values.
- [ ] Move, copy, and duplicate entries and groups with full metadata preservation.
- [ ] Add expiration and reminder management.
- [ ] Add Auto-Type-style field mappings where iOS offers an equivalent mechanism.
- [ ] Extend passkey registration: attach to an existing entry, conditional registration, largeBlob/PRF extensions, RS256/EdDSA algorithms.
- [ ] Add custom-icon import and selection plus per-entry favicon management.
- [x] Add passkey creation from Apple's "Add Passkey" credential flow (ES256, KeePassXC-compatible storage).
- [x] Display preserved custom icons and opt-in website favicons.

### Entry history and tags

- [ ] Compare a historical revision with the current entry.
- [ ] Restore selected fields from a historical revision.
- [x] Add an entry-history viewer.
- [x] Restore a full historical revision while retaining the replaced state when database history settings allow it.
- [x] Complete tag integration: browser, search, group-tag inheritance, and editor suggestions.

### Attachments

- [ ] Add attachments from Files, Photos, and other supported system sources.
- [ ] Replace, rename, and delete attachments.
- [ ] Warn clearly before operations that may substantially increase vault size.
- [x] Export and share attachments.
- [x] Browse, preview, and share attachments in read-only mode.
- [x] Support attachment synchronization across storage providers.

### Browsing and interface

- [ ] Audit database-row layout and rendering performance with large vaults on compact and regular-width devices.
- [x] Consistent password presentation with strength indication.
- [x] Settings folders and grouped subpages.
- [x] Option to hide metadata in database rows.

### Database management and password generation

- [x] Expose database encryption algorithm and KDF tuning with safe defaults and clear warnings.
- [ ] Add reusable advanced password-generator recipes and per-entry generation history.
- [ ] Add carefully designed import and export tools.
- [x] Create new databases directly in the app.
- [x] Configure generated-password length, character sets, and ambiguous-character exclusion.
- [x] Display the database encryption algorithm and KDF in Database Details.

## Accessibility and localization

### Accessibility

- [ ] Complete a VoiceOver audit of setup, unlock, browsing, editing, conflict recovery, and AutoFill flows.
- [ ] Support Dynamic Type at accessibility sizes without clipping or loss of function.
- [ ] Support Increased Contrast and Reduce Motion.
- [ ] Ensure no state is communicated by color alone.
- [ ] Add accessible password-character reading options.
- [ ] Add automated accessibility checks to CI where practical.
- [ ] Add hardware-keyboard navigation for iPad.
- [x] Add hardware-keyboard navigation and app commands for Mac.

### Localization

- [ ] Add Simplified Chinese localization.
- [ ] Add Traditional Chinese localization.
- [ ] Add Japanese localization.
- [ ] Establish a community translation and review workflow.
- [ ] Add release checks for layout-breaking localized strings.
- [x] Internationalization infrastructure across the app.
- [x] Add German localization.
- [x] Add French localization.
- [x] Add Spanish localization.
- [x] Add release checks for untranslated strings and format-specifier drift.

## Platform and provider reach

### Storage providers

- [ ] Add Google Drive support.
- [ ] Add support for additional storage providers using the same sync-safety guarantees.
- [ ] Add a provider-contract test suite applied uniformly to Dropbox, OneDrive, and WebDAV.
- [x] Add OneDrive support.
- [x] Add WebDAV support.

### Apple platforms

- [ ] Complete and release the native macOS app.
- [ ] Publish a GitHub release for the macOS app.
- [ ] Deliver a full keyboard-first macOS experience rather than only feature parity with iOS.
- [ ] Document an enterprise/MDM distribution decision and its impact on the consumer app.
- [x] Ship an iPad-native layout.

Feature requests and contributions are welcome. Please include the user problem, affected platform and storage provider, interoperability expectations, and any sample KDBX fixture that can be shared safely.
</content>
