# AutoFill Services

This folder holds extension-facing helpers shared between the main app and the AutoFill target.

## Main Files

- `AutoFillSaveCoordinator.swift` stages and saves new credentials, refreshes shared caches, and queues deferred cloud uploads when needed.
- `CredentialMatcher.swift` matches KeePass entries to web domains and usernames for AutoFill suggestions.
- `CredentialIdentityStoreManager.swift` mirrors unlocked entries into the system credential identity store. It also owns `CredentialRecordIdentifier` (the sole encoder/parser of the database-tagged record-identifier format on published identities) and the `CredentialIdentityStoreProviding` seam (production: `SystemCredentialIdentityStore`; tests swap a fake via the `#if DEBUG` `storeProviderOverride`).
- `PasswordGenerator.swift` provides the reusable strong-password generator used by both the app and AutoFill flows.
- `PasswordStrengthEstimator.swift` scores passwords into the four-level strength meter shown in the app and extension; on both AutoFill allow-lists in `../../../project.yml` (dual-list rule in `../README.md`).
- `AutoFillIdentityStoreFallbackReader.swift` is a DEBUG + simulator-only backing-store fallback reader behind the `#if DEBUG && targetEnvironment(simulator)` seam in `CredentialIdentityStoreManager.swift`; it compiles to nothing in Release/on-device.
- `AutoFillMemoryLimit.swift` refuses an unlock the AutoFill extension's memory budget cannot survive, before Argon2 allocates and the process is killed with no error to report (#57). The requirement comes from `KDBXFileSummary` — the KDF parameters sit in the plaintext outer header — and the budget from `os_proc_available_memory`, which is `API_UNAVAILABLE(macos)` and reports 0 for an unlimited process; both the macOS branch and a reported 0 skip the check. `parseReserveBytes` is a deliberate floor for the decrypt/decompress/parse working set, not a prediction: the check exists to catch the case that is certain to fail, not to reject databases that would have opened. Scope: it runs after the file is already in memory, so it covers the KDF allocation and the parse that follows, not a database so large that reading it is itself fatal — that case still needs a guard on the read, and a second message, before the header can be inspected. On both AutoFill allow-lists in `../../../project.yml` (dual-list rule in `../README.md`).

## Change Carefully

- Keep these files extension-safe. If you add a new dependency from here to another service folder, verify that the target is included in `../../../project.yml`.
