# Security Services

This folder holds device-security integrations and secret-handling helpers outside the core models.

## Main Files

- `BiometricService.swift` wraps LocalAuthentication flows used by the app and AutoFill.
- `KeychainService.swift` stores composite keys with the shared access group and biometric access control.
- `PasskeyCrypto.swift` handles passkey-related crypto helpers used by the extension flow.
- `ScreenProtectionService.swift` manages screenshot/app-switcher protection behavior.

## Change Carefully

- Keychain account naming, access-group behavior, biometric prompts, and screen-protection defaults all have user-visible security consequences.
