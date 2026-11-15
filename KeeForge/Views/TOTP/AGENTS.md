# TOTP Views

**Scope:** TOTP enrollment surfaces: the QR scanner sheet (iOS only) and the destination picker for an incoming `otpauth://` URL. The editor's verification-code rows are in `../Entry/EntryEditView.swift` (iOS) and `../Entry/Mac/MacEntryEditorView.swift` (Mac). Folder-wide UI rules are in `../AGENTS.md`.

## Ownership

- URI parsing and validation live in `OTPAuthURI` and `EntryEditViewModel.applyOTPAuthURI(_:)`; every enrollment path funnels through them. Destination filtering and decisions live in `TOTPEnrollmentViewModel`. Keep both out of the views so they stay unit-tested.
- The destination picker opens the normal editor with the URI already applied: `EntryEditView` pushed on iOS; on Mac the pick ends the sheet and opens the window's inline editor through `MacWorkspacePresentation.beginEnrollmentEditor` (an edit selects its entry first). The user reviews and saves through the standard editor flow.
- Two ways in: an `otpauth://` link, and on iOS the vault's New › Scan QR Code, which opens the destination picker once the scanner sheet has dismissed (a presentation started while another dismisses is dropped).

## Invariants

- On iOS saving or deleting in the editor finishes the enrollment; cancelling returns to the destination list, so a wrong pick does not destroy the incoming code. This is why `EntryEditView.Completion` distinguishes `.cancelled`. On Mac cancelling the inline editor discards the code. While that window already has an editor open, the picks are disabled with a note, so its unsaved work is never replaced.
- The picker's search is its own local text in `TOTPEnrollmentViewModel`, never the session's global `searchText`.
- The replace confirmation is anchored to the stack content, not a row: rows are filtered away under search and would take the dialog host with them.
- `TOTPQRScannerSheet.swift` is wholly `#if os(iOS)`; VisionKit's scanner does not exist on macOS, where the scan affordance is hidden.
- A rejected QR payload can carry a secret. The hint debounce keeps its SHA-256 digest, never the payload.
- `startScanning()` fails before the scanner is on screen, so the start is deferred with one retry and only a still-failing start shows the unavailable state. Camera denial is not terminal: availability is re-checked when the scene becomes active.

## Tests

- `TOTPEnrollmentViewModelTests`, `OTPAuthURITests`.
- `TOTPEnrollmentDeepLinkUITests` drives the destination sheet through the launched-with-URL path only. A link arriving while a session is already unlocked, and system default-app routing, are manual device checks.
- XCUITest cannot drive the camera; the scanner sheet has no UI coverage.

## See also

- `../AGENTS.md`, `../Entry/AGENTS.md`
- `../../ViewModels/AGENTS.md`: `AppRoutingCoordinator` owns the pending enrollment
