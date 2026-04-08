# AutoFillExtension

This target provides password, passkey, and one-time-code fulfillment through `AuthenticationServices`.

## Main Files

- `CredentialProviderViewController.swift` is the extension entry point for interactive and silent credential requests.
- `AutoFillSearchView.swift` renders the searchable SwiftUI UI shown inside the extension.

## How It Works

- The extension looks up the active database through `../KeeForge/Services/DatabaseListStore.swift` and reads the shared cached database copy from the App Group container.
- It reuses `../KeeForge/Models` plus a selected subset of service files declared explicitly in `../project.yml`.
- Unlock can use stored composite keys plus biometrics for quick AutoFill, or fall back to interactive password entry.
- Password and passkey requests both parse the database locally; the extension does not depend on the main app being open.

## Change Carefully

- Keep dependencies extension-safe. If the extension needs another service file, add it explicitly to the `KeeForgeAutoFill` sources in `../project.yml`.
- Changes to App Group storage, shared defaults, cached database copy semantics, or Keychain semantics usually affect both targets.
- Relevant tests are usually in `../KeeForgeTests/CredentialIdentityStoreManagerTests.swift`, `../KeeForgeTests/CredentialMatcherTests.swift`, `../KeeForgeTests/PasskeyTests.swift`, and `../KeeForgeTests/SharedVaultStoreTests.swift`.
