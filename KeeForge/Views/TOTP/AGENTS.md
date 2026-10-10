# TOTP Views

**Scope:** TOTP enrollment surfaces: the QR scanner sheet (iOS only) and the destination picker for an incoming `otpauth://` URL. The editor's One-Time Password section is in `../Entry/EntryEditView.swift`. Folder-wide UI rules are in `../AGENTS.md`.

## Ownership

- URI parsing and validation live in `OTPAuthURI` and `EntryEditViewModel.applyOTPAuthURI(_:)`; every enrollment path funnels through them. Destination filtering and decisions live in `TOTPEnrollmentViewModel`. Keep both out of the views so they stay unit-tested.
- The destination picker opens the normal `EntryEditView` with the URI already applied (pushed on iOS, a sheet on macOS). The user reviews and saves through the standard editor flow.

## Invariants

- Saving or deleting in the editor finishes the enrollment; cancelling returns to the destination list, so a wrong pick does not destroy the incoming code. This is why `EntryEditView.Completion` distinguishes `.cancelled`.
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
