# AutoFill Services

This folder holds extension-facing helpers shared between the main app and the AutoFill target.

## Main Files

- `AutoFillSaveCoordinator.swift` stages and saves new credentials, refreshes shared caches, and queues deferred cloud uploads when needed.
- `CredentialMatcher.swift` matches KeePass entries to web domains and usernames for AutoFill suggestions.
- `CredentialIdentityStoreManager.swift` mirrors unlocked entries into the system credential identity store. It also owns `CredentialRecordIdentifier` (the sole encoder/parser of the database-tagged record-identifier format on published identities) and the `CredentialIdentityStoreProviding` seam (production: `SystemCredentialIdentityStore`; tests swap a fake via the `#if DEBUG` `storeProviderOverride`).
- `PasswordGenerator.swift` provides the reusable strong-password generator used by both the app and AutoFill flows.

## Change Carefully

- Keep these files extension-safe. If you add a new dependency from here to another service folder, verify that the target is included in `../../../project.yml`.
