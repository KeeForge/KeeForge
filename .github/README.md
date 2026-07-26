# GitHub CI And Templates

This folder holds the GitHub Actions workflows, issue/PR templates, funding config, and repo assets. The workflows are one leg of the project's CI story; Xcode Cloud and a local release gate cover the rest.

## Workflows

- `workflows/pr-tests.yml` — the **required PR gate** (job name `unit-tests`; it is a required status check on `main` together with DCO). Runs on every PR to `main` against `iPhone 17 Pro, OS=latest` with `-only-testing:KeeForgeTests`. Success is judged on XCTest's aggregate summary failure count, **not** xcodebuild's raw exit code: GitHub runners intermittently exit 65 ("TEST EXECUTE FAILED") during post-run teardown even on a fully green suite, and a retried-then-passed flake logs a failed attempt line that must not fail the job. Retried-but-passed tests surface as warnings; logs and `.xcresult` bundles upload as artifacts.
- `workflows/ci.yml` — manual `workflow_dispatch` only. This was the old push/PR workflow, demoted because it judges success on xcodebuild's raw exit code, which is too flaky on GitHub runners for push/PR noise. Two jobs: `build-and-test` (iOS, `-only-testing:KeeForgeTests`) and `macos-build-and-test` (scheme `KeeForgeMac`, `-only-testing:KeeForgeMacTests`, ad-hoc signed with no entitlements because CI runners have no signing account).
- `workflows/ios18-rc-tests.yml` — fires on `rc/*` tag pushes (plus manual dispatch); ignores the tag-deletion event emitted when the release skill promotes `rc/*` to `v*`. Creates an iPhone SE (3rd generation) simulator on the newest installed iOS 18.x runtime — compact width, the layout that surfaced the iOS 17 editor-navigation hang this job exists to catch — and runs the full unit + UI suites. This is minimum-OS coverage Xcode Cloud cannot provide: its RC test action can only pin the latest runtime or iOS 16.4, with no iOS 18.x option. Uses the same aggregate-verdict harness as `pr-tests.yml`.

## Division Of Labor

- GitHub Actions: PR unit-test gating (`pr-tests.yml`) and iOS 18 minimum-OS RC coverage (`ios18-rc-tests.yml`).
- Xcode Cloud: RC test runs on the latest runtime plus release build/archive (triggered by `rc/*` and `v*` tags; see `.agents/skills/release/SKILL.md` and `ci_scripts/README.md`).
- `ci_scripts/run_kdbx_compatibility_gate.sh`: the required **local** release gate — no CI runs it, because it needs `keepassxc-cli`, which neither GitHub runners nor Xcode Cloud install.

## Gotchas

- All workflows bootstrap `BuildConfig.local.xcconfig` via `BOOTSTRAP_LOCAL_CONFIG_FROM_ENV=1 ./ci_scripts/prepare_build_config.sh` with the placeholder `DROPBOX_APP_KEY=ciplaceholderdropboxappkey` (alphanumerics only — it lands in a `CFBundleURLScheme`; see `ci_scripts/README.md`). The app treats the placeholder as cloud sign-in disabled.
- Workflows select the newest `Xcode_*.app` on the runner and regenerate the project with XcodeGen; the checked-in `.xcodeproj` is never assumed current.
- Issue templates live in `ISSUE_TEMPLATE/` (bug report, feature request, config), the PR template is `PULL_REQUEST_TEMPLATE.md`, and `assets/` holds the app icon used in repo pages.
