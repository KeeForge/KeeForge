# OneTimeCodes

**Scope:** one-time codes over plain bytes as a standalone Swift package: TOTP (RFC 6238) on HOTP (RFC 4226), Base32 (RFC 4648), the strict `otpauth://totp` enrollment parser, the algorithm enum with its `otpauth` and KeePass names, and the KeeOTP query rewrite. Sealed secrets, the session key, the placeholder shown for an unusable secret, and reading TOTP out of KDBX fields live in `KeeForge/Models/`.

## Invariants

- No KeeForge types, no UI frameworks, no app policy. Foundation and CryptoKit only.
- No user-facing text, logging, or printing. Errors are plain enums; the app words them.
- `TOTPAlgorithm.rawValue` (`SHA1`, `SHA256`, `SHA512`) is persisted through `Codable` in app payloads. Never change it.
- Generation never fails: `TOTPParameters` refuses only an empty secret, and clamps the period to at least 1 and the digits to 1...9 instead of rejecting them. Whatever the app shows when a secret does not resolve is its own choice.
- Secrets are held as `SymmetricKey`. `Base32.decode` writes into one pre-sized buffer, so it leaves no stray copy for a caller that wipes the result.
- `OTPAuthURI` is strict and keeps `rawURI` byte-verbatim apart from the lowercased scheme and authority. Lenient reading of stored values belongs to the app's parser until it moves here (see `README.md`).

## Public surface

- `TOTPParameters`, `TOTP` (`code(for:at:)`, `secondsRemaining(period:at:)`), `TOTPAlgorithm`, `Base32` (`decode`, `encode`, `canonicalSecret`), `OTPAuthURI` with `OTPAuthURIError`, and `KeeOTPQuery.rewriting`. `HOTP` stays internal; widen the surface only for a caller that needs it.

## Tests

- `Tests/OneTimeCodesTests` covers the package with known answers from independent sources, listed in `Tests/OneTimeCodesTests/Fixtures/README.md`. Prefer them over round trips.
- `scripts/coverage.sh` runs the suite and fails below its line, region, and function floors (all 100%). Region coverage is the branch measure. Never lower a floor to land a change. A `??` default or `@autoclosure` that can never run counts as an uncovered function: restructure rather than lower the floor.
- CI runs the script in the `macos-unit-tests` job (`../../.github/workflows/tests.yml`). Locally, run it under the repo Xcode lock.
- App tests do not link the package; they import it and get its symbols from the host app, since a second copy would make thrown errors fail type matches. They cover what the app adds: `TOTPGeneratorTests` for decryption, `decodedSecret` precedence, and the placeholder, and the KDBX suites for stored TOTP fields.
