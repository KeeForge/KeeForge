# Cloud Views

Cloud provider file browsing and the manual WebDAV and FTP connect forms.

## Screen Map

- `WebDAVConnectView.swift` owns the manual WebDAV connect sheet (server address, username, password with `PasswordInputRow`, advanced unencrypted-HTTP opt-in, inline error, Connect/Cancel), backed by `WebDAVConnectViewModel`. Its nested sheet sizes itself to the form, so nothing is clipped today, but the `Form` still takes `macGroupedForm()` for the sheet rule above; each field takes `macFormFieldStyle()`, and the server field also `macLabelsHidden()` because the section header already says "Server".
- `FTPConnectView.swift` is the same form for FTP (server address, username, password, the mandatory Allow Unencrypted FTP toggle, inline error), backed by `FTPConnectViewModel`, with the same Mac form modifiers. `CloudFileBrowserView.swift`'s private `ManualConnectSheet` picks the form by the provider's connect seam (`WebDAVConnecting` or `FTPConnecting`).

Shared UI shells and the folder-wide UI rules live in `../README.md`.
