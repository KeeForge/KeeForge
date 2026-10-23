# AutoFill Services

**Scope:** helpers shared by the app and both AutoFill extensions: saving a new entry, matching entries to a request, publishing credential identities, password generation, and the extension memory pre-flight. Every file here is on the shared allow-lists; the dual-list rule is in `../AGENTS.md`.

## Ownership

- `AutoFillSaveCoordinator.saveNewEntry`: the only extension-safe write path, and the only creator of pending-upload markers (`../Cloud/AGENTS.md`).
- `AutoFillSaveCoordinator.destinationGroup(in:preferredGroupID:)`: the one decision of which group a new AutoFill entry goes into. Database Details and the creators display the same resolution; do not resolve it anywhere else.
- `CredentialIdentityStoreManager`: every mutation of the system credential identity store. `CredentialRecordIdentifier` is the sole encoder and parser of the database-tagged record identifier.
- `CredentialMatcher`: what a service identifier matches. Published identities and the pickers both read URLs through it.
- `KPGroup.autoFillEntries` (`../../Models/Group.swift`): which entries AutoFill may see at all.

## Invariants

### Saving

- Everything here must stay extension-safe on iOS and macOS. A new dependency on another service file needs that file on both allow-lists.
- A new entry never goes into the synthetic KDBX Root: other KeePass apps cannot read entries there. The fallback is the first top-level group, and the configured group is used only while it exists outside the recycle bin. A group that stops resolving is not cleared from the setting.
- The two-phase marker order in `saveNewEntry` is load-bearing; the crash analysis is in the comment there.
- After a save, identities are published and the active AutoFill pointer moves only if the reference has AutoFill enabled.
- The extension saves with `KDFExecutionPolicy.autoFillExtension`.

### Credential identities

- Every operation reads `CredentialIdentityStoreCapabilities` first. Per-database aggregation is reachable only when `supportsIncrementalUpdates` is true.
- Where macOS reports it false (recorded on 26.5, not re-verified), every refresh is a whole-store replace and every targeted removal degrades to clearing the store, so the store holds one database's identities. The gate is the runtime flag, not `#if os(macOS)`. macOS 27.0.1 reports it true. Platform facts are in `../../../AutoFillExtension/AGENTS.md`.
- Enumeration throws when any returned object lacks `ASCredentialIdentity` conformance. An unreadable store is a third state, never an empty one: nothing may be inferred from it. macOS 27.0.1 and a physical iPhone on iOS 27.0.1 return only such objects once the store is non-empty (an empty store still enumerates as empty).
- With an unreadable store the database registry stands in for its contents, because only AutoFill-enabled databases publish. A refresh replaces the whole store when no other database is AutoFill-enabled, and otherwise only saves additively. Every targeted removal clears the whole store, as on a store without incremental updates.
- The additive save cannot drop its own database's stale identities. With two or more AutoFill-enabled databases on such an OS, a deleted or changed entry's suggestion stays until a removal or Clear AutoFill Entries empties the store; tapping it in the extension is one such removal. Do not reach for private selectors on the returned objects to close this gap.
- An enumerated identity without a readable `recordIdentifier` forces the additive path: unknown system identities are never deleted by a refresh. Clear AutoFill Entries removes them.
- The mutation queue is per process. The app and extension can overlap, so a refresh must be idempotent; the worst case is a briefly stale suggestion until the database's next refresh.
- A password identity is a `.URL` identifier `https://<host>`; a one-time-code identity is a `.domain` identifier with the exact host. Only the host is published: no path, port, query, or user info reaches the system store, and never the registrable domain, because the host is all the system list shows to tell subdomains apart.
- Expired entries are never published.
- Legacy bare-UUID identifiers carry no database. They are attributed to the database that was active when they were written, which is why removal passes `includingLegacyIdentifiers` only for the active database.

### Matching

- `KPGroup.autoFillEntries` is the single filter for groups whose `<EnableSearching>` resolves to false. All three sources call it: `DatabaseViewModel.credentialStoreEntries`, `AutoFillSaveCoordinator.credentialStoreEntries`, and the extension's own parse. `DatabaseViewModel.autoFillExcludedGroupIDs` must resolve inheritance the same way (`../../ViewModels/AGENTS.md`).
- An `.app` service identifier (an App ID such as `TEAMID.com.example.app`) is never parsed as a host: `searchTerm(for:)` returns nil. Reverse-DNS App IDs end in real TLDs and would strictly match an unrelated website.
- Entries saved before that rule hold a raw App ID as a URL. Read entry URLs for AutoFill through `CredentialMatcher.webURLs(of:)`, which drops such a field without rewriting the entry.
- Strict matching decides the exact section and the silent fill; broad matching only decides what a picker lists (`../../../AutoFillExtension/AGENTS.md`).
- Registrable-domain boundaries come from the embedded Public Suffix List (`swift-psl`), not from string heuristics.

### Memory pre-flight and settings

- `AutoFillMemoryLimit.check` compares exactly one number, the header's Argon2 memory parameter, against `os_proc_available_memory`. Do not price in the file size or parse cost: a false refusal breaks a vault that opens today. It refuses only what is certain to be killed.
- It is skipped on macOS (the API does not exist there) and for an unlimited process, and never refuses AES-KDF or an unknown KDF. It does not cover a file too large to read.
- `PasswordGenerator` samples passphrase words independently with Swift’s uniform integer sampling and `SystemRandomNumberGenerator`. The unchanged EFF long wordlist must be bundled in all four product targets; never substitute a smaller fallback list.
- `PasswordGenerator.Options` is persisted App Group-wide and decodes per field, so adding an option does not reset stored ones.
- `AutoFillDiagnostics` is DEBUG-only and logs event names, flags, and counts. Never pass entry data, URLs, or secrets to it.

## Tests

- `CredentialIdentityStoreManagerTests` (fake store via the DEBUG `storeProviderOverride`), `CredentialMatcherTests`, `AutoFillMemoryLimitTests`, `PasswordGeneratorTests`, `PasswordStrengthEstimatorTests`.
- A store change needs a case for each of the three shapes: incremental and readable, non-incremental (`supportsIncrementalUpdatesValue = false`), and incremental but unreadable (`enumerationError`).
- In a unit-test host the manager mutates nothing unless a store override is installed: the host is the real signed app, and its system store is the developer's own.
- `AutoFillSaveCoordinator` has no class of its own: `CredentialProviderSaveTests`, `CredentialProviderPickerCreationTests`, `CredentialProviderRegistrationTests`, and `KDBXCompatibilityTests` for the bytes it writes.
- Which pages the system offers an identity on is undocumented and can only be checked with a signed build on a device; the simulator's identity store is not a substitute.

## See also

- `../AGENTS.md`, `../Cloud/AGENTS.md`, `../Persistence/AGENTS.md`
- `../../../AutoFillExtension/AGENTS.md`: request handling and platform limits
