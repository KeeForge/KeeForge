# GitHub CI And Templates

GitHub Actions workflows, issue/PR templates, funding config, and repo assets. Actions is one leg of CI; Xcode Cloud and a local release gate cover the rest.

## Workflows

- `workflows/pr-tests.yml` — required PR gate (job `unit-tests`, a required status check alongside DCO on both `main` and `release/**`; the sibling `macos-unit-tests` job runs on every PR but is **not yet listed** in either ruleset — adding it is a repo-settings change). Runs on every PR regardless of base branch, so stacked PRs (which target the branch below them) get the same gate: `iPhone 17 Pro, OS=latest`, `-only-testing:KeeForgeTests`. Verdict comes from XCTest's aggregate failure count, **not** xcodebuild's exit code — runners intermittently exit 65 (`TEST EXECUTE FAILED` during post-run teardown) on green suites, and retried-then-passed flakes must not fail the job (they surface as warnings). Logs and `.xcresult` bundles upload as artifacts.
- `workflows/ci.yml` — manual `workflow_dispatch` only; demoted from push/PR because it judges on the raw exit code, too flaky on GitHub runners. Jobs: `build-and-test` (iOS, `-only-testing:KeeForgeTests`) and `macos-build-and-test` (scheme `KeeForgeMac`, `-only-testing:KeeForgeMacTests`, ad-hoc signed with no entitlements — runners have no signing account).
- `workflows/pr-tests.yml` job `macos-unit-tests` — the Mac counterpart of the iOS gate: scheme `KeeForgeMac`, `platform=macOS`, `-only-testing:KeeForgeMacTests`, ad-hoc signed with entitlements stripped (runners have no signing account). Added when the Mac app moved from on-hold to shipping; before that the Mac suite ran only on manual dispatch, which is how a red `CredentialProviderShellMacTests` went unnoticed. Same aggregate-verdict harness as the iOS job.
- `workflows/macos-rc-tests.yml` — fires on `rc/*` tag pushes (plus manual dispatch), the Mac counterpart to `ios18-rc-tests.yml`. Runs the full `KeeForgeMacTests` suite. `KeeForgeMacUITests` is deliberately excluded: it drives real windows and needs an unlocked, active login session a headless runner does not have (`KeeForgeMacUITests/README.md`), so it stays a local pre-release step. Minimum-OS caveat: the floor is macOS 14 but runners are macos-15 and Apple ships no macOS 14 image, so a macOS 14 smoke pass stays on the manual checklist.
- `workflows/ios18-rc-tests.yml` — fires on `rc/*` tag pushes (plus manual dispatch); ignores tag-deletion events. One `rc/{version}-b{build}` tag is pushed per candidate build from a `release/{major}.{minor}` branch. Creates an iPhone SE (3rd generation) simulator on the newest installed iOS 18.x runtime (compact width — the layout that surfaced the iOS 17 editor-navigation hang) and runs the full unit + UI suites, then swaps to an iPad (10th generation) simulator for a regular-width lane running `DatabaseCreationRegularWidthUITests` + `RegularWidthWorkspaceUITests` (those classes `XCTSkip` on every compact-width device, so this lane is the only CI place they execute). Minimum-OS coverage Xcode Cloud cannot provide: its RC test action pins only the latest runtime or iOS 16.4. Same aggregate-verdict harness as `pr-tests.yml`.

## Division Of Labor

- GitHub Actions: PR unit-test gating for both platforms (`pr-tests.yml`, all PRs including stacked), iOS 18 minimum-OS RC coverage (`ios18-rc-tests.yml`), and macOS RC coverage (`macos-rc-tests.yml`).
- Xcode Cloud: the **Tests (RC)** workflow on `rc/*` tags — test on the latest runtime and archive to the public TestFlight channel. **Nothing triggers on `v*`**: that tag records which soaked build shipped, and the App Store build is selected from TestFlight rather than re-archived. See `.agents/skills/release/xcode-cloud-setup.md`.
- `ci_scripts/run_kdbx_compatibility_gate.sh`: the required **local** gate, run once per candidate build — no CI runs it; it needs `keepassxc-cli`, which neither GitHub runners nor Xcode Cloud install. It runs per platform: the iOS scheme by default, and `KDBX_COMPAT_SCHEME=KeeForgeMac` for the Mac scheme (which switches the test target to `KeeForgeMacTests` and the destination to `platform=macOS`).

## Branch Rulesets

Two repository rulesets, both with admin bypass:

- `main` (`~DEFAULT_BRANCH`): deletion protection, no force-push, required `unit-tests` + `DCO` status checks (add `macos-unit-tests` here to gate the Mac app too — the job exists and runs, but is not yet required). Linear history is deliberately **not** required — release-branch backports land as real merge commits, which makes "does `main` have every release fix?" answerable with `git merge-base --is-ancestor` instead of patch-id guesswork. Contributor PRs still squash-merge.
- `release branches` (`refs/heads/release/**`): the same rules plus required linear history, since nothing is ever merged *into* a release branch.

## Gotchas

- All workflows bootstrap `BuildConfig.local.xcconfig` via `BOOTSTRAP_LOCAL_CONFIG_FROM_ENV=1 ./ci_scripts/prepare_build_config.sh` with placeholder `DROPBOX_APP_KEY=ciplaceholderdropboxappkey` (alphanumerics only — it lands in a `CFBundleURLScheme`; see `ci_scripts/README.md`). The app treats the placeholder as cloud sign-in disabled.
- Workflows select the newest `Xcode_*.app` on the runner and regenerate the project with XcodeGen; the checked-in `.xcodeproj` is never assumed current.
- Issue templates: `ISSUE_TEMPLATE/` (bug report, feature request, config). PR template: `PULL_REQUEST_TEMPLATE.md`. `assets/` holds the app icon used in repo pages.
