# Test Fixtures

Sample databases and key files used by unit tests, UI tests, the KDBX compatibility gate, and screenshot flows. Generator scripts and tests cite this file as the inventory; each generator module under `generators/` documents how and why its fixture is built.

## Databases

| File | Password | Format | Generator |
| --- | --- | --- | --- |
| `test.kdbx` | `testpassword123` | KDBX 4, AES-256 | none |
| `demo.kdbx` | `demo` | KDBX 4 | none |
| `demo-keyfile.kdbx` | `demo` + `demo-keyfile.key` | KDBX 4 | none |
| `autofill-union.kdbx` | `testpassword123` | KDBX 4.0, AES-256 | none |
| `autofill-store-alpha.kdbx`, `autofill-store-bravo.kdbx` | `testpassword123` | KDBX 4 | `autofill_store.py` |
| `kitchen-sink.kdbx` | `testpassword123` | KDBX 4.1, AES-256-CBC, Argon2d | `kitchen_sink.py` |
| `challenge-response.kdbx` | `challenge-response` + YubiKey response | KDBX 4.0, AES-256-CBC, Argon2d (2 iterations, 1 MiB) | `challenge_response.py` |
| `challenge-response-aeskdf.kdbx` | `challenge-response` + YubiKey response | KDBX 4, AES-KDF (1000 rounds) | `challenge_response.py` |
| `compatibility/legacy-kdbx31.kdbx` | `testpassword123` | KDBX 3.1 | none |
| `compatibility/foreign-chacha20.kdbx` | `foreign-chacha20` | KDBX 4, ChaCha20 | `foreign_ciphers.py` |
| `compatibility/foreign-twofish.kdbx` | `foreign-twofish` | KDBX 4, Twofish | `foreign_ciphers.py` |
| `compatibility/unknown-inner-header.kdbx` | `unknown-inner-header` | KDBX 4, AES-256-CBC, Argon2d | `unknown_inner_header.py` |
| `compatibility/argon2-high-iterations.kdbx` | `argon2-high-iterations` | KDBX 4, AES-256-CBC, Argon2d (1500 iterations, 1 MiB, parallelism 1) | `argon2_high_iterations.py` |

### `test.kdbx`

Default fixture for most tests and the stable source for common entries. Also backs the `aes-baseline` compatibility ID.

- The root holds only groups, so a flow enters a subgroup before opening an entry.
- `Social`: `Twitter` (password `twitterpass123`), `Discord`, `Offline Key`, `Public Profile`.
- `Work`: `Email`, `GitHub`, and the nested group `Internal` with one entry.
- `Empty`: no entries.
- It has no passkeys and no key file.

### `demo.kdbx` and `demo-keyfile.kdbx`

- `demo.kdbx` is the richer demo database used by `KeeForgeUITests/AppStoreScreenshots.swift`.
- `demo-keyfile.kdbx` needs password `demo` plus `demo-keyfile.key`. The UI tests, `KeeForgeTests/KDBXWriterTests.swift`, and `KeeForgeTests/KDBXRoundTripTests.swift` hardcode those credentials. It backs the `password-keyfile` compatibility ID; its entry `KeyFile Test Entry` has password `keyfilepass123`.

### `autofill-union.kdbx`

One `Union` group with three entries, publishing exactly 3 password and 1 one-time-code AutoFill identities:

| Entry | Domain | Notes |
| --- | --- | --- |
| `Union Bank` | `unionbank-fixture.net` | |
| `Union News` | `union-news-fixture.org` | TOTP through the KeePassXC `otp` field |
| `Union Shop` | `union-shop-fixture.io` | |

- Every service domain and username is disjoint from `test.kdbx`.
- Bundled only into `KeeForgeUITests`, where the TOTP classes use it (`TOTPSmokeUITests`, `TOTPEnrollmentUITests`, `TOTPEnrollmentDeepLinkUITests`).
- Built with `pykeepass` (`create_database`). There is no generator: regenerate by recreating the three entries with the same password.

### `autofill-store-alpha.kdbx` and `autofill-store-bravo.kdbx`

Dedicated fixtures for the physical-device `AutoFillStoreUITests`; bundled only into `KeeForgeUITests`.

| Database | Entry | Username | Domain | Has |
| --- | --- | --- | --- | --- |
| alpha | `Alpha Login` | `alpha-user` | `alpha-store-fixture.net` | password, TOTP |
| bravo | `Bravo Login` | `bravo-user` | `bravo-store-fixture.org` | password, TOTP |
| bravo | `Bravo Password` | `bravo-password-user` | `bravo-password-fixture.com` | password |

- Alpha publishes 2 identities and bravo 3.
- Service domains are disjoint, entry UUIDs are fixed, and nothing expires, so the suite does not depend on the general fixtures. The system credential-identity store can dedup identities that share a (service, user) pair across databases, which is why the two must not overlap.

### `kitchen-sink.kdbx`

The rich union fixture, built with `pykeepass`, an independent implementation. It is the only bundled database with entry tags, group `<Tags>`, a `Meta/CustomIcons` image, a binary pool, a protected custom field, or a `PublicCustomData` outer-header field.

The outer header carries `PublicCustomData` (id `0x0C`), a variant dictionary holding `KeeForgeFixture` = `KDBX 4.1 public custom data`. KeeForge does not model it and a save must re-emit it byte for byte.

Ten root groups, in this child order:

| Group | Entries (`username` / `password`) | What it carries |
| --- | --- | --- |
| `Tagged` | `Router Admin` (`tag-router-user` / `TagRouterSecret1`; tags `shared`, `Work`, `Personal Notes`), `Mail Account` (`tag-mail-user` / `TagMailSecret2`; tags `shared`, `work`), `Untagged Entry` (no tags) | A tag count above one, the `Work`/`work` case-variant pair, and a tag with a space (identifier suffix `tag-list.row.personal-notes`) |
| `Archive` | `Old Backup` (`tag-archive-user` / `TagArchiveSecret4`; tag `archive`) | The "1 entry" plural branch |
| `Secrets` | `Protected Custom` (`fixture-user` / `fixture-password`), `TOTP Login` (`totp-user` / `TotpSecret1`) | See below |
| `Icons` | `Custom Badge` (`icon-custom-user` / `IconCustomSecret1`, URL `https://icons-fixture.example.com`), `Plain Entry` (`icon-plain-user` / `IconPlainSecret2`) | See below |
| `Projects` | `Alpha Login` (`alpha-user` / `GroupTagAlpha1`, URL `https://alpha.example.com`) | Group tags `team;shared` plus a group `<Notes>` |
| `Projects/Client Work` | `Beta Login` (`beta-user` / `GroupTagBeta2`, URL `https://beta.example.com`, entry tag `own-tag`) | Nested group with tag `billable`: parent tag, subgroup tag, and own tag accumulate |
| `Empty Tags Group` | `Gamma Login` (`gamma-user` / `GroupTagGamma3`) | An empty `<Tags/>` element, the state `hasTagsElement` preserves |
| `Plain Group` | `Delta Login` (`delta-user` / `GroupTagDelta4`) | No `<Tags>` element at all; KeeForge must never add one |
| `Attachments` | `Multi Attachment Entry` (`multi-user` / `entry-password-1`), `Dedup Entry A` (`entry-password-2`), `Dedup Entry B` (`entry-password-3`), `No Attachment Entry` (`plain-user` / `entry-password-4`) | See below |
| `Round Trip` | `Controlled Unknowns` (`roundtrip-user` / `roundtrip-pass`, URL `https://example.com/round-trip`) | See below |
| `Recycle Bin` | `Trashed Login` (`trashed-user` / `GroupTagTrashed5`) | A real bin with `Meta/RecycleBinUUID` set, so soft-delete edits must reuse it. The bin has no tags |

Details the table does not hold:

- `Secrets`: `Protected Custom`'s current version and its single stored history version both carry `API Token = custom-secret` with `Protected="True"`. `TOTP Login` has a protected `otp` field holding an `otpauth://` URI (secret `JBSWY3DPEHPK3PXP`, 30 s, 6 digits).
- `Icons`: `Custom Badge` displays the fixture's single custom icon, UUID `4D9C2B1E-7A35-4E68-9B0D-52F16C8A3E77`, a deterministic 8x8 PNG. The UUID is hardcoded in the UI test's `entry-icon-picker.custom.<uuid>` identifier; change both together. `Plain Entry` uses a standard icon, has no stored `<History>`, and has no URL, so it carries the icon-change-pushes-history and disabled "Download Website Icon" cases.
- `Projects`: pykeepass writes the `;` join, which exercises the semicolon split. The group `<Notes>` ("Group notes ride along as unknown XML next to the structured Tags element.") exercises unknown-sibling positioning next to `<Tags>`.
- `Attachments`: `Multi Attachment Entry` has `note-ü.txt` (non-ASCII filename) and `pixel.png` (binary content). The two dedup entries attach one shared pool binary, `shared.bin`.
- `Round Trip`: the coverage is opaque XML in awkward positions, not the values.
  - Its `<CustomData>` (`RoundTripEntryKey` = `RoundTripEntryValue-Expected`) sits between `<Binary>` and `<History>`.
  - Its `<Password>` and `<Notes>` sit after `<History>`, a legal but non-canonical child order.
  - Its `<AutoType>` carries a `DefaultSequence` and a `RoundTrip Login` association.
  - The attachment `round-trip.txt` is referenced by the current entry and by its single history version (password `history-pass-v1`, notes `Historical revision for round-trip coverage`, no `<CustomData>`), so a history-only `<Binary>` cannot be dropped.
  - `Meta` carries a second `<CustomData>` sibling (`RoundTripMetaKey` = `RoundTripMetaValue-Expected`) next to the one pykeepass writes. It is schema-invalid and the only such construct in the corpus.
- Recycle-bin tag exclusion is unit-tested in memory in `DatabaseViewModelTests`, not through this bin.

Attachment SHA-256 values, also recorded in `KeeForgeTests/Support/KDBXCompatibilitySupport.swift` (`AttachmentFixtureHashes`) and verified with `keepassxc-cli attachment-export`:

| Attachment | SHA-256 |
| --- | --- |
| `note-ü.txt` | `bcc1c6cd101bd5b27356a7004361fd1e1ff74ed2ef416e3252997d328efd3727` |
| `pixel.png` | `3ec322a42990a3067cc6c73f3856a86e55bdd8baf19d2166954a8fb319329a72` |
| `shared.bin` | `fd184a4f05cf3d4f39ab726bda3d3a923da30e9ab2d6697b69c2d39d7ea1ab18` |
| `round-trip.txt` | `22e06efe984efab5605bccf1c0c1e208db740e16cac328dcbfa27cecee8458db` |

Consumers:

- Bundled into every test target, both UI suites included. The UI classes that use it are listed in `../KeeForgeUITests/AGENTS.md`; retargeting or removing it breaks UI tests, not only the compatibility gate.
- Unit tests: `KDBXParserTests.testGroupTagsFixtureParsesGroupTagsThroughFullDecryptPath`, `KDBXRoundTripTests` (`<Times>` order, opaque XML, fixed-point sweeps, `test_unknownNodes_controlledFixture_…`), `SortOrderTests` (recycle-bin pinning), `AttachmentTests`, `DatabaseDraftTests.test_updateEntry_updatesFields_preservesUnknownXML`, `KDBXWriterTests.test_writtenFile_validatesOuterHeaderHMAC`.
- Compatibility gate scenarios, all run by `KDBXCompatibilityTests.test_kitchenSinkFixture_…`: `fixture-smoke-kitchen-sink`, `attachments-update-entry`, `attachments-soft-delete-entry`, `attachments-add-remove`, `group-tags-update-entry`, `group-tags-update-group`.

When changing it:

- A password change means updating `KDBXCompatibilitySupport.fixtureEntryPasswords` / `passwordExpectations`.
- A group name or tag change means updating the `group-tags-*` scenarios, `KDBXParserTests`, and `KDBXCompatibilityTests`.

### `challenge-response.kdbx` and `challenge-response-aeskdf.kdbx`

Databases whose composite key includes a YubiKey HMAC-SHA1 challenge-response, built the way KeePassXC builds it.

- Password `challenge-response`; HMAC secret `KeeForgeYubiKeyTest!`, mirrored by `KeeForgeTests/Support/YubiKeyEmulator.swift`. The password alone does not open either file, and the generator verifies that.
- Composite key: `SHA256(SHA256(password) || SHA256(response))`. The challenge is the KDF salt PKCS#7-padded to 64 bytes; the response is HMAC-SHA1 over the unpadded salt.
- The AES-KDF variant uses the `c9d9f39a…` KDF UUID, which KeePassXC writes for a KDBX 4 AES-KDF database. Its challenge is the AES-KDF seed, padded the same way.
- Both hold one `Hardware Key` group with `YubiKey Entry` (`yubikey-user` / `YubiKeySecret1`).
- Neither is in the external compatibility gate: `keepassxc-cli` would need a real YubiKey.
- `challenge-response.kdbx` drives `ChallengeResponseKeyTests` and `HardwareKeyUnlockTests`; the AES-KDF variant drives `ChallengeResponseKeyTests`.

### `compatibility/`

Fixtures for the KDBX compatibility matrix and the external opener gate.

A compatibility ID is an artifact ID, not a file name. Three IDs read a fixture outside this folder, because only one copy of identical bytes is kept. The mapping lives in `KDBXCompatibilitySupport.Fixture`.

| Compatibility ID | File | Database password | Entry the gate reads back → password |
| --- | --- | --- | --- |
| `aes-baseline` | `test.kdbx` | `testpassword123` | `Social/Twitter` → `twitterpass123` |
| `password-keyfile` | `demo-keyfile.kdbx` + `demo-keyfile.key` | `demo` | `KeyFile Test Entry` → `keyfilepass123` |
| `kitchen-sink` | `kitchen-sink.kdbx` | `testpassword123` | `Attachments/Multi Attachment Entry` → `entry-password-1` |
| `legacy-kdbx31` | `compatibility/legacy-kdbx31.kdbx` | `testpassword123` | none |
| `foreign-chacha20` | `compatibility/foreign-chacha20.kdbx` | `foreign-chacha20` | `Foreign/Foreign Entry Alpha` → `ForeignAlphaSecret1` |
| `foreign-twofish` | `compatibility/foreign-twofish.kdbx` | `foreign-twofish` | `Foreign/Foreign Entry Alpha` → `ForeignAlphaSecret1` |
| `unknown-inner-header` | `compatibility/unknown-inner-header.kdbx` | `unknown-inner-header` | `Unknown Header/Inner Header Entry` → `UnknownHeaderSecret1` |
| `argon2-high-iterations` | `compatibility/argon2-high-iterations.kdbx` | `argon2-high-iterations` | `High Iterations/High Iteration Entry` → `HighIterationSecret1` |

- After KeeForge rewrites a fixture, `run_kdbx_compatibility_gate.sh` asks `keepassxc-cli show -s -a Password` for the entry in the last column, proving a value authored by another implementation survives a KeeForge save. The pairs are mirrored in `KDBXCompatibilitySupport.fixtureEntryPasswords`; change both together.
- The `kitchen-sink` group-tag scenarios also probe `Projects/Alpha Login` → `GroupTagAlpha1`, `Plain Group/Delta Login` → `GroupTagDelta4`, and `Projects/Client Work/Beta Login Updated` → `GroupTagBetaUpdated2` (a value KeeForge wrote). The generator's own `keepassxc-cli` pass also probes `Round Trip/Controlled Unknowns` → `roundtrip-pass`.

`legacy-kdbx31.kdbx`: besides its compatibility ID it is a plain bundled fixture for the legacy-format coverage in `KDBXParserTests`, `KDBXFileSummaryTests`, `LocalDatabaseSaverTests`, `CloudDatabaseSaverTests`, and `DatabaseViewModelTests`, and is bundled into `KeeForgeUITests`.

`foreign-chacha20.kdbx` and `foreign-twofish.kdbx`: pykeepass-authored, so they cover KeeForge's ChaCha20 and Twofish outer-cipher read paths against a database KeeForge did not write. Every other fixture is AES-256-CBC. Both hold identical content and differ only in password and declared outer cipher:

- A root-level `Foreign` group.
- `Foreign Entry Alpha`: `foreign-alpha-user` / `ForeignAlphaSecret1`, custom field `ForeignField` = `ForeignFieldValue`.
- `Foreign Entry Beta`: `foreign-beta-user` / `ForeignBetaSecret2`, no custom field.

`unknown-inner-header.kdbx`: covers preservation of unrecognized KDBX 4 inner-header fields (`../docs/specs/2026-07-26-kdbx-format-hardening/02-unknown-inner-header-preservation.md`).

- One `Unknown Header` group with `Inner Header Entry` (`unknown-header-user` / `UnknownHeaderSecret1`) and two attachments, so the binary pool has two entries to splice between:
  - `alpha-attachment.txt`: `2e1e53db7251ba3852ea965523b8ff3ab8b7426adf50277d0d8d41d40630bdfd`
  - `beta-attachment.txt`: `ee48b95cd61f6f910959979dc94199de8012611f0050e85c5d7cd15e3d95d4b0`
- Three unknown fields are spliced into the on-disk item sequence:
  - id `0x21`, non-empty payload, between the two binary-pool entries. KeeForge's writer normalizes it to before the pool on save, and this fixture lets a test observe that.
  - id `0x7F`, a recognizable non-trivial payload, after the protected-stream ID and key fields.
  - id `0x10`, zero-length payload, after `0x7F`.
- Reopening the final file with pykeepass fails with `MappingError`. That is the expected, verified outcome; KeePassXC skips unrecognized IDs and opens it normally.

`argon2-high-iterations.kdbx`: a high iteration count with low memory (1.5 GiB of total work), the acceptance case for the `KDFExecutionPolicy` work budget. A per-parameter iteration cap would reject it. One `High Iterations` group with `High Iteration Entry` (`high-iteration-user` / `HighIterationSecret1`). The low memory keeps repeated derivations in the matrix and gate cheap.

Changing an entry password in `unknown-inner-header.kdbx` or `argon2-high-iterations.kdbx` means updating `KDBXCompatibilitySupport.fixtureEntryPasswords`.

## Merge Fixtures

`Merge/` holds the oracle fixtures for the KeePass Synchronize merge feature. Each scenario is a directory with a trio of KDBX 4 databases and a recorded expectation dump. All share the password `testpassword123`.

| Path | Content |
| --- | --- |
| `Merge/<scenario-id>/local.kdbx` | The side KeeForge holds in memory (the merge target) |
| `Merge/<scenario-id>/remote.kdbx` | The side that landed on disk or in the cloud (the merge source) |
| `Merge/<scenario-id>/merged-reference.kdbx` | `cp local.kdbx merged-reference.kdbx`, then `keepassxc-cli merge -s merged-reference.kdbx remote.kdbx`. KeePassXC 2.7.12 is the behavioral oracle |
| `Merge/<scenario-id>/expectations.txt` | The merge's change list, the idempotence re-merge output, `keepassxc-cli ls -R` for all three files, and a decoded structural dump (tree, UUIDs, `LastModificationTime`, `LocationChanged`, history items, attachments, `DeletedObjects`) |
| `Merge/manifest.json` | Machine-readable index: password, base-tree UUIDs, per-scenario description, edit order, assertions, and every place the oracle diverges from the algorithm spec |

The base tree is deterministic, so tests can key on UUIDs: root `00000000-0000-4000-8000-000000000000`, groups `Work` / `Personal` / `Archive` (`1111…`, `2222…`, `3333…`), entries `Alpha` / `Beta` / `Gamma` (`aaaa…`, `bbbb…`, `cccc…`). Timestamps are wall-clock values from generation time and change on every regeneration.

Scenarios: `both-add-entries`, `remote-newer-wins`, `local-newer-wins`, `history-union`, `same-timestamp-diverged`, `move-vs-edit`, `move-into-remote-only-group`, `delete-local-then-edit-remote`, `edit-remote-then-delete-local`, `delete-remote-then-edit-local`, `edit-local-then-delete-remote`, `recycle-vs-edit`, `group-rename-vs-entry-add`, `group-deleted-vs-entry-added`, `attachment-divergence`, `identical-no-changes`.

**The reference is not authoritative everywhere.** `keepassxc-cli merge` runs KeePassXC's `Merger` in *KeepNewer* mode (the root group's merge mode falls back to `KeepNewer`, and `Merger::mergeDeletions` returns early for every mode except `Synchronize`), and no CLI flag forces `Synchronize`. Consequences, all recorded per scenario in `manifest.json`:

- **Deletions never propagate.** In the four delete scenarios the reference resurrects the entry regardless of timestamps, and target-side tombstones survive next to the live entry. KeeForge implements the `Synchronize` rule: a tombstone kills an object whose `LastModificationTime` precedes the `DeletionTime`; an object edited afterwards survives and its tombstone is dropped. So the reference and KeeForge deliberately disagree in `edit-remote-then-delete-local` and `edit-local-then-delete-remote`, and on tombstone retention in `delete-local-then-edit-remote`.
- **`Meta/RecycleBinUUID` is never adopted** (an explicit TODO in `Merger::mergeMetadata`), so `recycle-vs-edit`'s reference carries the bin group with an all-zero `RecycleBinUUID`.
- **A merge-moved entry keeps its stale `LocationChanged`.** `Merger` adopts the source value for groups but not for entries. Compare placement, not that timestamp.
- **Sibling order is an artifact.** When the source entry wins a conflict, `Merger` erases the target entry and appends a clone, so the winner ends up last in its group. Compare merged trees order-insensitively.

Everything else (entry conflict resolution, history union, history dedupe by `LastModificationTime`, moves, group renames, idempotence) is mode-independent in KeePassXC and is a faithful oracle.

- Regenerate the set with `scripts/generate-merge-fixtures.sh` (see `../scripts/README.md`); `--scenario <id>` rebuilds one.
- `KeeForgeTests/KDBXMergerOracleTests.swift` consumes them, enumerating scenarios from `manifest.json`.
- They are bundled into `KeeForgeTests` / `KeeForgeMacTests` as a folder reference (`type: folder` in `../project.yml`), because every scenario directory holds the same three file names and a flat resource copy would collide. The bundle keeps the `Merge/<scenario-id>/…` structure, and a new scenario directory needs no project change. The oracle suite fails if a directory and the manifest disagree.

## Key Files

| File | Use |
| --- | --- |
| `test-hex.key`, `test-v1.key`, `test-v2.keyx`, `test-arbitrary.key` | The supported key-file parsing formats. Bundled only into the unit-test targets |
| `demo-keyfile.key` | Paired with `demo-keyfile.kdbx`; also `KeyFileProcessorTests`' 32-byte binary-format sample |
| `invalid-xml.keyx` | Non-base64 XML key data. Bundled into `KeeForgeUITests` so `KeyFileUITests` can verify malformed XML fails visibly during unlock |

## Regenerating fixtures

`TestFixtures/generate_fixtures.py` authors the generated fixtures (`pip3 install --user pykeepass`; it runs from any working directory). Each recipe lives in its own module under `TestFixtures/generators/`; shared plumbing is in `generators/_common.py`.

```bash
python3 TestFixtures/generate_fixtures.py --list          # names and output paths
python3 TestFixtures/generate_fixtures.py --all --check   # verify every generated fixture on disk
python3 TestFixtures/generate_fixtures.py kitchen-sink    # rebuild one, then verify it
```

Registered names: `autofill-store-alpha`, `autofill-store-bravo`, `kitchen-sink`, `argon2-high-iterations`, `challenge-response`, `challenge-response-aeskdf`, `foreign-chacha20`, `foreign-twofish`, `unknown-inner-header`. Several names can be passed in one run, for example `foreign-chacha20 foreign-twofish`.

- `--check` verifies only and never writes. Without it, each selected fixture is rebuilt and then verified with the same assertions.
- `--keepassxc-cli /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli` adds an optional external-reader check: KeePassXC opens the file and lists its group. `kitchen-sink` and `unknown-inner-header` also read back entry passwords and export every attachment for a SHA-256 comparison.
- `--output-dir DIR` builds and verifies in `DIR` instead of the committed locations, to rehearse a regeneration without touching the repo.
- Regenerating always changes the file's bytes: the master seed, encryption IV, and KDF salt are randomized, and pykeepass mints fresh UUIDs and timestamps. Only the decoded content is deterministic, and that is all the tests and the tool's own verification assert.

Fixtures without a generator:

- The `Merge/` set is rebuilt by `scripts/generate-merge-fixtures.sh`.
- `test.kdbx`, `demo.kdbx`, `demo-keyfile.kdbx`, `autofill-union.kdbx`, `compatibility/legacy-kdbx31.kdbx`, and every key file are one-off artifacts described above.

## Notes

- One file per content: no fixture is a byte-identical copy of another. Every bundled database is described once by a `KDBXTestFixture` descriptor in `../KeeForgeTests/Support/KDBXTreeAssertions.swift`. The compatibility harness points at that descriptor (`KDBXCompatibilitySupport.Fixture.Source.bundled(_:)`) instead of keeping a private copy under `compatibility/`, and its fixture IDs stay stable when the file it reads moves.
- A new fixture that tests depend on must be wired into `../project.yml`. Fixtures shared by more than one target live in the `UnitTestFixtures` and `UITestFixtures` `targetTemplates`; a target lists only its own extras (`KeeForgeUITests` does, `KeeForgeMacUITests` does not).
