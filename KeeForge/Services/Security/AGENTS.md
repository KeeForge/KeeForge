# Security Services

**Scope:** device-security integrations and secret-handling helpers outside the core models: Keychain, LocalAuthentication, the reveal/copy gate, passkey crypto, YubiKey challenge-response, screen privacy. Cross-service rules are in `../AGENTS.md`.

## Ownership

- `KeychainService`: one quick-unlock item per database, shared with the AutoFill extension, plus the express-unlock item beside it.
- `QuickUnlockKeychain`: how the app and both AutoFill extensions read, write, and replace those two items. Neither side touches the express item through `KeychainService` directly.
- `BiometricService`: every LocalAuthentication prompt. It also owns `isBiometricAuthInProgress`, which `../AppSupport/MacLockMonitor` reads.
- `SecretAccessGate`: the device-owner gate and grace period in front of revealing or copying a protected value, one per database session (`DatabaseViewModel.secretAccess`). App targets only; AutoFill authenticates on its own and has no grace period.
- `ScreenProtectionService`: both platforms' screen privacy behind `#if os(iOS)` / `#else`. The Mac design and its limits are in `../../../KeeForgeMac/SECURITY.md`.

## Invariants

### Keychain

- `com.keevault.sharedkeychain` must stay FIRST in every target's `keychain-access-groups` (`KeeForge.entitlements`, `KeeForgeMac.entitlements`, `KeeForgeMacDirect.entitlements`, `AutoFillExtension.entitlements`, `AutoFillExtensionMac.entitlements`). `KeychainService` sets no `kSecAttrAccessGroup`, so its items land in the first listed group.
- Reordering strands every stored quick-unlock key: the app and extension stop seeing each other's items. Today only the iOS app lists a second group (`com.microsoft.adalcache`, for MSAL); the rule holds for the single-group targets the moment a group is added.
- Item naming is a compatibility boundary: service `com.keevault.app`, account `compositeKey:<database UUID>`, plus the legacy `compositeKey:<filename>` account that older installs still hold.
- The express-unlock item (`expressUnlockKey:<database UUID>`) holds one file version's KDF output, from the last unlock (app or AutoFill) or app save of that database, and gets exactly the quick-unlock item's protection through the same `storeItem`. Storing or deleting the quick-unlock item by database ID deletes it first, so every key change (password unlock, rekey, AutoFill, hardware-key toggle, removal) drops it. A save writes it only beside a quick-unlock item holding the session's composite key, so it never opens a version that item could not. It is read only with the context that released the quick-unlock item and never prompts on its own; a failed read only costs the KDF. A hardware-key database never has one: it would open the vault without the YubiKey.
- The item is `WhenUnlockedThisDeviceOnly` with `quickUnlockAccessControlFlags`: `.biometryCurrentSet` on iPhone and iPad, `[.biometryCurrentSet, .or, .companion]` (Touch ID or an authorized Apple Watch) on the Mac. No flag admits the passcode or Mac login password. Keep it in step with `BiometricService.quickUnlockPolicy`.
- On the Mac a read uses a non-interactive context, so the caller's evaluated policy is the only prompt. Without that, the Keychain could raise a Watch prompt inside biometric-only AutoFill.
- For a database with `DatabaseReference.hardwareKey`, the stored item is the pre-key (`KDBXCrypto.preKey`), never the composite key, so quick unlock still needs the YubiKey and no response is persisted. `DatabaseListStore.setHardwareKey` deletes the item whenever a hardware key is added or removed, because its meaning changes.
- `shouldStoreQuickUnlockKey` gates writes on `BiometricService.isQuickUnlockAvailable`. On the Mac it also rewrites an existing item while neither mechanism is available, since the master key may have changed on another device.
- Cloud credentials are not stored here. `../Cloud/CloudTokenStore` has its own items with a different protection class (`../Cloud/AGENTS.md`).

### Authentication

- Every reveal or copy of a protected value asks its session's `SecretAccessGate`, never `BiometricService` directly. A prompt raised around the gate neither honors the grace period nor ends it on failure.
- The grant is in memory only, on `ContinuousClock`, and never outlives the shortest period selected since it was earned. A tighter setting shortens it for good and Always Ask revokes it; lengthening needs a new authentication, so an unlocked app in someone else's hands cannot extend it.
- Whoever writes `SettingsService.authenticationGracePeriod` calls `SecretAccessGate.gracePeriodSettingDidChange()` afterwards. Each gate also tightens when asked, which covers a write that skipped the call.
- An invalidation that lands while a prompt is up makes `authenticate(reason:)` throw `CancellationError`: the late answer grants neither the disclosure nor a grace period. When the session invalidates is in `../../ViewModels/AGENTS.md`.
- The app's quick-unlock action evaluates `quickUnlockPolicy` (biometrics, or biometrics-or-companion on the Mac). AutoFill always passes the biometric-only default, so its prompt never offers Apple Watch.
- Reveal/copy gating uses `canAuthenticateDeviceOwner`, not `isAvailable`: a device without biometrics still prompts for the passcode or login password instead of skipping authentication.
- `isBiometricAuthInProgress` is raised before the system prompt appears and by some callers around their own work. It does not mean a prompt is on screen; consumers must not treat it as one.

### Hardware key and passkeys

- `HardwareKeyService` works only in the iOS app: YubiKit is linked into `KeeForge` alone, the file is not on the AutoFill allow-lists, and elsewhere a request throws `unavailable`.
- NFC is the only transport. YubiKit requires the accessory delegate callbacks, which do nothing here; do not wire them to challenge-response or restore the accessory protocol declaration.
- A cancelled request never returns a response: cancellation stops NFC and the request re-checks cancellation after resuming.
- NFC needs the `com.apple.developer.nfc.readersession.formats` entitlement (`KeeForge.entitlements`) plus the YubiKey OTP AIDs and `NFCReaderUsageDescription` in `../../Info.plist`.
- `PasskeyCrypto.aaguid` (`FF55D8C0-F4FB-4016-9FDD-56DBBD251802`) identifies KeeForge to relying parties and never changes. Registration is ES256 only, with "none" attestation.

### Screen privacy

- macOS capture blocking goes through one choke point (`ScreenProtectionService.windowSharingType(blockCapture:)`). A window the key-window sweep cannot reach, such as the quick-search panel, must apply that value itself.
- The Mac blur cover on resign-active is unconditional and skips only the secret-free Settings window (`shouldPrivacyCover(windowIdentifier:)`). Capture blocking is best-effort; do not describe it as a guarantee.

## Tests

- `KeychainServiceTests` (express item lifetime and protection too), `KeychainMigrationTests`; `DatabaseViewModelExpressUnlockTests` for what an app unlock or save reads and stores, `CredentialProviderCoordinatorTests` for AutoFill's; `SecretAccessGateTests` with `EntrySecretActionTests` for the gate's callers.
- `HardwareKeyUnlockTests` covers the unlock flow around `HardwareKeyService`; the NFC session itself has no unit coverage.
- `PasskeyCryptoTests` (in `PasskeyTests.swift`) and `CredentialProviderRegistrationTests` for `PasskeyCrypto`.
- Mac window covering is checked by hand (`../../../KeeForgeMac/SECURITY.md`); only the policy functions are unit-tested, in `SettingsServiceTests`.

## See also

- `../AGENTS.md`, `../Cloud/AGENTS.md`, `../AppSupport/AGENTS.md`
- `../../ViewModels/AGENTS.md`: lock, unlock, and `secretAccess` lifetime
- `../../../AutoFillExtension/AGENTS.md`: the extension's own unlock rules
- `../../../KeeForgeMac/SECURITY.md`, `../../../docs/threat-model.md`
