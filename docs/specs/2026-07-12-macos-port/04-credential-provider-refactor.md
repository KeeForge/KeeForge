# Slice 04: CredentialProvider Refactor (iOS-only)

> Parent: [`epic.md`](./epic.md) · Depends on: — (parallelizable with 01–03)

## Goal

Split the ~1,000-LOC `AutoFillExtension/CredentialProviderViewController.swift` into a platform-neutral coordinator plus a thin iOS presentation shell, with zero behavior change — proven by the ~100 existing AutoFill unit tests — so slice 05 can add a macOS shell without touching the logic.

## Scope

**In:**
- Extract everything that is not UIKit presentation into a `CredentialProviderCoordinator` (or similarly named type): request handling (`prepareCredentialList` for passwords and passkeys, `prepareInterfaceToProvideCredential`, the iOS 26.2-gated save/generate-password flows), vault access/unlock orchestration, credential matching, passkey assertion, and `cleanup()` lifecycle.
- Leave a thin `CredentialProviderViewController` shell: `UIHostingController` embedding of the existing SwiftUI views (`AutoFillSearchView`, `AutoFillEntryCreatorView`), `UIAlertController` prompts, extension-context completion calls routed through the coordinator.
- iOS only. This lands and ships (or at least merges) independently of any Mac target.

**Out:** the macOS shell, mac targets, mac entitlements/Info.plist (slice 05); any feature change, matching-logic change, or UI change — this slice is a pure refactor.

## Affected areas

- New: `AutoFillExtension/CredentialProviderCoordinator.swift` (platform-neutral: Foundation, AuthenticationServices, CryptoKit, SwiftUI-view-model level only — must compile without UIKit).
- Modified: `AutoFillExtension/CredentialProviderViewController.swift` — shrinks to the iOS shell.
- Unchanged: `KeeForge/Services/AutoFill/*` (CredentialMatcher, CredentialIdentityStoreManager, AutoFillSaveCoordinator), `PasskeyCrypto.swift`, the embedded SwiftUI views. If the refactor wants to change their APIs, that's scope creep — stop.

Design constraints (behavior invariants, not implementation prescriptions):
- **`cleanup()` is the extension's only "lock":** the coordinator must guarantee session-key and vault teardown on every completion path — success, user cancel, error alert dismissal, and extension-context cancellation. The existing tests cover much of this; add coverage for any path they miss.
- The coordinator's seam to the shell should be narrow enough that slice 05's `NSHostingController`/`NSAlert` shell needs no knowledge of matching or vault logic (roughly: "present this view", "ask this question", "complete with this credential/error").
- Preserve the `@available(iOS 26.2, *)` gating semantics exactly.

## KeeForge bits

- **Targets:** `CredentialProviderCoordinator.swift` → KeeForgeAutoFill (KeeForgeMacAutoFill added in slice 05). `CredentialProviderViewController.swift` stays KeeForgeAutoFill-only.
- **project.yml:** add the new source file to the `KeeForgeAutoFill` target's `AutoFillExtension` path (already covered by the folder source entry — verify, since the folder is included wholesale). Run `xcodegen generate`.
- **Accessibility identifiers:** all existing AutoFill view identifiers preserved untouched (the SwiftUI views don't change).

## Testing

- **Unit:** the ~100 existing AutoFill tests are the harness and must pass unmodified: `CredentialIdentityStoreManagerTests`, `PasskeyTests`, `CredentialMatcherTests`, `CredentialProviderSaveTests`, `PasskeyDisplayTests` (recount at implementation time — the suite grows). Where tests currently reach through the view controller, retarget them at the coordinator — assertions unchanged.
  New: `CredentialProviderCoordinatorTests.swift` — `test_cleanup_runsOnCancel`, `test_cleanup_runsOnError`, `test_cleanup_runsOnSuccessfulCompletion` (session key nil + vault state cleared on each path), plus one test that the coordinator compiles/runs without any UIKit import (enforced by target-membership discipline rather than a runtime assert).
  Run slice: `-only-testing:KeeForgeTests/CredentialMatcherTests -only-testing:KeeForgeTests/PasskeyTests -only-testing:KeeForgeTests/CredentialProviderSaveTests -only-testing:KeeForgeTests/CredentialProviderCoordinatorTests`.
- **Integration / UI:** N/A — XCUITest cannot drive the system AutoFill UI; manual pass below.
- **Manual:** one full iOS AutoFill regression on device/simulator: QuickType suggestion fill, in-extension search + fill, passkey assertion, save-new-credential flow, cancel from every screen (verifies cleanup paths in vivo).
- **Edge cases that apply:** locked database when the extension activates, biometric failure → password fallback inside the extension, cancellation at each stage, extension memory pressure (no retained vault after completion).

## Exit criteria

- [ ] All pre-existing AutoFill tests pass with unchanged assertions; new coordinator tests pass.
- [ ] Manual iOS AutoFill regression done.
- [ ] No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] `xcodegen generate` if needed; `AutoFillExtension/README.md` updated with the coordinator/shell split.
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- Internal: restructure the AutoFill extension for upcoming macOS support (no user-facing change).`
