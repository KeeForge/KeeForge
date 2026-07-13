# AutoFillExtension

This target provides password, passkey, one-time-code, and new-credential save/generate fulfillment through `AuthenticationServices`.

## Main Files

- `CredentialProviderCoordinator.swift` is the platform-neutral core: request handling (passwords, passkeys, one-time codes, save/generate-password), vault access and unlock orchestration, credential matching, passkey assertion, and the `cleanup()` teardown lifecycle. It must stay free of UIKit/AppKit so a future macOS shell can host it unchanged; it talks to the shell only through the narrow `CredentialProviderPresenting` protocol ("present this view", "ask this question", "complete with this credential/error").
- `CredentialProviderViewController.swift` is the thin iOS shell and extension entry point: it forwards system requests to the coordinator, hosts the SwiftUI views in `UIHostingController`s, shows `UIAlertController` prompts, and relays completions/cancellations to the extension context. No matching or vault logic lives here.
- `AutoFillSearchView.swift` renders the searchable SwiftUI UI shown inside the extension.
- `AutoFillEntryCreatorView.swift` renders the credential-creation UI used for save-password requests and strong-password generation follow-up.

## How It Works

- The extension looks up the active database through `../KeeForge/Services/Persistence/DatabaseListStore.swift` and reads the shared cached database copy from the App Group container.
- It reuses `../KeeForge/Models` plus a selected subset of service files declared explicitly in `../project.yml`.
- The shared model layer links the local `KeeForgeTwofish` package, so Twofish-encrypted databases use the same parser and cipher-preserving writer in the app and extension.
- Unlock can use stored composite keys plus biometrics for quick AutoFill, or fall back to interactive password entry.
- Password and passkey requests both parse the database locally; the extension does not depend on the main app being open.
- Expired entries are excluded from proactive identities and automatic password, passkey, and one-time-code fulfillment. They remain available in the interactive picker with an explicit warning and require a manual tap.
- Save-password requests now prefill a new entry via `../KeeForge/Services/AutoFill/AutoFillSaveCoordinator.swift`, save encrypted bytes through `../KeeForge/Services/Persistence/LocalDatabaseSaver.swift`, and enqueue `../KeeForge/Services/Cloud/PendingUploadQueue.swift` markers for cloud-backed databases before returning success.

## Change Carefully

- Keep dependencies extension-safe. If the extension needs another service file, add it explicitly to the `KeeForgeAutoFill` sources in `../project.yml`.
- Keep `CredentialProviderCoordinator.swift` free of UIKit imports and types. It is also compiled into the `KeeForge` app target (see `../project.yml`) so `KeeForgeTests/CredentialProviderCoordinatorTests.swift` can unit-test it.
- Every completion path (success, user cancel, error alert dismissal, silent-request failure) must funnel through the coordinator's completion helpers so `cleanup()` — the extension's only "lock" — always clears the session key and parsed vault state.
- Changes to App Group storage, shared defaults, cached database copy semantics, or Keychain semantics usually affect both targets.
- Relevant tests are usually in `../KeeForgeTests/CredentialProviderCoordinatorTests.swift`, `../KeeForgeTests/CredentialProviderSaveTests.swift`, `../KeeForgeTests/CredentialIdentityStoreManagerTests.swift`, `../KeeForgeTests/CredentialMatcherTests.swift`, `../KeeForgeTests/PasskeyTests.swift`, and `../KeeForgeTests/SharedVaultStoreTests.swift`.
