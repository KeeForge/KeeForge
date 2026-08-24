# AutoFill Services

This folder holds extension-facing helpers shared between the main app and the AutoFill target.

## Main Files

- `AutoFillSaveCoordinator.swift` stages and saves new credentials, refreshes shared caches, and queues deferred cloud uploads when needed.
- `CredentialMatcher.swift` matches KeePass entries to web domains and usernames for AutoFill suggestions.
- `CredentialIdentityStoreManager.swift` mirrors unlocked entries into the system credential identity store. It also owns `CredentialRecordIdentifier` (the sole encoder/parser of the database-tagged record-identifier format on published identities) and the `CredentialIdentityStoreProviding` seam (production: `SystemCredentialIdentityStore`; tests swap a fake via the `#if DEBUG` `storeProviderOverride`).
- `PasswordGenerator.swift` provides the reusable strong-password generator used by both the app and AutoFill flows. `Options` is `Codable` and persisted App Group-wide as `SettingsService.passwordGeneratorOptions`, so the generator sheet reopens with the settings last used and the AutoFill generate buttons match them; decoding is per-field so adding an option does not reset the stored ones.
- `PasswordStrengthEstimator.swift` scores passwords into the four-level strength meter shown in the app and extension; on both AutoFill allow-lists in `../../../project.yml` (dual-list rule in `../README.md`).
- `AutoFillDiagnostics.swift` is a DEBUG-only breadcrumb log for diagnosing AutoFill request flows on a development device. It appends event names, flags, and counts (never entry data, URLs, or secrets) to `Library/autofill-diagnostics.log` in the App Group container (`Library` because devicectl's file service only reaches Library/Documents/tmp), which a paired Mac can pull with `xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier group.com.keevault.shared --source Library/autofill-diagnostics.log`. Release builds compile every call to a no-op. On both AutoFill allow-lists in `../../../project.yml` (dual-list rule in `../README.md`).
- `AutoFillMemoryLimit.swift` refuses an unlock the AutoFill extension's memory budget cannot survive, before Argon2 allocates and the process is killed with no error to report (#57). It compares exactly one number against another — the header's Argon2 memory parameter (via `KDBXFileSummary`) against `os_proc_available_memory` — and its doc comments explain why the check must stay that narrow. macOS and unlimited processes skip the check; AES-KDF and unrecognized KDFs are never refused. Not covered: a database so large that *reading* it is fatal — that needs a guard on the read, before the header can be inspected. On both AutoFill allow-lists in `../../../project.yml` (dual-list rule in `../README.md`).

## Change Carefully

- Keep these files extension-safe. If you add a new dependency from here to another service folder, verify that the target is included in `../../../project.yml`.
