# KDBXKit

**Scope:** the KDBX container as a standalone Swift package: outer and inner headers, key derivation (AES-KDF, Argon2), composite keys and key files, HMAC block framing, outer ciphers, compression, and the inner random stream for protected values. Reading yields `KDBXContainer.Payload` (header plus XML); writing seals XML the caller serialized. The XML's meaning, KeeForge's model, and everything above it live in `KeeForge/Models/`.

## Invariants

- No KeeForge types, no UI frameworks, no app policy. The package depends only on Foundation, CryptoKit, CommonCrypto, Security, zlib, argon2, and `Vendor/KeeForgeTwofish`.
- No user-facing text. Errors are plain enums; the app gives them localized descriptions (`KeeForge/Models/KDBXKit+Localization.swift`). Adding an error case means adding its message there, in every shipped locale.
- No logging or printing: the package handles keys and decrypted payloads.
- Resource limits come from the caller as a `KDFExecutionPolicy`. The app's presets are in `KeeForge/Models/KDFExecutionPolicy+App.swift`.
- Saving is `prepareHeader` → caller serializes against `header.innerStreamKey` → `seal`. Every prepared header has fresh seeds, IV, inner stream key, and KDF salt, and a ChaCha20 inner stream.
- Wipe transient key material with `SecureWipe`, under the rules in its header comment.

## Tests

- The app's test targets cover the package: `KDBXParserTests` (container read, KDF, Salsa20 and Argon2 known answers), `KDBXWriterTests` (container write), `ChaCha20Tests`, `TwofishTests`, `KeyFileProcessorTests`, `KeyFileGeneratorTests`, `KDFExecutionPolicyTests`, `SecureWipeTests`, and the KeePassXC gate in `KDBXCompatibilityTests`.
- Test targets import `KDBXKit` without linking it; the symbols come from the host app. Linking the package into a test bundle as well would load a second copy, and errors thrown by one copy would not match the other's types.
- `swift build` in this folder checks that the package builds on its own.
