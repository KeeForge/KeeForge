# Test Fixtures

This folder contains the sample databases and key files used by unit tests, UI tests, and screenshot flows.

## Main Databases

- `test.kdbx` — default fixture for most tests. Password: `testpassword123`.
- `demo.kdbx` — richer demo fixture used by `KeeForgeUITests/AppStoreScreenshots.swift`. Password: `password`.
- `demo-keyfile.kdbx` — key-file-protected fixture used for key-file tests. Pair it with `demo-keyfile.key`; the current UI tests use password `demo`.
- `round-trip/unknown-elements.kdbx` — controlled KDBX4 round-trip fixture with meta and entry `CustomData`, `AutoType`, `History`, and an attachment reference. Password: `test-round-trip`.
- `test-v3-backup.kdbx` — legacy sample kept in the repo but not currently wired into the active test targets.

## Key Files

- `test-binary.key`, `test-hex.key`, `test-v1.key`, `test-v2.keyx`, and `test-arbitrary.key` cover the supported key-file parsing formats.
- `demo-keyfile.key` is the end-to-end fixture paired with `demo-keyfile.kdbx`.

## Notes

- `test.kdbx` has groups under the root, so many flows need to enter a subgroup before opening an entry.
- `test.kdbx` is the stable fixture-backed source for common entries like Twitter, GitHub, and Email.
- If you add a new fixture that tests depend on, wire it into the correct target in `../project.yml`.
