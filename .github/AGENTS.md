# GitHub CI And Templates

**Scope:** GitHub Actions workflows, branch rulesets, issue/PR templates, `CODEOWNERS`, funding config, and repo assets. Actions is one leg of CI; Xcode Cloud and local release gates cover the rest.

## What gates what

| When | Where | What runs |
| --- | --- | --- |
| Every pull request, any base branch | `workflows/pr-tests.yml` | Jobs `unit-tests` (`KeeForgeTests`, iOS simulator) and `macos-unit-tests` (`KeeForgeMacTests`). Both are required status checks. No UI tests. |
| `rc/*` tag push | `workflows/ios18-rc-tests.yml` | Full unit and UI suites on an iPhone SE (3rd generation) at the newest iOS 18.x runtime on the runner, then the two regular-width UI classes on an iPad. |
| `rc/*` tag push | `workflows/macos-rc-tests.yml` | Full `KeeForgeMacTests`. |
| `rc/*` tag push | Xcode Cloud **Tests (RC)** | `KeeForgeCloudUnitTests`, `KeeForgeCloudUIA`, `KeeForgeCloudUIB` on the latest runtime, plus the iOS and Mac App Store archives. |
| `rc/*` tag push | `workflows/ios-rc-tests.yml` | The same three Cloud test schemes on GitHub's `xcode-27` runner: iPhone 18 Pro and iPhone SE (3rd generation) at the newest iOS runtime, six jobs. No archives. |
| Each release candidate, locally | `ci_scripts/run_kdbx_compatibility_gate.sh` | KeePassXC cross-validation, once per platform. |
| Each release candidate, locally | `KeeForgeMacUITests/MacSmokeUITests` | Mac UI smoke. |
| Manual only | `workflows/ci.yml`, `workflows/ios18-ui-regression.yml` | Diagnostics, not gates. |

- **Nothing triggers on `v*`.** That tag records which soaked build shipped; the App Store build is selected from TestFlight, never re-archived.
- **`KeeForgeMacUITests` never runs in CI.** It drives real windows and needs an unlocked, active login session that no runner has (`../KeeForgeMacUITests/AGENTS.md`). Behavior covered only by a Mac UI test is uncovered in CI.
- **No CI runs the KDBX gate.** It needs `keepassxc-cli`, which neither GitHub runners nor Xcode Cloud install. See `../ci_scripts/AGENTS.md`.
- **UI tests are release-gated, not PR-gated.** They first run on the `rc/*` tag.
- The iPad lane in `ios18-rc-tests.yml` is the only CI place `DatabaseCreationRegularWidthUITests` and `RegularWidthWorkspaceUITests` execute; they `XCTSkip` on every compact-width device.
- `ios18-rc-tests.yml` exists because Xcode Cloud has no iOS 18.x runtime to pin. It is the minimum-OS gate.
- External TestFlight distribution is a manual App Store Connect step after every gate is accepted; no post-action distributes. See `../.agents/skills/prepare-release/references/xcode-cloud-setup.md`.
- The separate Xcode Cloud **Contributor Testing** workflow produces internal-only TestFlight builds for contributor hardware testing. It runs no tests and is not release evidence (`../ci_scripts/contributor-testing.md`).

## Verdict rule

`pr-tests.yml`, the three RC workflows, and `ios18-ui-regression.yml` judge on `ci_scripts/validate_xcresult_summary.py`, not the `xcodebuild` exit code: the fresh `.xcresult` summary must report `result=Passed`, zero failures, and at least one executed test. Exit 65 is tolerated only after that check, because runners return it intermittently during teardown; any other nonzero exit fails. `ci.yml` judges on the raw exit code, which is why it is manual only.

## Branch rulesets

Three repository rulesets, all with admin bypass. They live in GitHub settings, not in this repo. Collaborators with the Write role merge PRs on green checks but cannot push `main`, touch `release/**`, or create tags.

- `main` (`~DEFAULT_BRANCH`): no deletion, no force-push, required `unit-tests` + `macos-unit-tests` + `DCO`, and a PR rule with zero required approvals but required code-owner review. Linear history is deliberately **not** required: release-branch backports land as real merge commits, so "does `main` have every release fix?" is answerable with `git merge-base --is-ancestor`.
- `release branches` (`refs/heads/release/**`): the same status checks, no deletion or force-push, required linear history (nothing is merged *into* a release branch), and restricted creation and updates.
- `tags` (`~ALL`): restricted creation, update, and deletion, so only admins push `rc/*` and `v*`.

`CODEOWNERS` owns `/.github/` and `/ci_scripts/`. A PR therefore cannot rewrite its own required gate or the Xcode Cloud scripts without owner approval. This matters because a skipped required job counts as passing.

## Gotchas

- Renaming the `unit-tests` or `macos-unit-tests` job breaks the rulesets, which match the check by job name.
- Every `KeeForgeMac` job runs on `macos-26` and fails below Xcode 26.4: Xcode 26.3's `actool` crashes compiling `KeeForge.icon` for macOS. The iOS unit-test jobs (`pr-tests.yml`, `ci.yml`) also run on `macos-26`. The iOS 18 workflows (`ios18-rc-tests.yml`, `ios18-ui-regression.yml`) stay on `macos-15`, the only image with iOS 18 simulator runtimes.
- Mac jobs sign ad hoc with entitlements stripped (`CODE_SIGN_IDENTITY=-`, `CODE_SIGN_ENTITLEMENTS=`), because runners have no signing account.
- Workflows regenerate the project with XcodeGen; the checked-in `.xcodeproj` is never assumed current. `ios18-ui-regression.yml` pins Xcode 26.3 and `ios-rc-tests.yml` keeps the image default; the rest select the newest Xcode on the runner.
- Workflows bootstrap `BuildConfig.local.xcconfig` with the placeholder `DROPBOX_APP_KEY=ciplaceholderdropboxappkey`. It must stay alphanumeric and the app treats it as cloud sign-in disabled; the rule is in `../ci_scripts/AGENTS.md`.
- `ios18-rc-tests.yml` takes about two hours on one runner and has a 180-minute timeout. It fails loudly if the runner image drops its iOS 18 runtimes.
- `ios-rc-tests.yml` runs on `xcode-27`, the only image with Xcode 27 and an iOS 27 runtime. It uses the image's default Xcode, because the newest one installed there is a beta. Xcode Cloud's test actions are metered against a monthly compute allowance and are cancelled once it is spent; this workflow is not metered.
- An existing `rc/*` tag cannot gain a workflow file. To run `ios-rc-tests.yml` against one, dispatch it from a branch that has the file and pass the tag as `ref`; the run then reports on the dispatching branch, so read the tested commit from its log.
- This file is named `AGENTS.md` because GitHub renders a `.github/README.md` as the repository front page.
