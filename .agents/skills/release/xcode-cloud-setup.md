# Xcode Cloud Configuration This Workflow Depends On

One-time App Store Connect setup. Read this if archives or TestFlight uploads are not appearing as
expected, or when reconfiguring Xcode Cloud. Everything here is configured in the App Store Connect
web UI; none of it lives in this repo.

## Required workflow shape

| Trigger | Workflow | Actions |
| --- | --- | --- |
| `rc/*` tag push | **Release Candidate** | Test - iOS, **then** Archive - iOS (Distribution: TestFlight External) |
| `v*` tag push | *(none)* | — |

Two properties matter:

1. **Test and archive live in the same workflow, in that order.** Xcode Cloud runs a workflow's
   actions in sequence and stops at the first failure, so a red test action means no build is
   produced. Splitting them into two workflows both triggered on `rc/*` would let an archive upload
   while its tests are still running or already failed.
2. **No workflow triggers on `v*`.** The `v{version}` tag is a record of what shipped. The App Store
   build is selected in App Store Connect from the already-uploaded TestFlight build. If a `v*`
   trigger still exists from the previous process, disable it — otherwise every ship produces a
   stray archive that nobody tested, with a build number that collides with the soaked one.

## Environment variables on the archive action

`ci_scripts/ci_pre_xcodebuild.sh` fails an archive when `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID`
is missing or still a CI placeholder, rather than shipping a build with broken cloud sign-in. The
Release Candidate workflow now archives, so **it must carry the real values**:

- `DROPBOX_APP_KEY` — real key, marked secret
- `ONEDRIVE_CLIENT_ID` — real client ID, marked secret

Under the previous process only the `v*` Release workflow needed these. Moving the archive to
`rc/*` moves the requirement with it.

For non-archive actions, `ci_scripts/ci_post_clone.sh` falls back to CI-only placeholders so
project generation still succeeds. The Dropbox placeholder is `ciplaceholderdropboxappkey` —
alphanumerics only, because it is interpolated into the `db-$(DROPBOX_APP_KEY)`
`CFBundleURLScheme` and App Store Connect rejects underscores with ITMS-90158.
`KeeForgeTests/URLSchemeFormatTests.swift` enforces this on the built app bundle.

## TestFlight distribution

- The archive action's distribution preparation must target **TestFlight (External)**, pointed at
  the public-link group.
- The **first build of each new marketing version** goes through Beta App Review before external
  testers can install it — budget roughly a day. Later builds of the same version normally
  distribute without re-review.
- Export compliance does not prompt: `ITSAppUsesNonExemptEncryption` is declared in
  `KeeForge/Info.plist`.

## Public link settings

- Set a **tester cap** on the public link. A few hundred is plenty for a first public beta and
  keeps feedback triageable; the hard ceiling is 10,000 external testers.
- Keep the link **disabled between releases** so testers do not accumulate and auto-update into a
  candidate they did not opt into.
- Public-link testers join without approval and Apple does not expose their email addresses. The
  only channels back to them are the per-build **What to Test** notes and
  `feedback.keeforge.com`.

## What Xcode Cloud does not cover

- `ci_scripts/run_kdbx_compatibility_gate.sh` needs `keepassxc-cli`, which Xcode Cloud does not
  install. It stays a required **local** gate, run once per candidate build.
- Minimum-OS coverage: Xcode Cloud's test action can only pin the latest runtime or iOS 16.4, with
  no iOS 18.x runtime available. `.github/workflows/ios18-rc-tests.yml` on GitHub-hosted `macos-15`
  runners covers iOS 18 and the iPad regular-width lane.
