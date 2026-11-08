# Cloud Views

**Scope:** the cloud file and folder browser and the manual WebDAV and FTP connect forms. Folder-wide UI rules, including the macOS grouped-form modifiers these forms need, are in `../AGENTS.md`.

## Ownership

- `CloudFileBrowserView` picks the manual form from the provider's connect seam (`WebDAVConnecting` or `FTPConnecting`); other providers use hosted sign-in. Connection logic is in `WebDAVConnectViewModel` / `FTPConnectViewModel`, listing and selection in `CloudFileBrowserSession` and `CloudFolderBrowserViewModel`.

## Invariants

- Each browser `NavigationStack` is `.id(session.selectedAccountID)`, so switching accounts drops pushed folder IDs that belong to the old account.
- A selection callback captures the listing's account ID and resolves it through `CloudFileBrowserSession.selectionAccount(matching:)`. A pick from a superseded account's listing must not be attributed to the current one.
- Both connect forms block Cancel and interactive dismissal while connecting, and on disappearance invalidate the form and clear the password. A late provider result cannot call back into a dismissed form; credentials a provider already persisted stay.

- Native-grant providers present Picker results as explicit selectable rows without falling back to a custom listing for authorization. Reconnect is account-bound; account-only creation connection is distinct. Parent sheet dismissal delegates cancellation to the owning session rather than sweeping provider-wide authentication.
- Drive destination folders carry opaque parent IDs, with My Drive root represented by nil. Literal filenames must not be parsed as paths or service identity.

## Tests

- `WebDAVConnectViewModelTests`, `FTPConnectViewModelTests`, `CloudFileBrowserViewModelTests`, `CloudNativeSelectionWorkflowTests`. UI classes are in `CloudSyncUITests.swift` and `WebDAVSyncUITests.swift` (`CloudBrowserSmokeUITests`, `WebDAVAddFlowUITests`, `WebDAVConnectErrorUITests`).

## See also

- `../AGENTS.md`, `../../Services/Cloud/AGENTS.md`
