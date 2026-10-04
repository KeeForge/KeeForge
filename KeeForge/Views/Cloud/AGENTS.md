# Cloud Views

Cloud provider file browsing and the manual WebDAV and FTP connect forms.

## Screen Map

- `WebDAVConnectView.swift` owns the manual WebDAV connect sheet (server address, username, password with `PasswordInputRow`, advanced unencrypted-HTTP opt-in, inline error, Connect/Cancel), backed by `WebDAVConnectViewModel`. Its nested sheet sizes itself to the form, so nothing is clipped today, but the `Form` still takes `macGroupedForm()` for the sheet rule above; each field takes `macFormFieldStyle()`, and the server field also `macLabelsHidden()` because the section header already says "Server".
- `FTPConnectView.swift` is the same form for FTP (server address, username, password, the mandatory Allow Unencrypted FTP toggle, inline error), backed by `FTPConnectViewModel`, with the same Mac form modifiers. `CloudFileBrowserView.swift`'s private `ManualConnectSheet` picks the form by the provider's connect seam (`WebDAVConnecting` or `FTPConnecting`).

Both manual connect forms block Cancel and interactive dismissal while connecting, then invalidate their form lifetime and clear the password on disappearance. A late provider result cannot invoke the dismissed form's callback or publish an error; credential persistence already committed by a provider is preserved.

`CloudFileBrowserView.swift` owns file picking and creation-folder picking. Each navigation stack is keyed by selected account, so switching accounts drops pushed folder IDs. Selection callbacks capture the listing's account ID and validate it through `CloudFileBrowserSession.selectionAccount(matching:)`; the folder view model also clears old files when a new account starts loading and rejects superseded results.

Shared UI shells and the folder-wide UI rules live in `../README.md`.
