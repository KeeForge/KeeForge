# KDBXKit test fixtures

The databases are copies of files in the repository's `TestFixtures/` (`../../../../../TestFixtures`, `compatibility/` for the foreign and legacy ones), so the package tests run on their own. Their provenance and generators are documented in `TestFixtures/README.md`; update both copies together.

| File | Credentials | Format |
| --- | --- | --- |
| `test.kdbx` | `testpassword123` | KDBX 4.0, AES-256, Argon2d |
| `demo-keyfile.kdbx` | `demo` + `demo-keyfile.key` | KDBX 4.0, AES-256, Argon2d |
| `challenge-response-aeskdf.kdbx` | `challenge-response` + YubiKey response | KDBX 4.0, AES-KDF (header only in these tests) |
| `legacy-kdbx31.kdbx` | `testpassword123` | KDBX 3.1, AES-256, Salsa20 inner stream |
| `foreign-chacha20.kdbx` | `foreign-chacha20` | KDBX 4.0, ChaCha20 |
| `foreign-twofish.kdbx` | `foreign-twofish` | KDBX 4.0, Twofish |
| `unknown-inner-header.kdbx` | `unknown-inner-header` | KDBX 4.0; inner header has unknown ids 0x21 (between the two binaries), 0x7F, and an empty 0x10 |

`demo-keyfile.key` (a 32-byte binary key file holding bytes 0x00...0x1f) and `invalid-xml.keyx` (XML 1.0 with invalid key data) are copies too.

These key files are owned by this package and exist only here:

| File | Exercises |
| --- | --- |
| `test-hex.key` | 64 hex characters encoding 0x00...0x1f |
| `test-v1.key` | XML 1.0, Base64 key 0x00...0x1f |
| `test-v2.keyx` | XML 2.0, hex key 0x00...0x1f with its `Hash` attribute |
| `test-arbitrary.key` | Text that is no key format: the SHA-256 fallback |
