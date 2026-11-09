# KDBXKit

**Scope:** the KDBX container as a standalone Swift package: outer and inner headers, key derivation (AES-KDF, Argon2), composite keys and key files, HMAC block framing, outer ciphers, compression, and the inner random stream for protected values. Reading yields `KDBXContainer.Payload` (header plus XML); writing seals XML the caller serialized. The XML's meaning, KeeForge's model, and everything above it live in `KeeForge/Models/`.

## Invariants

- No KeeForge types, no UI frameworks, no app policy. The package depends only on Foundation, CryptoKit, CommonCrypto, Security, zlib, argon2, and `Vendor/KeeForgeTwofish`.
- No user-facing text. Errors are plain enums; the app gives them localized descriptions (`KeeForge/Models/KDBXKit+Localization.swift`). Adding an error case means adding its message there, in every shipped locale.
- No logging or printing: the package handles keys and decrypted payloads.
- Resource limits come from the caller as a `KDFExecutionPolicy`. The app's presets are in `KeeForge/Models/KDFExecutionPolicy+App.swift`.
- Saving is `prepareHeader` → caller serializes against `header.innerStreamKey` → `seal`. Every prepared header has fresh seeds, IV, inner stream key, and KDF salt, and a ChaCha20 inner stream.
- Wipe transient key material with `SecureWipe`, under the rules in its header comment.

## Public surface

- `KDBXContainer` reads (`readHeader`, `read`) and `KDBXContainerWriter` writes (`prepareHeader`, `seal`). `KDBXKeyDerivation`, `KDBXVariantMap`, `KDBXOuterCipher`, `KDBXInnerStream`, `KDBXKeyFile` (reading key files and generating new XML 2.0 ones), `KDBXCrypto` (composite keys only), `KDFExecutionPolicy`, and `SecureWipe` are the supporting types. Hashing, ciphers, gzip, and byte reading stay internal; widen the surface only for a caller that needs it.
- The header keeps raw values (cipher UUID, compression flags, stream ID, the variant map with unknown types) so a foreign file round-trips and an unknown value can be reported. Typed views (`cipher`, `compression`, `keyDerivation`) are computed from them.
- KDBX 3.1 is mapped onto the KDBX 4 header shape and read through the same calls; it is never written.

## Tests

- `Tests/KDBXKitTests` covers the package on its own, with `@testable import KDBXKit`. Prefer known-answer vectors from independent sources over round trips: a round trip cannot catch a wrong cipher or KDF. `Tests/KDBXKitTests/Fixtures/README.md` lists the fixtures.
- Fixture KDF outputs are precomputed constants, because the fixtures' Argon2 settings take minutes in a debug build. Regenerate them if a fixture changes.
- `scripts/coverage.sh` runs the suite and fails below its line, region, and function floors. Swift has no branch records, so region coverage is the branch measure. Raise a floor when coverage rises; never lower one to land a change. The remaining uncovered regions are library-call failures that cannot happen with valid sizes and compiler regions after `while true` loops.
- CI runs the script in the `macos-unit-tests` job (`../../.github/workflows/tests.yml`). Locally, run it under the repo Xcode lock.
- App tests do not link the package; they import it and get its symbols from the host app, since a second copy would make thrown errors fail type matches. They cover what the app adds on top: the model, saves, localization, and the KeePassXC gate in `KDBXCompatibilityTests`.
