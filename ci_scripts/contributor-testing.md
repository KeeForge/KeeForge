# Signed contributor builds

Trusted collaborators can request signed iOS and native macOS builds through the
Xcode Cloud **Contributor Testing** workflow. It archives `KeeForge` and
`KeeForgeMac` with **TestFlight (Internal Testing Only)** and distributes both to
the private **KeeForge Contributors** internal group. These builds cannot be
submitted to external testers or the App Store.

## Request a build

The configured Git trigger accepts branches beginning with `contributor/miquno/`
in `KeeForge/KeeForge`. From the revision to test, push a new remote branch:

```bash
# Use the remote that points to KeeForge/KeeForge, not your fork.
git remote -v
test_sha=$(git rev-parse --short=12 HEAD)
git push upstream HEAD:refs/heads/contributor/miquno/test-$test_sha
```

Replace `upstream` with the appropriate remote name. This does not change your
local branch. Pushing another revision to a matching branch also starts a build;
a newer push to the same branch cancels its older running or queued build.
Pushing an unchanged ref does not request another build.

Alternatively, in App Store Connect, open Xcode Cloud → KeeForge → Workflows →
**Contributor Testing** → **Start Build**, select the desired branch, and start.
Clear **Mine** if a branch is missing. The workflow allows manual starts from any
branch in the connected repository. Manual control availability must be checked
with the collaborator's own account; the Git trigger does not depend on it.

## Install and report results

Use the Apple Account invited to the internal group in TestFlight on the iPhone,
iPad, or Mac. Install the native macOS build on the Mac, rather than the iOS app
running on Apple silicon. Wait for both the archive and the platform's internal
testing post-action to succeed before expecting the build in TestFlight.

Record the source SHA, platform, TestFlight build number, OS, and relevant hardware
with the test result. Xcode Cloud assigns TestFlight build numbers; do not bump
`project.yml`, create RC tags, or start a release just to request a contributor
build. These archives reuse the app's existing identifiers and storage, so test
with disposable database copies and keep backups of any existing test data.

For the Touch ID / Apple Watch unlock change in #154, check both mechanisms
against the same saved unlock item, a Watch-only setup with no enrolled
fingerprints, unavailable mechanisms, changes to fingerprint/Watch enrollment,
and AutoFill remaining Touch ID-only without a Watch prompt or login-password
fallback. A successful archive does not validate these hardware behaviors.

## Maintainer configuration

- Workflow ID: `2f9d2871-0a4f-4a24-806d-2de974e111df`.
- Internal group ID: `9d38b792-1531-4b07-a73a-bf4504622ce3`.
- Restrict Editing is enabled. Collaborators keep the Developer role scoped to
  KeeForge; they do not receive signing private keys, Admin access, or API keys.
- The two internal TestFlight post-actions explicitly target KeeForge
  Contributors. The group's general automatic-distribution option is off.
- The workflow uses clean builds, Latest Release Xcode/macOS, and the existing
  redacted `DROPBOX_APP_KEY` and `ONEDRIVE_CLIENT_ID` values needed by archive
  validation. Do not add signing keys or unrelated credentials to its environment.
- It runs two archives, with no test actions. PR checks remain the normal code
  gate; this workflow provides binaries for hardware testing, not release evidence.
- The prefix is a trigger filter, not a Git permission boundary. Any repository
  writer who can push that prefix can request builds. Build scripts in the chosen
  revision execute in the workflow environment; only trusted contributors should
  have this access.
- The first setup run is Xcode Cloud build 61, source
  `7810d1bb4199d6f492866aa32c87b8cbedcaf64f`, which includes merged PR #154.

The **Tests (RC)** workflow, RC tags, external tester groups, and release gates
remain separate. This workflow produces the Mac App Store variant for TestFlight;
it does not exercise the Developer ID/Sparkle direct-download channel.
