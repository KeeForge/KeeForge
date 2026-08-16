# Security Services

This folder holds device-security integrations and secret-handling helpers outside the core models.

## Main Files

- `BiometricService.swift` wraps LocalAuthentication flows used by the app and AutoFill.
- `KeychainService.swift` stores composite keys with biometric access control, shared with the extension via the keychain access group (see the invariant below).
- `PasskeyCrypto.swift` handles passkey-related crypto helpers used by the extension flow: PEM key handling and assertion signing, plus registration support — ES256 key/credential-ID generation, attested authenticator data (COSE key, `aaguid` = KeeForge's stable product AAGUID `FF55D8C0-F4FB-4016-9FDD-56DBBD251802`), and the "none"-format WebAuthn attestation object via a minimal private CBOR encoder.
- `ScreenProtectionService.swift` holds both platform implementations behind `#if os(iOS)`/`#else`: iOS shields the app switcher and reacts to screen capture; macOS layers a resign-active cover with best-effort `NSWindow.sharingType` capture blocking through a single choke point (see `../../../docs/macos-security-notes.md`).
- `SecureRandom.swift` wraps `SecRandomCopyBytes` for throwing secure-random `Data` generation; on both AutoFill allow-lists in `../../../project.yml` (dual-list rule in `../README.md`).

## Change Carefully

- Keychain account naming, access-group behavior, biometric prompts, and screen-protection defaults all have user-visible security consequences.
- Access-group ordering invariant: `KeychainService` never sets `kSecAttrAccessGroup`, so its items land in the FIRST keychain access group listed in the calling target's entitlements. App/extension sharing therefore depends on `com.keevault.sharedkeychain` staying first in every entitlements file — ahead of `com.microsoft.adalcache` (iOS app) and `com.microsoft.identity.universalstorage` (Mac app). Reordering any `keychain-access-groups` array strands the shared composite keys. Also noted in a comment in `../../../AutoFillExtension/AutoFillExtensionMac.entitlements`.
