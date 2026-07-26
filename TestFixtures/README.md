# Test Fixtures

This folder contains the sample databases and key files used by unit tests, UI tests, and screenshot flows.

## Main Databases

- `test.kdbx` — default fixture for most tests. Password: `testpassword123`.
- `demo.kdbx` — richer demo fixture used by `KeeForgeUITests/AppStoreScreenshots.swift`. Password: `demo`.
- `demo-keyfile.kdbx` — key-file-protected fixture used for key-file tests. Credentials: password `demo` plus `demo-keyfile.key`, hardcoded by both the UI tests and the unit tests (`KeeForgeTests/KDBXWriterTests.swift`, `KeeForgeTests/KDBXRoundTripTests.swift`).
- `autofill-union.kdbx` — distinct-domain second database for `KeeForgeUITests/AutoFillStoreUITests`' multi-database union scenario. Password: `testpassword123`. One `Union` group with three entries — `Union Bank` (`unionbank-fixture.net`), `Union News` (`union-news-fixture.org`, TOTP via the KeePassXC `otp` field), `Union Shop` (`union-shop-fixture.io`) — publishing exactly 3 password + 1 one-time-code AutoFill identities. Every service domain and username is deliberately disjoint from `test.kdbx`'s: the simulator's credential-identity store dedups identities sharing the same (service, user) pair across databases, so the union scenario needs fixtures that cannot collapse into each other. Generated with `pykeepass` (`create_database` → KDBX 4.0 / AES-256, same rationale as `compatibility/attachments.kdbx` — `keepassxc-cli db-create` only produces KDBX 3.1); regenerate by recreating the three entries above with the same password.
- `round-trip/unknown-elements.kdbx` — controlled KDBX4 round-trip fixture with meta and entry `CustomData`, `AutoType`, `History`, and an attachment reference. Password: `test-round-trip`.
- `test-v3-backup.kdbx` — legacy KDBX 3.1 fixture. Password: `testpassword123`. Bundled into `KeeForgeTests` and `KeeForgeMacTests` and used by `KDBXParserTests` (legacy-format coverage), `KDBXFileSummaryTests`, `LocalDatabaseSaverTests`, `CloudDatabaseSaverTests`, and `DatabaseViewModelTests`.
- `compatibility/` — sanitized fixtures for the KDBX compatibility matrix and external opener gate. Passwords mirror their source fixtures: `aes-baseline.kdbx` uses `testpassword123`, `password-keyfile.kdbx` uses `demo` plus `password-keyfile.key`, `unknown-rich.kdbx` uses `test-round-trip`, `kdbx41-public-custom-data.kdbx` uses `testpassword123`, `legacy-kdbx31.kdbx` uses `testpassword123`, and `attachments.kdbx` uses `testpassword123`.
- `compatibility/attachments.kdbx` — KDBX4 (AES cipher) fixture built with `pykeepass` for attachment coverage. Besides the compatibility gate, it is also bundled into both UI-test targets (`KeeForgeUITests` and `KeeForgeMacUITests`) and driven by `KeeForgeUITests/EntryAttachmentsSmokeUITests.swift`, so retargeting or removing it breaks UI tests, not just the gate. One `Attachments` group with four entries: `Multi Attachment Entry` (two attachments: `note-ü.txt` and `pixel.png`, exercising a non-ASCII filename and binary content), `Dedup Entry A` and `Dedup Entry B` (both attach a file named `shared.bin` with byte-for-byte identical content, for pool-dedup coverage), and `No Attachment Entry` (no attachments). Deterministic content and SHA-256 hashes (also recorded in `KeeForgeTests/KDBXCompatibilitySupport.swift`):
  - `note-ü.txt`: `bcc1c6cd101bd5b27356a7004361fd1e1ff74ed2ef416e3252997d328efd3727`
  - `pixel.png`: `3ec322a42990a3067cc6c73f3856a86e55bdd8baf19d2166954a8fb319329a72`
  - `shared.bin` (identical on both Dedup Entry A and Dedup Entry B): `fd184a4f05cf3d4f39ab726bda3d3a923da30e9ab2d6697b69c2d39d7ea1ab18`
  - Regenerate with `pykeepass` (see `KDBXCompatibilitySupport` / gate history) rather than `keepassxc-cli db-create`, since that CLI's `db-create` only produces KDBX 3.1 databases and exposes no cipher/KDF override flags.

## Key Files

- `test-binary.key`, `test-hex.key`, `test-v1.key`, `test-v2.keyx`, and `test-arbitrary.key` cover the supported key-file parsing formats.
- `demo-keyfile.key` is the end-to-end fixture paired with `demo-keyfile.kdbx`.

## Notes

- `test.kdbx` has groups under the root, so many flows need to enter a subgroup before opening an entry.
- `test.kdbx` is the stable fixture-backed source for common entries like Twitter, GitHub, and Email.
- Compatibility fixtures are intentionally copied into `compatibility/` so future agents can add, remove, or retarget release-gate coverage without changing unrelated unit-test fixture names.
- If you add a new fixture that tests depend on, wire it into the correct target in `../project.yml`. Four targets bundle fixtures: `KeeForgeTests`, `KeeForgeUITests`, `KeeForgeMacTests`, and `KeeForgeMacUITests` (the Mac UI-test target consumes `test.kdbx` and `demo.kdbx` too).
