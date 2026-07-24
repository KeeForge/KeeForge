# AutoFillExtension

This target provides password, passkey, one-time-code, and new-credential save/generate fulfillment through `AuthenticationServices`.

## Main Files

- `CredentialProviderCoordinator.swift` is the platform-neutral core: request handling (passwords, passkeys, one-time codes, save/generate-password), vault access and unlock orchestration, credential matching, passkey assertion, and the `cleanup()` teardown lifecycle. It must stay free of UIKit/AppKit so a future macOS shell can host it unchanged; it talks to the shell only through the narrow `CredentialProviderPresenting` protocol ("present this view", "ask this question", "complete with this credential/error").
- `CredentialProviderViewController.swift` is the thin iOS shell and extension entry point (whole file is `#if os(iOS)`): it forwards system requests to the coordinator, hosts the SwiftUI views in `UIHostingController`s, shows `UIAlertController` prompts, and relays completions/cancellations to the extension context. No matching or vault logic lives here.
- `CredentialProviderViewControllerMac.swift` is the macOS shell (`#if os(macOS)`). On macOS `ASCredentialProviderViewController` subclasses `NSViewController`, so this shell hosts `AutoFillSearchView` in an `NSHostingController`, shows `NSAlert` prompts for unlock / error / read-only, and sets `preferredContentSize`. It routes **every** completion, cancel, `NSAlert` dismissal, and window close (`viewDidDisappear` → `cancelActiveRequestIfNeeded()`) back through the coordinator so `cleanup()` always runs — window close has no iOS analogue. Extension-context calls go through a small `CredentialProviderRequestCompleting` seam so the shell's cleanup routing is unit-testable without the system harness.
- `AutoFillSearchView.swift` renders the searchable SwiftUI UI shown inside the extension (shared by both shells).
- `AutoFillEntryCreatorView.swift` renders the credential-creation UI used for save-password requests and strong-password generation follow-up. It is `#if os(iOS)` because save/generate-password are iOS-only (see capability notes below).
- `Localizable.xcstrings` — String Catalog (source language `en`, plus `de`) for both AutoFill extension targets.
- `InfoPlist.xcstrings` — localized Info.plist values (e.g. `CFBundleDisplayName`) for both AutoFill extension targets.

## How It Works

- The extension resolves each request's target database through `../KeeForge/Services/Persistence/DatabaseListStore.swift` and reads the shared cached database copy from the App Group container. Requests that carry a record identifier (QuickType tap, silent fill, passkey/one-time-code by identity) unlock the database that owns the identity; identifier-less flows (manual search, save) use `DatabaseListStore.defaultAutoFillDatabase`. Databases with AutoFill disabled are treated as nonexistent, stale identities are cleaned up on tap, and with zero enabled databases the shells show `AutoFillNoEnabledDatabasesView` instead of an unlock prompt.
- With two or more AutoFill-enabled databases, `AutoFillSearchView` shows a toolbar database switcher (`CredentialProviderDatabaseSwitcherContext`, built by the coordinator). Picking another database runs its standard unlock flow and re-presents the same request against it; the previous database's vault state is retained until the new unlock succeeds, so cancelling the switch falls back to the previous database instead of ending the request.
- It reuses `../KeeForge/Models` plus a selected subset of service files declared explicitly in `../project.yml`.
- The shared model layer links the local `KeeForgeTwofish` package, so Twofish-encrypted databases use the same parser and cipher-preserving writer in the app and extension.
- Unlock can use stored composite keys plus biometrics for quick AutoFill, or fall back to interactive password entry.
- Interactive requests are presentation-order independent: the coordinator waits while the shell is off screen and schedules pending UI immediately when a request arrives after the shell has appeared.
- Password and passkey requests both parse the database locally; the extension does not depend on the main app being open.
- Expired entries are excluded from proactive identities and automatic password, passkey, and one-time-code fulfillment. They remain available in the interactive picker with an explicit warning and require a manual tap.
- Save-password requests now prefill a new entry via `../KeeForge/Services/AutoFill/AutoFillSaveCoordinator.swift`, save encrypted bytes through `../KeeForge/Services/Persistence/LocalDatabaseSaver.swift`, and enqueue `../KeeForge/Services/Cloud/PendingUploadQueue.swift` markers for cloud-backed databases before returning success.

## Platforms And Targets

- Two extension targets share this folder: `KeeForgeAutoFill` (iOS, embedded in `KeeForge`) and `KeeForgeMacAutoFill` (macOS, embedded in `KeeForgeMac`). Both pull in `CredentialProviderCoordinator.swift` plus an identical, order-locked allow-list of shared service/view sources — see the "SHARED AUTOFILL ALLOW-LIST (maintenance invariant)" markers in `../project.yml`. Edit both lists together.
- `CredentialProviderCoordinator.swift`, `CredentialProviderViewControllerMac.swift`, and `AutoFillSearchView.swift` are also compiled into the `KeeForgeMac` app target so `KeeForgeMacTests` can unit-test the coordinator and the mac shell lifecycle. The coordinator alone is compiled into the iOS `KeeForge` app target (the iOS shell is not unit-hosted).
- Mac Info.plist is `InfoMac.plist`; mac entitlements are `AutoFillExtensionMac.entitlements` (both excluded from the iOS target's source glob so they are not bundled as stray iOS resources). `KeeForgeMacAutoFill` sets `ENABLE_HARDENED_RUNTIME: YES` with **zero** `com.apple.security.cs.*` exceptions. Its `keychain-access-groups` list mirrors the iOS `AutoFillExtension.entitlements` order exactly (single shared group); MSAL's keychain group is app-only and intentionally absent.

## macOS Capability Notes (macOS 26.5 SDK, verified against AuthenticationServices headers)

- **Passwords + passkeys**: available on macOS 14 — advertised via `ProvidesPasswords` / `ProvidesPasskeys` in `InfoMac.plist`. All `ASPasskey*` / `ASPassword*` request/credential types are `macos(14.0)`.
- **One-time codes**: `ASOneTimeCodeCredential`, `ASOneTimeCodeCredentialRequest`, and `completeOneTimeCodeRequest(using:)` are `macos(15.0)+`, **not** macOS 14. The coordinator's OTC paths compile behind `@available(iOS 18.0, macOS 15.0, *)`, but `ProvidesOneTimeCodes` is **not** advertised on macOS (the slice guardrail only carries capability keys that exist on the macOS 14 floor). Deferred; can be flipped on for a macOS-15 minimum later.
- **Save-password / generate-password**: `ASSavePasswordRequest`, `ASGeneratePasswordsRequest`, `ASGeneratedPassword`, `completeSavePasswordRequest`, and `completeGeneratePasswordRequest` are `API_UNAVAILABLE(macos)` on every macOS version. The coordinator's save/generate surface is `#if os(iOS)`; the mac shell's `presentEntryCreator` / `presentGeneratedPassword` / `completeSave…` / `completeGenerate…` are unreachable stubs. `Supports*PasswordCredentials*` keys are omitted from `InfoMac.plist`.

## Change Carefully

- Keep dependencies extension-safe. If the extension needs another service file, add it explicitly to **both** the `KeeForgeAutoFill` and `KeeForgeMacAutoFill` allow-lists in `../project.yml` (same path, same position).
- Keep `CredentialProviderCoordinator.swift` free of UIKit/AppKit imports and types. It is compiled into the `KeeForge` and `KeeForgeMac` app targets (see `../project.yml`) so `KeeForge(Mac)Tests/CredentialProviderCoordinatorTests.swift` can unit-test it.
- Every completion path (success, user cancel, error alert dismissal, silent-request failure) must funnel through the coordinator's completion helpers so `cleanup()` — the extension's only "lock" — always clears the session key and parsed vault state.
- Changes to App Group storage, shared defaults, cached database copy semantics, or Keychain semantics usually affect both targets.
- Relevant tests are usually in `../KeeForgeTests/CredentialProviderCoordinatorTests.swift`, `../KeeForgeTests/CredentialProviderSaveTests.swift`, `../KeeForgeTests/CredentialIdentityStoreManagerTests.swift`, `../KeeForgeTests/CredentialMatcherTests.swift`, `../KeeForgeTests/PasskeyTests.swift`, and `../KeeForgeTests/SharedVaultStoreTests.swift`.
