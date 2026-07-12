# Slice 05: macOS AutoFill Extension

> Parent: [`epic.md`](./epic.md) · Depends on: 01, 04

## Goal

A system-wide macOS credential provider (passwords + passkeys) working in Safari, Chromium browsers, and native apps, reusing the slice-04 coordinator with a native `NSViewController` shell.

## Scope

**In:**
- New `KeeForgeMacAutoFill` app-extension target embedded in `KeeForgeMac`.
- macOS presentation shell for the coordinator (`ASCredentialProviderViewController` subclasses **NSViewController** on macOS): `NSHostingController` embedding of the shared SwiftUI views, `NSAlert` prompts, `preferredContentSize` sizing.
- Mac extension Info.plist + entitlements.
- Identity-store population from the Mac app (shared `CredentialIdentityStoreManager`).
- The manual QA matrix (system AutoFill is not UI-testable).

**Out:** any matching/vault/passkey logic change (owned by slice 04's coordinator — if the mac shell needs logic changes, the slice-04 seam was wrong; fix it there); one-time-code (`ProvidesOneTimeCodes`) parity investigation if macOS 14 doesn't support it — note and defer rather than block.

## Affected areas

- New: mac shell file(s) in `AutoFillExtension/` (e.g., a `#if os(macOS)` companion to the iOS shell), `AutoFillExtension/InfoMac.plist` (NSExtension point `com.apple.authentication-services-credential-provider-ui`; `ASCredentialProviderExtensionCapabilities`: ProvidesPasswords, ProvidesPasskeys; carry over the save/generate capability keys only if supported on macOS 14 — verify against the SDK, don't assume), `AutoFillExtension/AutoFillExtensionMac.entitlements` (autofill-credential-provider, app-sandbox, App Group, keychain-access-groups).
- Modified: `project.yml` — `KeeForgeMacAutoFill` target (`app-extension`, `platform: macOS`, bundle `com.keevault.app.autofill`, `ENABLE_HARDENED_RUNTIME: YES`, same shared-source allow-list as `KeeForgeAutoFill` — all 20 entries verified portable after slice 01's FaviconService image branch); `KeeForgeMac` gains the `embed: true` dependency.
- Unchanged: `CredentialProviderCoordinator.swift` (gains target membership only), all `KeeForge/Services/AutoFill/*` shared sources.

Security invariants:
- **Keychain-access-group ordering identical to iOS** in the mac entitlements — items stored without an explicit `kSecAttrAccessGroup` land in the first listed group; reordering would strand existing items.
- The mac shell must route every completion/cancel path through the coordinator's `cleanup()` — including `NSAlert` dismissals and window-close, which have no iOS analogue.
- Extension reads the App Group cached database copy exactly as iOS does; no new writes to the group container (epic guardrail).

## KeeForge bits

- **Targets:** mac shell + InfoMac.plist + mac entitlements → KeeForgeMacAutoFill only. `CredentialProviderCoordinator.swift` and the 20 allow-listed shared sources gain KeeForgeMacAutoFill membership. iOS targets untouched.
- **project.yml:** new target + embed dependency as above; keep the shared-source allow-list literally in sync with `KeeForgeAutoFill` (same paths, same order — divergence here is a standing maintenance trap worth a comment in the YAML). Run `xcodegen generate`.
- **Accessibility identifiers:** existing AutoFill view identifiers preserved (shared views). No new ones expected; add them if the mac shell introduces chrome.

## Testing

- **Unit:** the full AutoFill test suite plus slice-04's coordinator tests, now also on `KeeForgeMacTests` — they compile there via shared sources and must pass (they exercise coordinator + matching + passkey logic, not the shell).
  New: mac-shell lifecycle tests where feasible without the system harness — `test_shellCancel_invokesCleanup`, `test_alertDismissal_invokesCleanup` (drive the shell's completion paths with a stub coordinator).
  Run slice: `-only-testing:KeeForgeMacTests/CredentialMatcherTests -only-testing:KeeForgeMacTests/PasskeyTests -only-testing:KeeForgeMacTests/CredentialProviderCoordinatorTests`.
- **Integration / UI:** N/A — XCUITest cannot drive System Settings enablement or the AutoFill panel on macOS (same limitation as iOS).
- **Manual (the acceptance for this slice — run the full matrix):**
  - Enablement: System Settings → Passwords/AutoFill shows KeeForge; enabling activates the provider.
  - Safari: password fill on a saved site; QuickType-equivalent inline suggestion; passkey registration on webauthn.io; passkey assertion.
  - Chrome (or another Chromium browser): password fill via the system AutoFill panel.
  - Native app password field fill.
  - Touch ID unlock inside the extension on a Touch ID Mac; login-password fallback on a non-Touch-ID Mac.
  - Cancel from every extension screen; confirm no vault stays unlocked (relaunch extension → locked state).
  - Identities: adding/removing an entry in the Mac app updates suggestions (`CredentialIdentityStoreManager` round-trip).
- **Edge cases that apply:** locked database on activation, database file missing/stale bookmark inside the extension sandbox, biometric failure fallback, two databases with overlapping domains, extension invoked while main app holds the database open (file coordination).

## Exit criteria

- [ ] Unit tests green on both `KeeForgeTests` and `KeeForgeMacTests`.
- [ ] Full manual QA matrix executed and recorded in the PR description.
- [ ] No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] `xcodegen generate` run; `AutoFillExtension/README.md` updated (mac shell + capability notes).
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- macOS: system-wide AutoFill — passwords and passkeys in Safari, Chromium browsers, and native apps.`
