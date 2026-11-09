# GitHub CI And Templates

**Scope:** GitHub Actions workflows, branch rulesets, issue/PR templates, `CODEOWNERS`, funding config, and repo assets. Actions is one leg of CI; Xcode Cloud and local release gates cover the rest.

## What gates what

| When | Where | What runs |
| --- | --- | --- |
| Every pull request, any base branch | `workflows/tests.yml` | Jobs `unit-tests` (`KeeForgeTests`, iOS simulator) and `macos-unit-tests` (the KDBXKit package suite with its coverage floors, then `KeeForgeMacTests`). Both are required status checks. No UI tests. |
| `rc/*` tag push | `workflows/tests.yml` | `macos-unit-tests` (full `KeeForgeMacTests`), plus `ios-rc-tests` (a call to `workflows/ios-rc-tests.yml`): the three Cloud test schemes on GitHub's `xcode-27` runner on iPhone 18 Pro and iPhone SE (3rd generation) at the newest usable iOS runtime, and the two regular-width UI classes on an iPad (A16). Seven jobs. No archives. `macos-unit-tests` and the iPad job are release gates (`githubMac`, `githubIPad` in the candidate manifest); the iPhone jobs are not. |
| `rc/*` tag push | Xcode Cloud **Tests (RC)** | `KeeForgeCloudUnitTests`, `KeeForgeCloudUIA`, `KeeForgeCloudUIB` on the latest runtime, plus the iOS and Mac App Store archives. |
| Manual dispatch | `workflows/tests.yml` | The `rc/*` set against the `ref` input. |
| Weekly (Monday) and manual dispatch | `workflows/ci-drift.yml` | Not a gate. Checks `tests.yml` and `ios-rc-tests.yml` against the newest stable `macos-N` image, the newest `xcode-N` image, their stable Xcodes, and whether their iOS runtimes can create the test devices. Fails with the report in the run summary on drift. |
| Weekly | Dependabot (`dependabot.yml`) | Not a gate. One grouped PR bumping every `uses:` action to its latest release. |
| Each release candidate, locally | `ci_scripts/run_kdbx_compatibility_gate.sh` | KeePassXC cross-validation, once per platform. |
| Each release candidate, locally | `KeeForgeMacUITests/MacSmokeUITests` | Mac UI smoke. |

- **Nothing triggers on `v*`.** That tag records which soaked build shipped; the App Store build is selected from TestFlight, never re-archived.
- **`KeeForgeMacUITests` never runs in CI.** It drives real windows and needs an unlocked, active login session that no runner has (`../KeeForgeMacUITests/AGENTS.md`). Behavior covered only by a Mac UI test is uncovered in CI.
- **No CI runs the KDBX gate.** It needs `keepassxc-cli`, which neither GitHub runners nor Xcode Cloud install. See `../ci_scripts/AGENTS.md`.
- **UI tests are release-gated, not PR-gated.** They first run on the `rc/*` tag.
- The iPad lane in `ios-rc-tests` is the only CI place `DatabaseCreationRegularWidthUITests` and `RegularWidthWorkspaceUITests` execute; they `XCTSkip` on every compact-width device.
- No CI lane runs an iOS 18 runtime. iOS 18 stays the deployment target, but minimum-OS behavior is not test-gated.
- External TestFlight distribution is a manual App Store Connect step after every gate is accepted; no post-action distributes. See `../.agents/skills/prepare-release/references/xcode-cloud-setup.md`.
- The separate Xcode Cloud **Contributor Testing** workflow produces internal-only TestFlight builds for contributor hardware testing. It runs no tests and is not release evidence (`../ci_scripts/contributor-testing.md`).

## Verdict rule

Every `tests.yml` Xcode run judges on `ci_scripts/validate_xcresult_summary.py`, not the `xcodebuild` exit code (the KDBXKit step, a plain `swift test`, judges on its exit status): the fresh `.xcresult` summary must report `result=Passed`, zero failures, and at least one executed test. Exit 65 is tolerated only after that check, because runners return it intermittently during teardown; any other nonzero exit fails.

## Branch rulesets

Three repository rulesets, all with admin bypass. They live in GitHub settings, not in this repo. Collaborators with the Write role merge PRs on green checks but cannot push `main`, touch `release/**`, or create tags.

- `main` (`~DEFAULT_BRANCH`): no deletion, no force-push, required `unit-tests` + `macos-unit-tests` + `DCO`, and a PR rule with zero required approvals but required code-owner review. Linear history is deliberately **not** required: release-branch backports land as real merge commits, so "does `main` have every release fix?" is answerable with `git merge-base --is-ancestor`.
- `release branches` (`refs/heads/release/**`): the same status checks, no deletion or force-push, required linear history (nothing is merged *into* a release branch), and restricted creation and updates.
- `tags` (`~ALL`): restricted creation, update, and deletion, so only admins push `rc/*` and `v*`.

`CODEOWNERS` owns `/.github/` and `/ci_scripts/`. A PR therefore cannot rewrite its own required gate or the Xcode Cloud scripts without owner approval. This matters because a skipped required job counts as passing.

## Gotchas

- Renaming the `unit-tests` or `macos-unit-tests` job breaks the rulesets, which match the check by job name.
- Every `KeeForgeMac` job runs on `macos-26` and fails below Xcode 26.4: Xcode 26.3's `actool` crashes compiling `KeeForge.icon` for macOS. The PR `unit-tests` job also runs on `macos-26`.
- Mac jobs sign ad hoc with entitlements stripped (`CODE_SIGN_IDENTITY=-`, `CODE_SIGN_ENTITLEMENTS=`), because runners have no signing account.
- `ios-rc-tests` is a reusable workflow that `tests.yml` calls, not an inline matrix job: a skipped matrix job shows its raw `${{ matrix.* }}` name on every pull request. Its jobs therefore report as `ios-rc-tests / <scheme> (<device>)`, for example `ios-rc-tests / KeeForge (iPad (A16))`, and still belong to the `tests.yml` run.
- Workflows regenerate the project with XcodeGen; the checked-in `.xcodeproj` is never assumed current. `ios-rc-tests` keeps the image default; the other jobs select the newest Xcode on the runner.
- Workflows bootstrap `BuildConfig.local.xcconfig` with the placeholder `DROPBOX_APP_KEY=ciplaceholderdropboxappkey`. It must stay alphanumeric and the app treats it as cloud sign-in disabled; the rule is in `../ci_scripts/AGENTS.md`.
- `ios-rc-tests` runs on `xcode-27`, the only image with Xcode 27 and an iOS 27 runtime. It uses the image's default Xcode, because the newest one installed there is a beta. Xcode Cloud's test actions are metered against a monthly compute allowance and are cancelled once it is spent; this lane is not metered. Its simulator step takes the newest runtime that supports and can create each device: the image can carry a runtime newer than its default Xcode drives, which `simctl create` rejects with `Incompatible device`.
- An existing `rc/*` tag cannot gain a workflow file. To rerun a candidate, dispatch `tests.yml` from a branch that has it and pass the tag as `ref`; the run then reports on the dispatching branch, so read the tested commit from its log.
- `ci-drift.yml` reads image labels from the `actions/runner-images` README table and reproduces `tests.yml`'s Xcode choices in `scripts/ci_drift.py`. When a lane changes how it picks its runner, Xcode, or devices, change the script with it. A pre-release Xcode is one whose app name says beta or release candidate.
- Dependabot PRs pass DCO because the DCO app exempts bot authors; they still need code-owner review for `.github/`.
- This file is named `AGENTS.md` because GitHub renders a `.github/README.md` as the repository front page.
