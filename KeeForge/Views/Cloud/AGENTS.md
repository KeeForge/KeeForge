# Cloud Views

**Scope:** the cloud file and folder browser and the manual WebDAV and FTP connect forms. Folder-wide UI rules are in `../AGENTS.md`.

## Ownership

- `CloudFileBrowserView` (iOS only; the Mac connects and browses through `MacConnectServerSheet` and `MacRemoteBrowserViewController`) picks the manual form from the provider's connect seam (`WebDAVConnecting` or `FTPConnecting`); other providers use hosted sign-in. Connection logic is in `WebDAVConnectViewModel` / `FTPConnectViewModel`, listing and selection in `CloudFileBrowserSession` and `CloudFolderBrowserViewModel`.

## Invariants

- Each browser `NavigationStack` is `.id(session.selectedAccountID)`, so switching accounts drops pushed folder IDs that belong to the old account.
- A selection callback captures the listing's account ID and resolves it through `CloudFileBrowserSession.selectionAccount(matching:)`. A pick from a superseded account's listing must not be attributed to the current one.
- Both connect forms block Cancel and interactive dismissal while connecting, and on disappearance invalidate the form and clear the password. A late provider result cannot call back into a dismissed form; credentials a provider already persisted stay.

## Tests

- `WebDAVConnectViewModelTests`, `FTPConnectViewModelTests`, `CloudFileBrowserViewModelTests`. UI classes are in `CloudSyncUITests.swift` and `WebDAVSyncUITests.swift` (`CloudBrowserSmokeUITests`, `WebDAVAddFlowUITests`, `WebDAVConnectErrorUITests`).

## See also

- `../AGENTS.md`, `../../Services/Cloud/AGENTS.md`

- Cloud Recovery is accessible from Cloud account settings even while databases are locked. Export verifies retained ciphertext without restoring secrets or granting deletion consent. Before listing, it preserves byte-verified finalized legacy payloads under the journal commit lock so the existing export action can read them. Creation entries expose retry and confirmed discard only for prepared records, local completion only for confirmed receipts, and exact encrypted export for all unfinished phases. Discard compares the displayed snapshot under the creation locks before removing it. Unknown attempts have no Retry/Forget action, completed records stay hidden, and strict read or export errors retain every record and payload.

- The native Mac File → Cloud Recovery command exposes the Databases window’s recovery sheet independently of database registration; Database Settings also exposes it for an existing cloud reference. The launcher sheet owner handles its presentation and teardown.

- A recovery view owns one creation lifetime for its whole presentation. Native sheet teardown cancels it synchronously, before any delayed view disappearance; a dismissed recovery cannot dispatch another creation or finish local registration.
