# Cloud creation recovery acceptance manifest

This manifest defines the directed acceptance for the creation-recovery checkpoint. Source typechecking is not a runtime pass. All runtime items below remain **not run** until the reviewer authorizes the directed Mac and iOS runs; parent PR results do not cover this change.

## Selected suites

Run each whole suite once for both `KeeForgeTests` (iOS simulator) and `KeeForgeMacTests` (macOS), using `-only-testing:<target>/<suite>`:

- `PendingUploadQueueTests`, `PendingUploadDrainerTests`, `PendingUploadRecoveryTests`, `CloudFileCreationCoordinatorTests`.
- `DatabaseCreationServiceTests`, `DatabaseCreationViewModelTests`, `CredentialProviderPickerCreationTests`.
- `DatabaseViewModelTests` (includes cloud conflict-copy tests), `DatabaseListStoreTests`.
- `LocalizationTests`, `KDBXCompatibilityTests`, `CloudDatabaseSaverTests`, `CredentialProviderCoordinatorTests` (including their KDBX 3 read-only cases).

Select each suite only once, including when a case below appears in multiple acceptance groups. Isolate new creation journal fixtures under the redirected test App Group and use controlled provider transports; do not access real accounts or Keychain data. Independent notification and coalescing tests remain enabled.

## Required observations

1. **Success and compatibility.** Ciphertext and intent are durable before dispatch, response receipt precedes registration, new creation yields one usable row, and conflict copy leaves the original and its pending saves unchanged. Exercise existing local/app-only, picker, and KDBX read-only/compatibility suites. The source cases cover paths but no runtime evidence exists yet.
2. **Admission and concurrent attempts.** Inject payload and record publication failures and verify zero provider calls; lose a response and verify one call plus exact retained bytes; race same operation and same destination across owners and processes and verify at most one dispatch. Existing source tests cover lost response, same-operation concurrency and payload failure, but cross-process and record-publication fault evidence is still required.
3. **Confirmed registration and collisions.** Inject cache and registry prepublication and post-rename failures, then explicitly complete using the original UUID, factors, receipt and bytes without another create. Check same-operation replay, removal, unrelated row, colliding cache, and changed epoch/head/factors independently; current source tests cover a registry postpublication failure, retry and completed removal, while the remaining fault/collision matrix is unverified.
4. **Cancellation, corrupt input and UI actions.** Suspend a provider call, dismiss, deliver success and prove the receipt survives without implicit registration; explicitly complete without a second create. Verify prepared retry, attempting export-only, confirmed completion, completed hidden/no resurrection, strict unknown version/read errors, missing/corrupt payload retention, target/account separation, and no scene/drainer network retry. Phase policy and caller source cases are present; actual UI action, scene activation and corrupt-file runtime evidence remain outstanding.
5. **Persisted process restart.** Use the existing isolated production-writer helper pattern with separate processes and the same scratch fixture to prove attempted state does not resend and confirmed state registers only locally. A fresh view model or a fresh owner in the same process is not restart evidence; this test has not yet been authored or run.
6. **Localization and native presentation.** Run `LocalizationTests` for all nine locales and verify normalized catalogs. After runtime authorization, render the recovery states in all locales with `scripts/render-views.sh`, inspect them on iPhone/iPad and check the macOS presentation; screenshots, focus/keyboard and actual device behavior are not established by typechecking.

The supervisor owns final delta review and must authorize the directed 135/120-budget Mac/iOS run before execution. A single integrated final gate follows a frozen reviewed head; investigate a concrete failure and its affected family instead of retrying whole suites.
