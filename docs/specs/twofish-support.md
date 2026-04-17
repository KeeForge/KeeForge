# Twofish Support

Add outer-cipher support for `Twofish` alongside the existing `AES-256-CBC` and `ChaCha20-Poly1305` paths, for both `KDBX 3.1` and `KDBX 4.x`.

## Scope

- Read `KDBX 3.1` databases encrypted with `Twofish`.
- Write `KDBX 3.1` databases encrypted with `Twofish`.
- Read `KDBX 4.x` databases encrypted with `Twofish`.
- Write `KDBX 4.x` databases encrypted with `Twofish`.
- Preserve existing `AES` and `ChaCha20` behavior unchanged.

## Approach

- Introduce a dedicated `Twofish` outer-cipher implementation in `KeeForge/Models/KDBXCrypto.swift`.
- Add the KDBX `Twofish` cipher UUID to `KeeForge/Models/KDBXParser.swift`.
- Route both parser and writer outer-cipher selection through the cipher UUID, rather than format-specific special cases.
- Keep `KDBX 3.1` and `KDBX 4.x` framing logic separate; only the payload cipher changes.
- Prefer a vetted vendored/library implementation over a new hand-rolled cipher.

## Compatibility Notes

- `Twofish` uses a 16-byte block size and a 16-byte IV in CBC mode.
- Real-world clients appear to vary in padding strictness; parser behavior may need a compatibility fallback for malformed-but-common `Twofish` padding.
- `KDBX 4.x` still uses the same KDF/header/HMAC flow; `Twofish` only changes the outer payload encryption step.

## Tests

- Fixture-backed `KDBX 3.1` `Twofish` parse test.
- Fixture-backed `KDBX 4.x` `Twofish` parse test.
- `KDBX 3.1` write-then-reparse round trip using `Twofish`.
- `KDBX 4.x` write-then-reparse round trip using `Twofish`.
- Negative test for unsupported/unknown cipher UUIDs.

## Done When

- KeeForge can open and save `AES`, `ChaCha20`, and `Twofish` databases where the format permits them.
- The smallest relevant parser/writer test slices cover all supported outer ciphers for both `KDBX 3.1` and `KDBX 4.x`.
