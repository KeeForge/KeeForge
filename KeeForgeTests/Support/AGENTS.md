# Test Support

**Scope:** fixtures, fakes, spies, and assertion helpers shared by the suites in `../`. Nothing here declares a test class. Put new shared infrastructure here rather than beside a suite; suite-level rules are in [../AGENTS.md](../AGENTS.md).

## Invariants

### Fixtures

- Every bundled database a unit test opens is described once as a named `KDBXTestFixture` in `KDBXTreeAssertions.swift`, and the descriptor is the only way to open it (`url`, `data`, `keyFileData`, `compositeKey`, `parse`). No inline `KDBXTestFixture(...)` literal, `Bundle.url(forResource:)` lookup, or per-suite loader: suites drift apart and lose coverage.
- `TestDatabaseSupport.fixtureData` is for non-database resources (key files) only.
- `SSHAgentTestKeys.swift` (`#if os(macOS)`) holds throwaway OpenSSH private keys and reference RSA signatures generated with Python's `cryptography`, independent of KeeForge's parser. They protect nothing.
- A compatibility `Fixture.id` is an artifact ID used by the gate's manifests and the expectation allow-lists, independent of the file it reads (`aes-baseline` reads `test.kdbx`). Keep the ID stable when retargeting a fixture's source.

### Assertions

- "Did this field survive a save" checks go in the shared comparators (`assertTreesEqual` and friends in `KDBXTreeAssertions.swift`) so the XML, container, and saver suites gain them together. Do not add a per-suite copy.
- Compare a file URL a bookmark or store resolved with `XCTAssertEqualFilePaths`, never `.path` equality. A resolved bookmark reports `/private/var/...` and the temporary directory `/var`; a raw comparison passes sandboxed and fails on the unsandboxed build CI signs.

### Process-wide state

- A suite that installs `CredentialIdentityStoreManager.storeProviderOverride` or an observer calls `resetCredentialIdentityStoreState()` in `setUp` and `tearDown`. It drains pending mutations before and after clearing the seams; a leaked fire-and-forget task otherwise lands in the next test.
- The manager's operations are fire-and-forget tasks. For a positive assertion await an expectation fulfilled from `FakeCredentialIdentityStore.onMutation`; for a negative one install an `XCTFail` hook and await `CredentialIdentityStoreManager.waitForPendingMutations()`.

### Seams

- `KDFPolicyTestSupport.swift` gives parser, writer, and saver calls a `.mainApp` KDF policy when `kdfPolicy:` is omitted. A test about policy selection passes the policy explicitly.
- Drive reveal/copy authentication through `SecretAccessGateHarness` (pass `harness.gate` as the `secretAccess:` argument of `DatabaseViewModel.init`). Assigning `gracePeriod` announces the change to live gates as Settings does; set `announcesSettingChanges = false` to model a bare write.
- `YubiKeyEmulator.fixtureSecret` must match `HMAC_SECRET` in `../../TestFixtures/generators/challenge_response.py`.
- `FakeFTPServer` sits behind `FTPClient`'s connector seam and runs the real command, reply, and data-connection logic. Script failures through its hooks rather than stubbing the client.

## See also

- [../AGENTS.md](../AGENTS.md): layering, the compatibility matrix, platform rules
- [../../TestFixtures/README.md](../../TestFixtures/README.md): bundled databases, passwords, key files
